"""Restart an old database mid-surface, including posts with completed outcomes."""
import asyncio;
import from tests.helpers { make_settings, open_repo, stub_llm, load_fixture }
import from pipeline.notify { Bus }
import from pipeline.runner { Pipeline }

test "legacy partial results finish without reclassifying or rewriting prior outcomes" {
    async def body {
        settings = make_settings();
        roles = [
            "unlinked",
            "origin",
            "update",
            "duplicate",
            "notified",
            "held",
            "suppressed"
        ];
        async with open_repo(settings) as repo {
            # Populate only the records the former multi-commit runner had saved.
            await repo.db.execute("DROP TRIGGER queue_ingested_post");
            event_id = await repo.create_event(
                "OTHER", "Linked event", "Updated summary", {}
            );
            orphan_id = await repo.create_event(
                "SHIPPING_INCIDENT", "Stored headline", "Stored headline", {}
            );
            ids: dict[str, int] = {};
            for role in roles {
                post = load_fixture("kharg_strikes")[0][0];
                post.source_post_id = role;
                inserted = await repo.insert_post(post);
                assert inserted is not None;
                ids[role] = inserted;
                if role == "held" {
                    await repo.insert_decision(
                        inserted,
                        "unfiltered",
                        "",
                        error="llm_unavailable",
                        is_final=True
                    );
                } else {
                    await repo.insert_decision(inserted, "triage", "first");
                    score = 69
                        if role == "suppressed"
                        else (60 if role == "update" else 100);
                    await repo.insert_decision(
                        inserted,
                        "review",
                        "original",
                        materiality_score=score,
                        one_line="Stored headline",
                        category="SHIPPING_INCIDENT",
                        entities={},
                        is_final=True
                    );
                }
                if role in ("origin", "update", "duplicate", "notified") {
                    await repo.link_event_post(
                        event_id, inserted, "update" if role == "notified" else role
                    );
                }
                if role == "notified" {
                    await repo.insert_notification(
                        "UPDATE", inserted, event_id, {"original": True}
                    );
                }
            }
            old_decisions = await repo._all("SELECT * FROM decisions ORDER BY id");
            old_links = await repo._all("SELECT * FROM event_posts ORDER BY post_id");
            old_event = await repo.get_event(event_id);
            old_orphan = await repo.get_event(orphan_id);
            await repo.db.execute("DELETE FROM pipeline_migrations");
            await repo.db.commit();
        }
        async with open_repo(settings) as repo {
            llm = stub_llm();
            worker = Pipeline(settings, repo, llm, Bus());
            task = asyncio.create_task(worker.run());
            try {
                async def drained {
                    while not await repo._one(
                        "SELECT 1 FROM pipeline_migrations WHERE version=2"
                    )
                        or await repo._one("SELECT 1 FROM pipeline_pending LIMIT 1") {
                        await asyncio.sleep(0.01);
                    }
                }
                await asyncio.wait_for(drained(), 10);
            } finally {
                task.cancel();
                await asyncio.gather(task, return_exceptions=True);
            }
            cards = await repo.notifications_since(0);
            assert len(cards) == 4;
            assert cards[0] == {"original": True, "notification_id": 1};
            assert [(c["post_id"], c["kind"]) for c in cards[1:]]
                == [
                    (ids["unlinked"], "NEW_EVENT"),
                    (ids["origin"], "NEW_EVENT"),
                    (ids["update"], "UPDATE")
                ];
            assert cards[1]["score"] == 100
                and cards[1]["one_line"] == "Stored headline";
            assert cards[1]["event_id"] not in (event_id, orphan_id);
            assert cards[2]["event_id"] == cards[3]["event_id"] == event_id;
            assert cards[3]["what_changed"] == "Stored headline"
                and cards[3]["score"] == 60;
            assert await repo.get_event(event_id) == old_event;
            assert await repo.get_event(orphan_id) == old_orphan;
            assert len(await repo._all("SELECT id FROM events")) == 3;
            assert await repo._all(
                "SELECT * FROM event_posts WHERE post_id<>? ORDER BY post_id",
                (ids["unlinked"], )
            )
                == old_links;
            assert await repo._all("SELECT * FROM decisions ORDER BY id")
                == old_decisions;
            assert not llm.calls;
            # Subsequent configuration changes must not resurrect suppressed posts.
            await repo.recover_partial_results(5);
            assert not await repo._all("SELECT * FROM pipeline_pending");
        }
    }
    asyncio.run(body());
}
