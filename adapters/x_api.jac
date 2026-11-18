"""Official X API adapter: pay-per-use polling (docs/spec.md Ã‚Â§4, preference #3).

- GET /2/users/:id/tweets with since_id, exclude=replies, and
  expansions=referenced_tweets.id so quote tweets arrive with quoted text.
- author_id expansion refreshes the handle from the stable ID on every poll
  that returns data (rename-safe); a 404/403 on the timeline marks the
  account inactive and notifies via adapter status. Never crashes.
- Daily read budget is a hard stop: pause polling until the next UTC day,
  log loudly, banner via status. Telegram keeps running (Ã‚Â§12).
"""

import asyncio;
import logging;
import json;
import httpx;
import from datetime { UTC, datetime, timedelta }
import from adapters.base { AdapterStatus, Json, NormalizedPost, Sink, SourceAdapter }
import from config { AccountCfg, Settings }
import from db.repo { Repo, Row }

glob log: logging.Logger = logging.getLogger("newsstream.x_api");

glob BASE: str = "https://api.x.com/2",
     TWEET_PARAMS: dict[str, str] = {
         "max_results": "25",
         "exclude": "replies",
         "tweet.fields": "created_at,referenced_tweets,text",
         "expansions": "referenced_tweets.id,author_id,attachments.media_keys",
         "user.fields": "username",
         "media.fields": "url"
     };

"""Pure converter: API payload -> (posts oldest-first, current handle)."""
def parse_timeline(
    payload: Json,
    account_id: str,
    fallback_handle: str,
    *,
    received_at: datetime | None = None
) -> tuple[list[NormalizedPost], str] {
    received = received_at or datetime.now(UTC);
    includes = (payload.get("includes") or {}) as Json;
    quoted_by_id = {
        t["id"]: t.get("text", "") for t in (includes.get("tweets", []) as list[Json])
    };
    media_by_key = {
        m["media_key"]: m.get("url")
        for m in (includes.get("media", []) as list[Json])
        if m.get("media_key")
    };
    handle = fallback_handle;
    for u in (includes.get("users", []) as list[Json]) {
        if u.get("id") == account_id {
            handle = str(u.get("username", fallback_handle));
        }
    }

    posts: list[NormalizedPost] = [];
    for t in ((payload.get("data") or []) as list[Json]) {
        refs = (t.get("referenced_tweets") or []) as list[Json];
        # belt: exclude=replies upstream
        if `any(r.get("type") == "replied_to" for r in refs) {
            continue;
        }
        quoted_text: str | None = None;
        for r in refs {
            if r.get("type") == "quoted" {
                quoted_text = quoted_by_id.get(r.get("id")) or None;
            }
        }
        media_urls = [
            str(media_by_key[k])
            for k in ((t.get("attachments") or {}) as Json).get("media_keys", [])
            if media_by_key.get(k)
        ];
        posts.append(
            NormalizedPost(
                source="x",
                source_post_id=str(t["id"]),
                account_id=account_id,
                account_handle=handle,
                url=f"https://x.com/{handle}/status/{t['id']}",
                text=str(t.get("text", "")),
                quoted_text=quoted_text,
                is_reply=False,
                posted_at=datetime.fromisoformat(
                    t["created_at"].replace("Z", "+00:00")
                ),
                received_at=received,
                media_urls=media_urls
            )
        );
    }
    posts.reverse();  # API returns newest first; emit oldest first
    return (posts, handle);
}

def _seconds_to_next_utc_day -> float {
    now = datetime.now(UTC);
    tomorrow = (now + timedelta(days=1)).replace(
        hour=0, minute=0, second=0, microsecond=0
    );
    return (tomorrow - now).total_seconds();
}

class _ReadBudgetPaused(RuntimeError) {}

obj XApiAdapter(SourceAdapter) {
    has settings: Settings,
        repo: Repo,
        http: httpx.AsyncClient | None = None;  # injectable for tests

    has _resume_account: str = "";

    override def postinit {
        self.status = AdapterStatus(name="x_api");
    }

    def _client -> httpx.AsyncClient {
        if self.http is None {
            self.http = httpx.AsyncClient(
                timeout=15,
                headers={"Authorization": f"Bearer {self.settings.x_bearer_token}"}
            );
        }
        return self.http;
    }

    """Reserve the maximum possible page before I/O. An interrupted request
    keeps its reservation because the provider may have served the page."""
    async def _get(
        path: str, params: dict[str, str], minimum: int, maximum: int
    ) -> httpx.Response | None {
        day = datetime.now(UTC).date().isoformat();
        budget = self.settings.x_daily_read_budget;
        count = min(maximum, budget - await self.repo.x_reads_today());
        if count < minimum or not await self.repo.reserve_x_reads(day, count, budget) {
            self.status.state = "budget-paused";
            self.status.detail = f"Too few reads left for this request ({minimum} required); resumes next UTC day";
            return None;
        }
        if "max_results" in params {
            params["max_results"] = str(count);
        }
        try {
            response = await self._client().get(path, params=params);
        } except httpx.ConnectError {
            await self.repo.refund_x_reads(day, count);
            raise;
        }
        charged = max(1, len(response.json().get("data") or []))
            if maximum > 1 and response.is_success
            else 1;
        await self.repo.refund_x_reads(day, count - charged);
        return response;
    }

    async def resolve_account(handle: str) -> tuple[str, str] {
        r = await self._get(f"{BASE}/users/by/username/{handle.lstrip('@')}", {}, 1, 1);
        if r is None {
            raise _ReadBudgetPaused(self.status.detail);
        }
        r.raise_for_status();
        data = r.json()["data"];
        return (str(data["id"]), str(data["username"]));
    }

    async def _resolve_configured(pending: list[AccountCfg]) -> list[AccountCfg] {
        deferred: list[AccountCfg] = [];
        for (index, acct) in enumerate(pending) {
            try {
                (account_id, handle) = await self.resolve_account(acct.handle);
                await self.repo.upsert_account("x", account_id, handle, acct.tier);
                log.info("resolved @%s -> id %s", handle, account_id);
            } except _ReadBudgetPaused {
                return deferred + pending[index:];
            } except httpx.TransportError {
                deferred.append(acct);
                log.warning("Temporary X lookup failure for @%s", acct.handle);
            } except httpx.HTTPStatusError as e {
                if e.response.status_code == 429 or e.response.status_code >= 500 {
                    deferred.append(acct);
                }
                log.warning(
                    "X lookup returned %d for @%s", e.response.status_code, acct.handle
                );
            } except (KeyError, ValueError, TypeError) as e {
                log.error(
                    "could not resolve configured X handle @%s: %s", acct.handle, e
                );
            }
        }
        return deferred;
    }

    async def run(sink: Sink) {
        s = self.settings;
        if not s.x_api_enabled or not s.x_bearer_token {
            self.status.state = "disabled";
            self.status.detail = "x_api.enabled false or X_BEARER_TOKEN unset";
            log.info("x_api adapter idle: %s", self.status.detail);
            return;
        }

        known = {str(a["handle"]).lower() for a in await self.repo.get_accounts("x")};
        pending = [
            a
            for a in s.accounts
            if a.source == "x" and a.handle.lstrip("@").lower() not in known
        ];
        while True {
            pending = await self._resolve_configured(pending);
            if self.status.state != "budget-paused" {
                await self._poll_cycle(sink);
                if pending and self.status.state != "budget-paused" {
                    self.status.state = "reconnecting";
                    self.status.detail = f"Will retry {len(
                        pending
                    )} configured account lookup(s)";
                }
            }
            if self.status.state == "budget-paused" {
                log.warning("Official X polling paused: %s", self.status.detail);
                await asyncio.sleep(min(_seconds_to_next_utc_day(), 3600));
                self.status.state = "starting";
                continue;
            }
            await asyncio.sleep(s.x_poll_interval);
        }
    }

    async def _poll_cycle(sink: Sink) {
        accounts = [
            a
            for a in await self.repo.get_accounts("x")
            if a["status"] == "active"
        ];
        # A small daily cap may cover only part of the watchlist. Start the
        # next cycle at the account that was waiting when quota ran out.
        for (position, acct) in enumerate(accounts) {
            if str(acct["account_id"]) == self._resume_account {
                accounts = accounts[position:] + accounts[:position];
                break;
            }
        }
        self._resume_account = "";
        failures: list[str] = [];
        for acct in accounts {
            try {
                if await self._poll_account(acct, sink) {
                    continue;
                }
                if self.status.state == "budget-paused" {
                    self._resume_account = str(acct["account_id"]);
                    return;
                }
            } except httpx.HTTPStatusError as e {
                await self._handle_http_error(acct, e);
            } except httpx.HTTPError as e {
                self.status.detail = str(e)[:120];
                log.warning("x poll network error for @%s: %s", acct["handle"], e);
            }
            failures.append(self.status.detail);
        }
        if failures {
            self.status.state = "reconnecting";
            self.status.detail = f"{len(failures)}/{len(
                accounts
            )} account polls failed: {failures[0]}";
        } elif accounts {
            self.status.state = "live";
            self.status.detail = f"polling {len(accounts)} account(s) every {self.settings.x_poll_interval}s";
        } else {
            self.status.state = "disabled";
            self.status.detail = "no active X accounts";
        }
    }

    async def _poll_account(acct: Row, sink: Sink) -> bool {
        params = dict(TWEET_PARAMS);
        account_id = str(acct["account_id"]);
        cursor = await self.repo.x_poll_cursor(account_id);
        since = str(cursor["since_id"]);
        token = str(cursor["next_token"]);
        pages: list[Row] = json.loads(cursor["pages"]);
        upper = str(pages[-1].get("until_id", "")) if pages else "";
        restarted = False;
        if since and since != "0" {
            params["since_id"] = since;
        }
        while True {
            if token {
                params["pagination_token"] = token;
            } elif pages {
                # Preserve the buffered rows. Restart only the missing interval
                # above the committed since_id and below the oldest buffered ID.
                upper = min(
                    (
                        str(row["id"]) for page in pages
                        for row in page["payload"].get("data") or []
                    ),
                    key=int,
                    `default=""
                );
            }
            if upper {
                params["until_id"] = upper;
            }
            # X requires max_results >= 5 even when the timeline is empty.
            r = await self._get(f"{BASE}/users/{account_id}/tweets", params, 5, 25);
            if r is None {
                return False;
            }
            if r.status_code == 429 {
                reset = float(r.headers.get("x-rate-limit-reset", 0));
                pause = max(5.0, reset - datetime.now(UTC).timestamp());
                self.status.state = "reconnecting";
                self.status.detail = "X rate limit reached";
                log.warning("x rate limited; sleeping %.0fs", pause);
                await asyncio.sleep(min(pause, 900));
                return False;
            }
            if token and r.status_code in (400, 410, 422) {
                # Retry a rejected continuation at most once per poll. A second
                # rejection leaves a token-free checkpoint for the following poll.
                token = "";
                params.pop("pagination_token", None);
                await self.repo.save_x_poll_cursor(account_id, since, "", pages);
                if not restarted {
                    restarted = True;
                    continue;
                }
            }
            r.raise_for_status();
            payload = r.json();
            pages.append(
                {
                    "payload": payload,
                    "received": datetime.now(UTC).isoformat(),
                    "until_id": upper
                }
            );
            next_token = str((payload.get("meta") or {}).get("next_token") or "");
            # The first successful poll establishes the existing one-page baseline.
            if not since or not next_token {
                break;
            }
            if next_token == token {
                raise httpx.ProtocolError("X pagination token did not advance");
            }
            token = next_token;
            await self.repo.save_x_poll_cursor(account_id, since, token, pages);
        }
        newest = since or "0";
        handle = str(acct["handle"]);
        for page in reversed(pages) {
            payload = page["payload"];
            (posts, handle) = parse_timeline(
                payload,
                account_id,
                handle,
                received_at=datetime.fromisoformat(page["received"])
            );
            for post in posts {
                post.tier = str(acct["tier"]);
                await sink(post);
            }
            for item in payload.get("data") or [] {
                newest = max(newest or "0", str(item["id"]), key=int);
            }
        }
        await self.repo.upsert_account("x", account_id, handle, str(acct["tier"]));
        await self.repo.save_x_poll_cursor(account_id, newest, "", []);
        return True;
    }

    async def _handle_http_error(acct: Row, e: httpx.HTTPStatusError) {
        if e.response.status_code in (403, 404) {
            # ID no longer resolves: deleted/suspended. Mark inactive, tell the UI.
            await self.repo.set_account_status(
                "x", str(acct["account_id"]), "inactive"
            );
            self.status.detail = f"@{acct['handle']} unresolvable -> marked inactive";
            log.error(
                "x account @%s (id %s) unresolvable (%d); marked inactive",
                acct["handle"],
                acct["account_id"],
                e.response.status_code
            );
        } else {
            self.status.state = "reconnecting";
            self.status.detail = f"HTTP {e.response.status_code} for @{acct['handle']}";
            log.warning(
                "x poll error %d for @%s", e.response.status_code, acct["handle"]
            );
        }
    }
}
