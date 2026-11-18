"""Offline regression scenarios from the November 2026 feature audit."""
import asyncio;
import httpx;
import from adapters.base { Json, NormalizedPost }
import from adapters.x_api { XApiAdapter }
import from adapters.telegram { TelegramAdapter }
import from config { ChannelCfg }
import from tests.helpers { make_settings, open_repo }

test "official X daily budget is bounded on every request" {
    async def body {
        s = make_settings();
        s.x_daily_read_budget = 1;
        async with open_repo(s) as repo {
            calls: list[str] = [];
            def handle(r: httpx.Request) -> httpx.Response {
                calls.append(str(r.url));
                return httpx.Response(200, json={"data": []});
            }
            async def sink(p: NormalizedPost) {}
            async with httpx.AsyncClient(
                transport=httpx.MockTransport(handle)
            ) as client {
                adapter = XApiAdapter(s, repo, client);
                for i in range(3) {
                    await adapter._poll_account(
                        {"account_id": str(i), "handle": "demo", "tier": "osint"}, sink
                    );
                }
                assert not calls and await repo.x_reads_today() == 0;
                assert adapter.status.state == "budget-paused";
                s.x_daily_read_budget = 6;
                for i in range(3) {
                    acct: Json = {
                        "account_id": str(i),
                        "handle": "demo",
                        "tier": "osint"
                    };
                    await adapter._poll_account(acct, sink);
                }
                assert len(calls) == 2;
                assert "max_results=6" in calls[0] and "max_results=5" in calls[1];
                assert await repo.x_reads_today() == 2;
            }
        }
    }
    asyncio.run(body());
}

test "official X catchup spans pages and survives a pause and restart" {
    async def body {
        s = make_settings();
        s.x_daily_read_budget = 25;
        async with open_repo(s) as repo {
            await repo.save_x_poll_cursor("1", "100", "", []);
            cursors: list[str] = [];
            got: list[str] = [];
            def handle(r: httpx.Request) -> httpx.Response {
                token = r.url.params.get("pagination_token", "");
                cursors.append(token);
                assert r.url.params.get("since_id") == "100";
                ids = range(105, 100, -1) if token else range(130, 105, -1);
                return httpx.Response(
                    200,
                    json={
                        "data": [
                            {
                                "id": str(i),
                                "text": "fixture",
                                "created_at": "2026-11-18T12:00:00Z"
                            } for i in ids
                        ],
                        "meta": {} if token else {"next_token": "page2"}
                    }
                );
            }
            async def sink(p: NormalizedPost) {
                got.append(p.source_post_id);
            }
            acct: Json = {"account_id": "1", "handle": "demo", "tier": "tracker"};
            async with httpx.AsyncClient(
                transport=httpx.MockTransport(handle)
            ) as client {
                await XApiAdapter(s, repo, client)._poll_account(acct, sink);
                assert cursors == [""] and not got;
                assert await repo.x_reads_today() == 25;
                # Simulate an increased cap or the next daily budget and a fresh adapter.
                s.x_daily_read_budget = 50;
                await XApiAdapter(s, repo, client)._poll_account(acct, sink);
                assert cursors == ["", "page2"];
                assert got == [str(i) for i in range(101, 131)];
                assert await repo.x_reads_today() == 30;
                assert (await repo.x_poll_cursor("1"))["since_id"] == "130";
            }
        }
    }
    asyncio.run(body());
}

test "Telegram Bot only forwards configured stable channel IDs" {
    async def body {
        s = make_settings();
        s.telegram_channels = [ChannelCfg("alpha", "official")];
        s.telegram_bot_token = "fixture";
        calls: list[str] = [];
        got: list[str] = [];
        def handle(r: httpx.Request) -> httpx.Response {
            if r.url.path.endswith("/getChat") {
                assert r.url.params["chat_id"] == "@alpha";
                return httpx.Response(
                    200, json={"result": {"id": -1001000, "username": "alpha"}}
                );
            }
            calls.append(r.url.params["offset"]);
            if len(calls) > 1 {
                raise asyncio.CancelledError();
            }
            result: list[Json] = [];
            for (id, name, n) in [(-1001000, "renamed", 1), (-1002000, "beta", 2)] {
                result.append(
                    {
                        "update_id": n,
                        "channel_post": {
                            "message_id": n,
                            "date": 1789500000,
                            "text": "bulletin",
                            "chat": {"id": id, "username": name}
                        }
                    }
                );
            }
            return httpx.Response(200, json={"result": result});
        }
        async def sink(p: NormalizedPost) {
            got.append(p.account_handle);
        }
        try {
            await TelegramAdapter(s)._run_bot(
                sink, http=httpx.AsyncClient(transport=httpx.MockTransport(handle))
            );
        } except asyncio.CancelledError {}
        assert got == ["renamed"] and calls == ["0", "3"];
    }
    asyncio.run(body());
}
