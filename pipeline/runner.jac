"""Pipeline orchestration (docs/spec.md §6): persist -> classify -> dedup -> notify.

Operational rules honored here (§12):
- Persist raw before any LLM call; never lose a post to a downstream failure.
- 3+ consecutive Anthropic errors -> fail open: official/tracker posts surface
  unclassified with an "unfiltered" badge until calls succeed again.
- One INFO line per post: received | classified | dedup | latency.
- Dedup candidates are fetched concurrently with classification (latency §6).
"""

import asyncio;
import logging;
import time;
import json;
import from datetime { datetime }
import from collections { deque }
import from adapters.base { NormalizedPost }
import from config { Settings }
import from db.repo { Repo, Row }
import from pipeline.classify { Classification, classify }
import from pipeline.dedup {
    DedupResult,
    decide,
    fetch_open_events,
    filter_candidates,
    merge_summary,
    merged_entities
}
import from pipeline.llm { LLMClient, LLMUnavailable }
import from pipeline.normalize { normalize }
import from pipeline.notify { Bus, build_card, save_card }
import from pipeline.trade { Trader }

glob log: logging.Logger = logging.getLogger("newsstream.pipeline");

# (timestamp, seconds) samples
type Samples = deque[tuple[float, float]];

"""Rolling latency metrics for the UI footer."""
obj Stats {
    has platform: Samples postinit,  # posted -> received
        surface: Samples postinit;  # received -> published

    def postinit {
        self.platform = deque(maxlen=2000);
        self.surface = deque(maxlen=2000);
    }

    static def _percentiles(samples: Samples) -> dict[str, float | None] {
        cutoff = time.time() - 3600;
        vals = sorted(
            v
            for (ts, v) in samples
            if ts >= cutoff
        );
        if not vals {
            return {"p50": None, "p95": None};
        }
        return {
            "p50": round(vals[len(vals) // 2], 1),
            "p95": round(vals[min(len(vals) - 1, int(len(vals) * 0.95))], 1)
        };
    }

    def snapshot -> dict[str, dict[str, float | None]] {
        return {
            "platform": Stats._percentiles(self.platform),
            "surface": Stats._percentiles(self.surface)
        };
    }
}

obj Pipeline {
    has settings: Settings,
        repo: Repo,
        llm: LLMClient,
        bus: Bus,
        trader: Trader | None = None;

    has stats: Stats postinit,
        work_ready: asyncio.Event postinit,
        _trade_tasks: set[asyncio.Task[Row | None]] postinit;

    def postinit {
        self.stats = Stats();
        self.work_ready = asyncio.Event();
        self._trade_tasks = set();
    }

    """Commit the raw input before acknowledging receipt to the adapter."""
    async def sink(raw_post: NormalizedPost) {
        post = normalize(raw_post, self.settings);
        if post is not None {
            await self.repo.insert_post(post);
            self.work_ready.set();
        }
    }

    async def run {
        while True {
            self.work_ready.clear();
            row = await self.repo._one(
                "SELECT p.* FROM pipeline_pending q JOIN posts p ON p.id=q.post_id WHERE q.retry_at<=? ORDER BY q.post_id LIMIT 1",
                (time.time(), )
            );
            if row is None {
                try {
                    await asyncio.wait_for(self.work_ready.wait(), timeout=5);
                } except asyncio.TimeoutError {}
                continue;
            }
            post = NormalizedPost(
                source=row["source"],
                source_post_id=row["source_post_id"],
                account_id=row["account_id"],
                account_handle=row["account_handle"],
                url=row["url"],
                text=row["text"],
                quoted_text=row["quoted_text"],
                is_reply=bool(row["is_reply"]),
                posted_at=datetime.fromisoformat(row["posted_at"]),
                received_at=datetime.fromisoformat(row["received_at"]),
                media_urls=json.loads(row["media_urls"]),
                tier=row["tier"]
            );
            try {
                await self._process_pending(post, row["id"]);
            } except Exception {
                log.exception(
                    "processing failed for %s:%s; retained for retry",
                    post.source,
                    post.source_post_id
                );
                await self.repo._run(
                    "UPDATE pipeline_pending SET retry_at=? WHERE post_id=?",
                    (time.time() + 30, row["id"])
                );
                await self.repo.db.commit();
            }
        }
    }

    """Synchronous ingestion for replay tools and tests."""
    async def process(raw_post: NormalizedPost) -> str {
        post = normalize(raw_post, self.settings);
        if post is None {
            return "dropped";
        }
        post_id = await self.repo.insert_post(post);
        if post_id is None {
            return "seen";
        }
        return await self._process_pending(post, post_id);
    }

    async def _process_pending(post: NormalizedPost, post_id: int) -> str {
        t0 = time.monotonic();
        self.stats.platform.append(
            (time.time(), (post.received_at - post.posted_at).total_seconds())
        );
        events_task = asyncio.create_task(fetch_open_events(self.repo, self.settings));
        classifications: list[Classification] = [];
        result = DedupResult("suppressed", None);
        summary = "";
        entities: dict[str, list[str]] = {};
        try {
            try {
                classifications = await classify(
                    self.llm, self.settings, post, post_id
                );
            } except LLMUnavailable {
                result = DedupResult(
                    "UNFILTERED"
                        if self.llm.fail_open and post.tier in ("official", "tracker")
                        else "held-llm-down",
                    None
                );
            }
            if classifications
                and classifications[-1].materiality_score
                    >= self.settings.market.threshold {
                final = classifications[-1];
                candidates = filter_candidates(await events_task, final);
                try {
                    result = await decide(
                        self.llm, self.settings, post, final, candidates, post_id
                    );
                } except LLMUnavailable {
                    result = DedupResult(
                        "NEW_EVENT", None, reasoning="dedup_llm_unavailable"
                    );
                }
                if result.decision == "UPDATE" {
                    assert result.event_id is not None;
                    event = await self.repo.get_event(result.event_id);
                    assert event is not None;
                    summary = await merge_summary(
                        self.llm, self.settings, event, post, result, post_id
                    );
                    entities = merged_entities(event["entities"], final.entities);
                }
            }
        } finally {
            events_task.cancel();
            await asyncio.gather(events_task, return_exceptions=True);
        }
        outcome = await self._commit_outcome(
            post, post_id, classifications, result, summary, entities
        );
        elapsed = time.monotonic() - t0;
        if outcome in ("NEW_EVENT", "UPDATE") {
            self.stats.surface.append((time.time(), elapsed));
        }
        log.info(
            "received %s:%s | classified score=%s cat=%s | dedup=%s | latency=%.1fs",
            post.source,
            post.source_post_id,
            classifications[-1].materiality_score if classifications else None,
            classifications[-1].category if classifications else None,
            outcome,
            elapsed
        );
        return outcome;
    }

    async def _commit_outcome(
        post: NormalizedPost,
        post_id: int,
        classifications: list[Classification],
        result: DedupResult,
        summary: str,
        entities: dict[str, list[str]]
    ) -> str {
        final = classifications[-1] if classifications else None;
        event_id = result.event_id;
        title = "";
        card: Row | None = None;
        nid = 0;
        async with self.repo.result_transaction() as writer {
            claimed = await writer._run(
                "DELETE FROM pipeline_pending WHERE post_id=?", (post_id, )
            );
            if not claimed.rowcount {
                return "seen";
            }
            # A pre-upgrade interruption may have persisted a nonfinal triage row.
            await writer._run(
                "DELETE FROM decisions WHERE post_id=? AND is_final=0", (post_id, )
            );
            for (i, c) in enumerate(classifications) {
                await writer.insert_decision(
                    post_id,
                    c.stage,
                    c.model,
                    materiality_score=c.materiality_score,
                    sub_scores=c.sub_scores,
                    category=c.category,
                    one_line=c.one_line,
                    entities=c.entities,
                    reasoning=c.reasoning,
                    error=c.error,
                    is_final=i == len(classifications) - 1
                );
            }
            if final is None {
                await writer.insert_decision(
                    post_id, "unfiltered", "", error="llm_unavailable", is_final=True
                );
            }
            if result.decision == "NEW_EVENT" {
                assert final is not None;
                title = final.one_line or post.text[:120];
                event_id = await writer.create_event(
                    final.category, title, title, final.entities
                );
                await writer.link_event_post(event_id, post_id, "origin");
            } elif result.decision == "UPDATE" {
                assert event_id is not None;
                event = await writer.get_event(event_id);
                assert event is not None;
                title = str(event["title"]);
                await writer.update_event(event_id, summary, entities);
                await writer.link_event_post(event_id, post_id, "update");
            } elif result.decision == "DUPLICATE" {
                assert event_id is not None;
                await writer.link_event_post(event_id, post_id, "duplicate");
            }
            if result.decision in ("NEW_EVENT", "UPDATE", "UNFILTERED") {
                badges = ["unfiltered"]
                    if final is None
                    else (["classifier-error"] if final.error else []);
                card = build_card(
                    result.decision,
                    post,
                    post_id,
                    final,
                    event_id=event_id,
                    event_title=title,
                    what_changed=result.what_changed,
                    badges=badges
                );
                nid = await save_card(writer, card);
            }
        }
        if card is not None {
            self.bus.publish(card);
        }
        if result.decision == "NEW_EVENT"
            and result.reasoning != "dedup_llm_unavailable" {
            assert final is not None and event_id is not None;
            self._spawn_trade(post, post_id, final, event_id, nid);
        }
        return result.decision;
    }

    """Trade suggestion for a new event, after its card is out; runs beside the
    queue so the next post is not held up by it."""
    def _spawn_trade(
        post: NormalizedPost,
        post_id: int,
        final: Classification,
        event_id: int,
        notification_id: int
    ) {
        if self.trader is None {
            return;
        }
        task = asyncio.create_task(
            self.trader.on_new_event(post, post_id, final, event_id, notification_id)
        );
        self._trade_tasks.add(task);
        task.add_done_callback(self._trade_done);
    }

    def _trade_done(task: asyncio.Task[Row | None]) {
        self._trade_tasks.discard(task);
        if not task.cancelled() and task.exception() is not None {
            log.error("trade suggestion failed", exc_info=task.exception());
        }
    }

    """Wait for in-flight trade suggestions (tests, shutdown)."""
    async def trades_idle {
        if self._trade_tasks {
            await asyncio.gather(*list(self._trade_tasks), return_exceptions=True);
        }
    }

    """Mark events stale after stale_after_hours with no updates (§8)."""
    async def stale_sweeper {
        while True {
            n = await self.repo.mark_stale_events(self.settings.stale_after_hours);
            if n {
                log.info("marked %d events stale", n);
            }
            await asyncio.sleep(600);
        }
    }
}
