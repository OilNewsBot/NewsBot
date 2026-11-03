"""Offline personal API tests: ownership, input validation, and durable SSE."""

import asyncio;
import base64;
import contextlib;
import hashlib;
import json;
import os;
import httpx;
import from unittest.mock { patch }
import from fastapi { FastAPI, Request }
import from db.repo { Repo, Row }
import from personal.store { PersonalStore }
import from personal.providers { ProviderError }
import from personal.api { install_personal_routes, personal_events }
import from tests.helpers { make_settings }

glob ALICE: dict[str, str] = {"Cookie": "session=alice-session"},
     BOB: dict[str, str] = {"Cookie": "session=bob-session"};

obj ApiEnvironment {
    has repo: Repo,
        personal: PersonalStore,
        app: FastAPI,
        users: Row;
}

async def offline_resolver(provider: str, locator: str, secret: str = "") -> Row {
    # Provider/network behavior is separately tested with offline transports.
    return {
        "remote_id": locator,
        "name": "Source " + locator,
        "url": "https://example.org/feed"
    };
}

@contextlib.asynccontextmanager
async def api_fixture -> AsyncIterator[ApiEnvironment] {
    settings = make_settings();
    repo = Repo(settings.db_path);
    await repo.connect();
    personal_store = PersonalStore(settings.db_path);
    await personal_store.connect();
    try {
        alice = await repo.create_user("alice", "alice@example.org", "unused");
        bob = await repo.create_user("bob", "bob@example.org", "unused");
        for (uid, token) in [(alice, "alice-session"), (bob, "bob-session")] {
            await repo.create_session(
                hashlib.sha256(token.encode()).hexdigest(), uid, "2099-01-01 00:00:00"
            );
        }
        app = FastAPI();
        install_personal_routes(app, repo, personal_store, resolver=offline_resolver);
        yield ApiEnvironment(repo, personal_store, app, {"alice": alice, "bob": bob});
    } finally {
        await personal_store.close();
        await repo.close();
    }
}

async def add_source(
    client: httpx.AsyncClient, headers: dict[str, str], locator: str = "tech"
) -> Row {
    response = await client.post(
        "/api/me/connections",
        headers=headers,
        json={"provider": "rss", "label": "My RSS"}
    );
    assert response.status_code == 201 , response.text;
    cid = response.json()["connection"]["id"];
    response = await client.post(
        "/api/me/sources",
        headers=headers,
        json={"connection_id": cid, "locator": locator}
    );
    assert response.status_code == 201 , response.text;
    return response.json()["source"];
}

def article(external_id: str, text: str = "Company releases a new product") -> Row {
    return {
        "external_id": external_id,
        "title": "Product announcement",
        "text": text,
        "url": "https://example.org/story",
        "posted_at": "2026-11-01T12:00:00+00:00"
    };
}

def stream_request(token: str) -> Request {
    async def receive -> Row {
        return {"type": "http.request", "body": b"", "more_body": False};
    }
    return Request(
        {
            "type": "http",
            "method": "GET",
            "path": "/api/me/stream",
            "scheme": "http",
            "query_string": b"",
            "server": ("test", 80),
            "headers": [(b"cookie", ("session=" + token).encode())]
        },
        receive=receive
    );
}

test "personal routes require a valid account" {
    async def run {
        async with api_fixture() as fixture {
            app: FastAPI = fixture.app;
            client = httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="http://test"
            );
            async with client {
                for path in [
                    "connections",
                    "sources",
                    "feed",
                    "notifications",
                    "notifications/head",
                    "stream"
                ] {
                    assert (await client.get("/api/me/" + path)).status_code == 401;
                }
                assert (
                    await client.post(
                        "/api/me/connections", json={"provider": "rss", "label": "RSS"}
                    )
                ).status_code
                    == 401;
                assert (
                    await client.post(
                        "/api/me/sources", json={"connection_id": 1, "locator": "x"}
                    )
                ).status_code
                    == 401;
                assert (
                    await client.patch(
                        "/api/me/sources/1", json={"alerts_enabled": False}
                    )
                ).status_code
                    == 401;
                assert (await client.delete("/api/me/sources/1")).status_code == 401;
                assert (await client.delete("/api/me/connections/1")).status_code
                    == 401;
                assert (
                    await client.get(
                        "/api/me/feed", headers={"Cookie": "session=not-a-session"}
                    )
                ).status_code
                    == 401;
            }
        }
    }
    asyncio.run(run());
}

test "personal source reads and changes are isolated between accounts" {
    async def run {
        async with api_fixture() as fixture {
            repo: Repo = fixture.repo;
            personal_store: PersonalStore = fixture.personal;
            app: FastAPI = fixture.app;
            users: Row = fixture.users;
            client = httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="http://test"
            );
            async with client {
                source = await add_source(client, ALICE);
                sid = int(source["id"]);
                cid = int(source["connection_id"]);
                assert (await client.get("/api/me/connections", headers=BOB)).json()
                    == {"connections": []};
                assert (await client.get("/api/me/sources", headers=BOB)).json()
                    == {"sources": []};
                assert (
                    await client.post(
                        "/api/me/sources",
                        headers=BOB,
                        json={"connection_id": cid, "locator": "secret"}
                    )
                ).status_code
                    == 404;
                assert (
                    await client.patch(
                        f"/api/me/connections/{cid}",
                        headers=BOB,
                        json={"api_key": "other"}
                    )
                ).status_code
                    == 404;
                assert (
                    await client.delete(f"/api/me/connections/{cid}", headers=BOB)
                ).status_code
                    == 404;
                assert (
                    await client.patch(
                        f"/api/me/sources/{sid}", headers=BOB, json={"enabled": False}
                    )
                ).status_code
                    == 404;
                assert (
                    await client.delete(f"/api/me/sources/{sid}", headers=BOB)
                ).status_code
                    == 404;
                await personal_store.persist_batch(sid, [], "initial", initial=True);
                await personal_store.persist_batch(
                    sid, [article("1", "Alice private earnings source")], "next"
                );
                afeed = (await client.get("/api/me/feed", headers=ALICE)).json()[
                    "items"
                ];
                assert len(afeed) == 1
                    and afeed[0]["text"] == "Alice private earnings source";
                alerts = (
                    await client.get("/api/me/notifications", headers=ALICE)
                ).json()["notifications"];
                assert len(alerts) == 1 and alerts[0]["kind"] == "SOURCE_POST";
                assert (await client.get("/api/me/feed", headers=BOB)).json()
                    == {"items": []};
                assert (await client.get("/api/me/notifications", headers=BOB)).json()
                    == {"notifications": []};
                assert (
                    await client.get("/api/me/notifications/head", headers=BOB)
                ).json()
                    == {"notification_id": 0};
                assert (
                    await client.get("/api/me/notifications/head", headers=ALICE)
                ).json()["notification_id"]
                    == alerts[0]["notification_id"];
                # Private data cannot reach existing oil feed/history queries.
                assert await repo.notifications_since(0) == [];
                assert await repo.feed() == [];
                assert (
                    await client.delete(f"/api/me/connections/{cid}", headers=ALICE)
                ).status_code
                    == 200;
                assert (await client.get("/api/me/sources", headers=ALICE)).json()
                    == {"sources": []};
                assert (await client.get("/api/me/notifications", headers=ALICE)).json()
                    == {"notifications": []};
            }
        }
    }
    asyncio.run(run());
}

test "personal API rejects cross-origin and invalid mutations" {
    async def run {
        async with api_fixture() as fixture {
            app: FastAPI = fixture.app;
            client = httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="http://test"
            );
            async with client {
                body: Row = {"provider": "rss", "label": "RSS"};
                for origin in [
                    "https://evil.example",
                    "null",
                    "http://test.evil.example",
                    "http://test:81"
                ] {
                    assert (
                        await client.post(
                            "/api/me/connections",
                            headers=ALICE | {"Origin": origin},
                            json=body
                        )
                    ).status_code
                        == 403;
                }
                assert (
                    await client.post(
                        "/api/me/connections",
                        headers=ALICE | {"Sec-Fetch-Site": "cross-site"},
                        json=body
                    )
                ).status_code
                    == 403;
                assert (
                    await client.post(
                        "/api/me/connections",
                        headers=ALICE | {"Origin": "http://test:80"},
                        json=body
                    )
                ).status_code
                    == 201;
                assert (
                    await client.post(
                        "/api/me/connections", headers=ALICE, json=body | {"user_id": 2}
                    )
                ).status_code
                    == 422;
                assert (
                    await client.post(
                        "/api/me/connections",
                        headers=ALICE,
                        json=body | {"daily_limit": True}
                    )
                ).status_code
                    == 422;
                assert (
                    await client.post(
                        "/api/me/connections",
                        headers=ALICE,
                        json=body | {"provider": "anything"}
                    )
                ).status_code
                    == 422;
                assert (
                    await client.post(
                        "/api/me/connections",
                        headers=ALICE,
                        json={"provider": "x", "label": "X"}
                    )
                ).status_code
                    == 422;
                source = await add_source(client, ALICE);
                path = "/api/me/sources/" + str(source["id"]);
                assert (
                    await client.patch(path, headers=ALICE, json={"enabled": "false"})
                ).status_code
                    == 422;
                assert (
                    await client.patch(
                        path, headers=ALICE, json={"include_keywords": "word"}
                    )
                ).status_code
                    == 422;
                assert (
                    await client.patch(
                        path, headers=ALICE, json={"include_keywords": [""]}
                    )
                ).status_code
                    == 422;
                assert (
                    await client.patch(
                        path,
                        headers=ALICE,
                        json={"include_keywords": [" earnings ", "EARNINGS"]}
                    )
                ).json()["source"]["include_keywords"]
                    == ["earnings"];
                assert (
                    await client.patch(
                        path, headers=ALICE, json={"alerts_enabled": False}
                    )
                ).json()["source"]["alerts_enabled"]
                    == False;
                assert (
                    await client.get("/api/me/feed?limit=1000", headers=ALICE)
                ).status_code
                    == 422;
                assert (
                    await client.get("/api/me/notifications?since=-1", headers=ALICE)
                ).status_code
                    == 422;
                assert (
                    await client.get(
                        "/api/me/stream",
                        headers=ALICE | {"Last-Event-ID": "not-a-number"}
                    )
                ).status_code
                    == 422;
            }
        }
    }
    asyncio.run(run());
}

test "personal X API keys stay private and source validation spends the connection budget" {
    async def run {
        with patch.dict(
            os.environ,
            {
                "NEWSBOT_CONNECTION_KEY": base64.urlsafe_b64encode(b"k" * 32).decode(),
                "X_PUSH_API_KEY": ""
            }
        ) {
            async with api_fixture() as fixture {
                personal_store: PersonalStore = fixture.personal;
                app: FastAPI = fixture.app;
                client = httpx.AsyncClient(
                    transport=httpx.ASGITransport(app=app), base_url="http://test"
                );
                async with client {
                    response = await client.post(
                        "/api/me/connections",
                        headers=ALICE,
                        json={
                            "provider": "x",
                            "label": "X",
                            "api_key": "private-example-provider-key",
                            "daily_limit": 1
                        }
                    );
                    assert response.status_code == 201 , response.text;
                    assert "private-example-provider-key" not in response.text;
                    cid = response.json()["connection"]["id"];
                    response = await client.post(
                        "/api/me/sources",
                        headers=ALICE,
                        json={"connection_id": cid, "locator": "alice-source"}
                    );
                    assert response.status_code == 201 , response.text;
                    response = await client.post(
                        "/api/me/sources",
                        headers=ALICE,
                        json={"connection_id": cid, "locator": "second-source"}
                    );
                    assert response.status_code == 429;
                    assert "private-example-provider-key"
                        not in (
                            await client.get("/api/me/connections", headers=ALICE)
                        ).text;
                    assert (
                        await client.patch(
                            f"/api/me/connections/{cid}",
                            headers=ALICE,
                            json={"api_key": "rotated-example-provider-key"}
                        )
                    ).status_code
                        == 200;
                    assert await personal_store.connection_secret(cid)
                        == "rotated-example-provider-key";
                    # Replacing a key does not reset today's budget.
                    assert not await personal_store.claim_request(cid);
                }
            }
        }
        with patch.dict(os.environ, {"NEWSBOT_CONNECTION_KEY": ""}) {
            async with api_fixture() as fixture {
                app: FastAPI = fixture.app;
                client = httpx.AsyncClient(
                    transport=httpx.ASGITransport(app=app), base_url="http://test"
                );
                async with client {
                    response = await client.post(
                        "/api/me/connections",
                        headers=ALICE,
                        json={
                            "provider": "x",
                            "label": "X",
                            "api_key": "private-example-provider-key"
                        }
                    );
                    assert response.status_code == 503;
                    assert "NEWSBOT_CONNECTION_KEY" in response.json()["detail"];
                    assert "private-example-provider-key" not in response.text;
                }
            }
        }
    }
    asyncio.run(run());
}

test "personal SSE replays durably and revokes every tab" {
    async def run {
        async with api_fixture() as fixture {
            repo: Repo = fixture.repo;
            personal_store: PersonalStore = fixture.personal;
            app: FastAPI = fixture.app;
            users: Row = fixture.users;
            client = httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="http://test"
            );
            async with client {
                source = await add_source(client, ALICE);
                other = await add_source(client, BOB);
                sid = int(source["id"]);
                await personal_store.persist_batch(sid, [], "baseline", initial=True);
                await personal_store.persist_batch(
                    int(other["id"]), [], "baseline", initial=True
                );
                first = personal_events(
                    stream_request("alice-session"),
                    repo,
                    personal_store,
                    int(users["alice"]),
                    0,
                    0.0
                );
                second = personal_events(
                    stream_request("alice-session"),
                    repo,
                    personal_store,
                    int(users["alice"]),
                    0,
                    0.0
                );
                assert "connected" in await anext(first);
                assert "connected" in await anext(second);
                # Arrival between opening a stream and its first read is retained.
                await personal_store.persist_batch(sid, [article("1")], "one");
                await personal_store.persist_batch(
                    int(other["id"]), [article("bob1", "Bob private item")], "one"
                );
                message = await anext(first);
                assert "event: notification" in message
                    and "Bob private" not in message;
                assert "event: notification" in await anext(second);
                alert_id = (
                    await personal_store.notifications_since(int(users["alice"]))
                )[0]["notification_id"];
                await personal_store.persist_batch(sid, [article("1")], "one");
                assert len(
                    await personal_store.notifications_since(int(users["alice"]))
                )
                    == 1;
                # Saved replay survives the connection object being reopened.
                await personal_store.close();
                await personal_store.connect();
                replay = personal_events(
                    stream_request("alice-session"),
                    repo,
                    personal_store,
                    int(users["alice"]),
                    int(alert_id),
                    0.0
                );
                assert "connected" in await anext(replay);
                await personal_store.persist_batch(
                    sid, [article("2", "Next update")], "two"
                );
                assert "Next update" in await anext(replay);
                await (replay as any).aclose();
                await repo.delete_session(hashlib.sha256(b"alice-session").hexdigest());
                assert "event: session_expired" in await anext(first);
                assert "event: session_expired" in await anext(second);
                await (first as any).aclose();
                await (second as any).aclose();
                # A different user's login and saved alerts remain valid.
                assert (
                    await client.get("/api/me/notifications", headers=BOB)
                ).status_code
                    == 200;
                assert (await client.get("/api/me/feed", headers=ALICE)).status_code
                    == 401;
            }
        }
    }
    asyncio.run(run());
}

test "personal provider refusal persists a connection cooldown" {
    async def run {
        with patch.dict(
            os.environ,
            {
                "NEWSBOT_CONNECTION_KEY": base64.urlsafe_b64encode(b"k" * 32).decode(),
                "X_PUSH_API_KEY": ""
            }
        ) {
            async with api_fixture() as fixture {
                repo: Repo = fixture.repo;
                personal_store: PersonalStore = fixture.personal;
                users: Row = fixture.users;
                calls: list[str] = [];
                async def limited(provider: str, locator: str, secret: str) -> Row {
                    calls.append(locator);
                    raise ProviderError(
                        "The provider asked us to wait", "rate_limited", 180
                    );
                }
                app = FastAPI();
                install_personal_routes(app, repo, personal_store, resolver=limited);
                conn = await personal_store.create_connection(
                    int(users["alice"]), "x", "X", "cooldown-test-key", 5
                );
                cid = int(conn["id"]);
                client = httpx.AsyncClient(
                    transport=httpx.ASGITransport(app=app), base_url="http://test"
                );
                async with client {
                    response = await client.post(
                        "/api/me/sources",
                        headers=ALICE,
                        json={"connection_id": cid, "locator": "example"}
                    );
                    assert response.status_code == 429;
                    assert response.headers["Retry-After"] == "180";
                    assert response.headers["Cache-Control"] == "no-store";
                    conn = await personal_store.get_connection(
                        int(users["alice"]), cid
                    );
                    assert conn["status"] == "rate_limited" and conn["retry_at"];
                    response = await client.post(
                        "/api/me/sources",
                        headers=ALICE,
                        json={"connection_id": cid, "locator": "another"}
                    );
                    assert response.status_code == 429 and calls == ["example"];
                    assert "cooldown-test-key" not in response.text;
                }
            }
        }
    }
    asyncio.run(run());
}

test "personal SSE does not emit a buffered page after mute and unmute" {
    async def run {
        async with api_fixture() as fixture {
            repo: Repo = fixture.repo;
            personal_store: PersonalStore = fixture.personal;
            users: Row = fixture.users;
            uid = int(users["alice"]);
            conn = await personal_store.create_connection(uid, "rss", "RSS");
            source = await personal_store.create_source(
                uid, int(conn["id"]), "feed", "Feed", "https://example.org/feed"
            );
            sid = int(source["id"]);
            await personal_store.persist_batch(sid, [], "baseline", initial=True);
            await personal_store.persist_batch(
                sid,
                [
                    article("1", "first"),
                    article("2", "buffered second"),
                    article("3", "buffered third")
                ],
                "three"
            );
            stream = personal_events(
                stream_request("alice-session"), repo, personal_store, uid, 0, 0.0
            );
            assert "connected" in await anext(stream);
            assert "first" in await anext(stream);
            # The stream already fetched rows 2 and 3. A mute/resume must invalidate them.
            await personal_store.update_source(uid, sid, {"alerts_enabled": False});
            await personal_store.update_source(uid, sid, {"alerts_enabled": True});
            assert "heartbeat" in await anext(stream);
            await personal_store.persist_batch(
                sid, [article("4", "fresh after resume")], "four"
            );
            assert "fresh after resume" in await anext(stream);
            await (stream as any).aclose();
        }
    }
    asyncio.run(run());
}

test "personal source resolution cannot apply an old credential result after rekey" {
    async def run {
        with patch.dict(
            os.environ,
            {
                "NEWSBOT_CONNECTION_KEY": base64.urlsafe_b64encode(b"k" * 32).decode(),
                "X_PUSH_API_KEY": ""
            }
        ) {
            async with api_fixture() as fixture {
                repo: Repo = fixture.repo;
                personal_store: PersonalStore = fixture.personal;
                users: Row = fixture.users;
                uid = int(users["alice"]);
                conn = await personal_store.create_connection(
                    uid, "x", "X", "original-race-key", 5
                );
                cid = int(conn["id"]);
                async def rekey_during_resolve(
                    provider: str, locator: str, secret: str
                ) -> Row {
                    if locator == "failure" {
                        assert secret == "original-race-key";
                        await personal_store.reconnect_connection(
                            uid, cid, "replacement-race-key"
                        );
                        raise ProviderError(
                            "The old key expired", "needs_reconnect", 60
                        );
                    }
                    assert secret == "replacement-race-key";
                    await personal_store.reconnect_connection(
                        uid, cid, "latest-race-key"
                    );
                    return {
                        "remote_id": "resolved-with-old-key",
                        "name": "Old result",
                        "url": "https://x.com/example"
                    };
                }
                app = FastAPI();
                install_personal_routes(
                    app, repo, personal_store, resolver=rekey_during_resolve
                );
                client = httpx.AsyncClient(
                    transport=httpx.ASGITransport(app=app), base_url="http://test"
                );
                async with client {
                    response = await client.post(
                        "/api/me/sources",
                        headers=ALICE,
                        json={"connection_id": cid, "locator": "failure"}
                    );
                    assert response.status_code == 422;
                    current = await personal_store.get_connection(uid, cid);
                    assert current["status"] == "configured";
                    assert current["last_error"] == "";
                    assert current["retry_at"] == "";
                    assert await personal_store.connection_secret(cid)
                        == "replacement-race-key";
                    response = await client.post(
                        "/api/me/sources",
                        headers=ALICE,
                        json={"connection_id": cid, "locator": "success"}
                    );
                    assert response.status_code == 422;
                    assert await personal_store.list_sources(uid) == [];
                    assert await personal_store.connection_secret(cid)
                        == "latest-race-key";
                    assert (await personal_store.get_connection(uid, cid))["status"]
                        == "configured";
                }
            }
        }
    }
    asyncio.run(run());
}
