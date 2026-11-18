"""Acceptance and recovery across shutdown and interrupted output transactions."""
import asyncio;
import from unittest.mock { patch }
import from pipeline.notify { Bus }
import from pipeline.runner { Pipeline }
import from tests.helpers {
    StubLLM,
    classify_response,
    load_fixture,
    make_settings,
    open_repo,
    stub_llm,
    sub_scores
}

test "accepted posts and the in-flight classification survive restart" {
    async def body {
        settings = make_settings();
        inputs = [post for (post, _) in load_fixture("kharg_strikes")][:3];
        waiting = asyncio.Event();
        async def slow(*args: any, **kwargs: any) -> dict[str, any] {
            waiting.set();
            await asyncio.Event().wait();
            return {};
        }
        async with open_repo(settings) as repo {
            worker = Pipeline(settings, repo, stub_llm(), Bus());
            with patch.object(StubLLM, "call_json", new=slow) {
                task = asyncio.create_task(worker.run());
                await worker.sink(inputs[0]);
                await asyncio.wait_for(waiting.wait(), 5);
                for post in inputs[1:] {
                    await worker.sink(post);
                }
                assert len(await repo._all("SELECT id FROM posts")) == 3;
                task.cancel();
                await asyncio.gather(task, return_exceptions=True);
                assert len(await repo._all("SELECT * FROM pipeline_pending")) == 3;
            }
        }
        async with open_repo(settings) as repo {
            llm = stub_llm([classify_response(sub_scores())] * 3);
            worker = Pipeline(settings, repo, llm, Bus());
            await worker.sink(inputs[0]);
            task = asyncio.create_task(worker.run());
            try {
                async def drained {
                    while (await repo._one("SELECT 1 FROM pipeline_pending LIMIT 1"))
                        is not None {
                        await asyncio.sleep(0.01);
                    }
                }
                await asyncio.wait_for(drained(), 5);
                assert len(llm.calls) == 3;
                assert len(await repo._all("SELECT * FROM decisions WHERE is_final=1"))
                    == 3;
                assert await worker.process(inputs[0]) == "seen";
            } finally {
                task.cancel();
                await asyncio.gather(task, return_exceptions=True);
            }
        }
    }
    asyncio.run(body());
}

test "failed card insert rolls back the event decisions and queue claim" {
    async def body {
        settings = make_settings();
        async with open_repo(settings) as repo {
            post = load_fixture("kharg_strikes")[0][0];
            llm = stub_llm([classify_response(sub_scores(10, 10, 10, 10, 10))] * 2);
            worker = Pipeline(settings, repo, llm, Bus());
            await repo.db.execute(
                "CREATE TRIGGER simulate_failure BEFORE INSERT ON notifications BEGIN SELECT RAISE(ABORT,'interrupted card'); END"
            );
            try {
                await worker.process(post);
            } except Exception as e {
                assert "interrupted card" in str(e);
            }
            assert not await repo._all("SELECT * FROM events");
            assert not await repo._all("SELECT * FROM decisions");
            pending = await repo._all("SELECT post_id FROM pipeline_pending");
            assert len(pending) == 1;
            await repo.db.execute("DROP TRIGGER simulate_failure");
            await repo.db.commit();
            assert await worker._process_pending(post, pending[0]["post_id"])
                == "NEW_EVENT";
            assert len(await repo.notifications_since(0)) == 1;
        }
    }
    asyncio.run(body());
}

test "upgrading a legacy database recovers unfinished inputs only once" {
    async def body {
        settings = make_settings();
        inputs = load_fixture("kharg_strikes");
        async with open_repo(settings) as repo {
            await repo.db.executescript(
                "DROP TRIGGER queue_ingested_post; DROP TABLE pipeline_pending; DROP TABLE pipeline_migrations;"
            );
            stranded = await repo.insert_post(inputs[0][0]);
            complete = await repo.insert_post(inputs[1][0]);
            assert stranded is not None and complete is not None;
            await repo.insert_decision(
                complete, "triage", "fixture", materiality_score=0, is_final=True
            );
        }
        async with open_repo(settings) as repo {
            assert await repo._all("SELECT post_id FROM pipeline_pending")
                == [{"post_id": stranded}];
            worker = Pipeline(
                settings, repo, stub_llm([classify_response(sub_scores())]), Bus()
            );
            assert stranded is not None;
            assert await worker._process_pending(inputs[0][0], stranded)
                == "suppressed";
        }
        async with open_repo(settings) as repo {
            assert not await repo._all("SELECT * FROM pipeline_pending");
            assert len(await repo._all("SELECT * FROM decisions WHERE is_final=1"))
                == 2;
        }
    }
    asyncio.run(body());
}

test "replaying a stored Telegram transport alias preserves its pending job" {
    async def body {
        settings = make_settings();
        async with open_repo(settings) as repo {
            worker = Pipeline(settings, repo, stub_llm(), Bus());
            post = load_fixture("kharg_strikes")[0][0];
            post.source = "telegram";
            post.account_id = "-1001234567890";
            post.source_post_id = "-1001234567890:42";
            await worker.sink(post);
            post.account_id = "1234567890";
            post.source_post_id = "1234567890:42";
            await worker.sink(post);
            rows = await repo._all("SELECT source_post_id FROM posts");
            assert rows == [{"source_post_id": "-1001234567890:42"}];
            assert len(await repo._all("SELECT post_id FROM pipeline_pending")) == 1;
        }
    }
    asyncio.run(body());
}
