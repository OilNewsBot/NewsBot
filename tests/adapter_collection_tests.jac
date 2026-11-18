"""Offline official X polling and configured Telegram collection."""
import asyncio;
import httpx;
import from unittest.mock { patch }
import from adapters.base { Json, NormalizedPost }
import from adapters.x_api { XApiAdapter }
import from adapters.telegram { TelegramAdapter }
import from config { AccountCfg, ChannelCfg }
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

test "expired X continuations restart the missing range with a bounded retry" {
    async def body {
        s = make_settings();
        s.x_daily_read_budget = 5;
        acct: Json = {"account_id": "1", "handle": "demo", "tier": "tracker"};
        def row(id: int) -> Json {
            return {
                "id": str(id),
                "created_at": "2026-11-18T12:00:00Z",
                "text": "fixture"
            };
        }
        tokens: list[str] = [];
        got: list[str] = [];
        def handle(r: httpx.Request) -> httpx.Response {
            q = r.url.params;
            assert q["since_id"] == "100";
            token = q.get("pagination_token", "");
            tokens.append(token);
            if token {
                return httpx.Response(400, json={"detail": "Expired pagination_token"});
            }
            next_id = int(q["until_id"]) - 1;
            return httpx.Response(
                200,
                json={
                    "data": [row(next_id)],
                    "meta": {"next_token": f"expired-{next_id}"}
                        if next_id > 101
                        else {}
                }
            );
        }
        async def sink(p: NormalizedPost) {
            got.append(p.source_post_id);
        }
        async with open_repo(s) as repo {
            await repo.save_x_poll_cursor(
                "1",
                "100",
                "original",
                [
                    {
                        "payload": {"data": [row(105), row(104)]},
                        "received": "2026-11-18T12:00:00+00:00"
                    }
                ]
            );
            async with httpx.AsyncClient(
                transport=httpx.MockTransport(handle)
            ) as client {
                adapter = XApiAdapter(s, repo, client);
                assert not await adapter._poll_account(acct, sink);
                assert tokens == ["original"]
                    and not got
                    and await repo.x_reads_today() == 1;
                s.x_daily_read_budget = 25;
                try {
                    await adapter._poll_account(acct, sink);
                    assert False , "a second rejection must yield to the next poll";
                } except httpx.HTTPStatusError {}
                checkpoint = await repo.x_poll_cursor("1");
                assert checkpoint["since_id"] == "100"
                    and checkpoint["next_token"] == ""
                    and not got;
                assert tokens == ["original", "", "expired-103", "", "expired-102"];
                assert await XApiAdapter(s, repo, client)._poll_account(acct, sink);
                assert got == ["101", "102", "103", "104", "105"];
                assert (await repo.x_poll_cursor("1"))["since_id"] == "105";
                assert await repo.x_reads_today() == 6;
            }
        }
    }
    asyncio.run(body());
}

test "running X adapter resolves quota-deferred configured accounts after UTC rollover" {
    async def body {
        s = make_settings();
        s.x_api_enabled = True;
        s.x_bearer_token = "fixture";
        s.x_daily_read_budget = 8;
        s.accounts = [
            AccountCfg("alpha", "x", "official"),
            AccountCfg("beta", "x", "tracker")
        ];
        calls: list[str] = [];
        def handle(r: httpx.Request) -> httpx.Response {
            path = r.url.path;
            calls.append(path);
            if path.endswith("/tweets") {
                return httpx.Response(200, json={"data": []});
            }
            username = path.split("/")[-1];
            return httpx.Response(
                200,
                json={
                    "data": {
                        "id": "1" if username == "alpha" else "2",
                        "username": username
                    }
                }
            );
        }
        async def sink(p: NormalizedPost) {}
        async with open_repo(s) as repo {
            await repo.add_x_reads(7);
            async with httpx.AsyncClient(
                transport=httpx.MockTransport(handle)
            ) as client {
                adapter = XApiAdapter(s, repo, client);
                async def advance(delay: float) {
                    if adapter.status.state == "budget-paused" {
                        assert calls == ["/2/users/by/username/alpha"];
                        assert await repo.x_reads_today() == 8;
                        await repo._run("UPDATE x_reads SET day='2000-01-01'");
                        await repo.db.commit();
                    } else {
                        assert adapter.status.state == "live";
                        raise asyncio.CancelledError();
                    }
                }
                with patch("adapters.x_api.asyncio.sleep", new=advance) {
                    try {
                        await adapter.run(sink);
                    } except asyncio.CancelledError {}
                }
                assert calls[:2]
                    == ["/2/users/by/username/alpha", "/2/users/by/username/beta"];
                assert sorted(calls[2:]) == ["/2/users/1/tweets", "/2/users/2/tweets"];
                assert await repo.x_reads_today() == 3;
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
            got.append(p.account_handle + ":" + p.tier);
        }
        try {
            await TelegramAdapter(s)._run_bot(
                sink, http=httpx.AsyncClient(transport=httpx.MockTransport(handle))
            );
        } except asyncio.CancelledError {}
        assert got == ["renamed:official"] and calls == ["0", "3"];
    }
    asyncio.run(body());
}

test "official X reports a failed cycle and a successful recovery" {
    async def body {
        s = make_settings();
        async with open_repo(s) as repo {
            for i in range(3) {
                await repo.upsert_account("x", str(i), "demo" + str(i), "osint");
            }
            async def sink(p: NormalizedPost) {}
            offline = [True];
            def handle(r: httpx.Request) -> httpx.Response {
                if offline[0] {
                    raise httpx.ConnectError("fixture offline");
                }
                return httpx.Response(200, json={"data": []});
            }
            async with httpx.AsyncClient(
                transport=httpx.MockTransport(handle)
            ) as http {
                adapter = XApiAdapter(s, repo, http);
                await adapter._poll_cycle(sink);
                assert adapter.status.state == "reconnecting"
                    and "3/3" in adapter.status.detail;
                offline[0] = False;
                await adapter._poll_cycle(sink);
                assert adapter.status.state == "live";
            }
        }
    }
    asyncio.run(body());
}


test "accounts beyond the daily timeline budget are served on the next day" {
    async def body {
        s = make_settings();
        s.x_daily_read_budget = 5;
        async with open_repo(s) as repo {
            for id in ["1", "2", "3"] {
                await repo.upsert_account("x", id, "desk" + id, "osint");
            }
            ids: list[str] = [];
            def handle(r: httpx.Request) -> httpx.Response {
                ids.append(r.url.path.split("/")[-2]);
                return httpx.Response(200, json={"data": []});
            }
            async def sink(p: NormalizedPost) {}
            async with httpx.AsyncClient(
                transport=httpx.MockTransport(handle)
            ) as client {
                adapter = XApiAdapter(s, repo, client);
                for day in range(3) {
                    await adapter._poll_cycle(sink);
                    assert await repo.x_reads_today() == 1;
                    await repo._run(
                        "UPDATE x_reads SET day=? WHERE day=date('now')",
                        (f"fixture-day-{day}", )
                    );
                    await repo.db.commit();
                }
            }
            assert ids == ["1", "2", "3"];
        }
    }
    asyncio.run(body());
}

test "a temporary X lookup failure does not strand the source or block known accounts" {
    async def body {
        s = make_settings();
        s.x_api_enabled = True;
        s.x_bearer_token = "fixture";
        s.accounts = [AccountCfg("delayed", "x", "tracker")];
        async with open_repo(s) as repo {
            await repo.upsert_account("x", "1", "known", "osint");
            calls: list[str] = [];
            def handle(r: httpx.Request) -> httpx.Response {
                path = r.url.path;
                calls.append(path);
                if path.endswith("/delayed") {
                    if len(calls) == 1 {
                        return httpx.Response(503, json={"error": "outage"});
                    }
                    return httpx.Response(
                        200, json={"data": {"id": "2", "username": "delayed"}}
                    );
                }
                return httpx.Response(200, json={"data": []});
            }
            async def sink(p: NormalizedPost) {}
            async with httpx.AsyncClient(
                transport=httpx.MockTransport(handle)
            ) as client {
                adapter = XApiAdapter(s, repo, client);
                async def step(delay: float) {
                    if len(calls) == 2 {
                        assert adapter.status.state == "reconnecting";
                    } else {
                        raise asyncio.CancelledError();
                    }
                }
                with patch("adapters.x_api.asyncio.sleep", new=step) {
                    try {
                        await adapter.run(sink);
                    } except asyncio.CancelledError {}
                }
                assert calls[:3]
                    == [
                        "/2/users/by/username/delayed",
                        "/2/users/1/tweets",
                        "/2/users/by/username/delayed"
                    ];
                assert sorted(calls[3:]) == ["/2/users/1/tweets", "/2/users/2/tweets"];
                assert adapter.status.state == "live";
            }
        }
    }
    asyncio.run(body());
}
