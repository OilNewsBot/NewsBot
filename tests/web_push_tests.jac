"""Replay news through the personal collector and exercise the real push API."""

import asyncio;
import os;
import httpx;
import from unittest.mock { patch }
import from app { create_app }
import from db.repo { Repo, Row }
import from personal.store { PERSONAL_ALERT_ELIGIBILITY, PersonalStore }
import from pwa.demo { collect_fixture, fixture_item }
import from pwa.service { PushService }
import from pwa.transport { WebPush, encode }
import from tests.helpers { make_settings }

glob API: str = "/api/me/web-push",
     PRIVATE_KEY: str = encode(bytes(range(32))),
     PUBLIC_KEY: str = str(WebPush(PRIVATE_KEY, "mailto:push@example.test").public_key),
     PASSWORD: str = "offline-password";

obj MockPush {
    has public_key: str = PUBLIC_KEY,
        calls: list[Row] = [],
        gone: str = "",
        limited: bool = False;

    async def send(_client: any, subscription: Row, ticket: str) -> int {
        self.calls.append({"endpoint": subscription["endpoint"], "ticket": ticket});
        if self.limited {
            return 429;
        }
        return 410 if self.gone == subscription["endpoint"] else 201;
    }
}

def login_data(name: str) -> Row {
    return {"email": name + "@example.test", "password": PASSWORD};
}

async def login(client: httpx.AsyncClient, name: str) {
    response = await client.post("/login", json=login_data(name));
    assert response.status_code == 200 , response.text;
    assert "Secure" in response.headers["set-cookie"];
    assert "HttpOnly" in response.headers["set-cookie"];
}

async def status(client: httpx.AsyncClient, endpoint: str | None = None) -> Row {
    response = await client.post(API + "/status", json={"endpoint": endpoint});
    assert response.status_code == 200 , response.text;
    assert response.headers["cache-control"] == "no-store";
    assert PRIVATE_KEY not in response.text;
    return response.json();
}

def device(name: str, binding: str) -> Row {
    return {
        "endpoint": "https://fcm.googleapis.com/fcm/send/" + name,
        "binding": binding,
        "keys": {
            "p256dh": WebPush(
                encode(bytes(range(1, 33))), "mailto:device@example.test"
            ).public_key,
            "auth": encode(bytes(range(16)))
        }
    };
}

async def register(client: httpx.AsyncClient, name: str) -> Row {
    body = device(name, (await status(client))["binding"]);
    response = await client.put(API + "/subscription", json=body);
    assert response.status_code == 204 , response.text;
    assert (await status(client, body["endpoint"]))["active"];
    return body;
}

test "web_push_routes_personal_fixture_only_to_eligible_active_devices" {
    async def run {
        settings = make_settings();
        mock = MockPush();
        with patch.dict(
            os.environ,
            {
                "NEWSBOT_PUBLIC_PWA": "1",
                "NEWSBOT_VAPID_PRIVATE_KEY": PRIVATE_KEY,
                "NEWSBOT_VAPID_SUBJECT": "mailto:push@example.test"
            }
        ) {
            app = create_app(settings);
        }
        repo = getattr(app.state, "repo") as Repo;
        store = getattr(app.state, "personal") as PersonalStore;
        service: any = getattr(app.state, "web_push");
        assert service.public_key == PUBLIC_KEY;
        service.transport = mock;
        await repo.connect();
        await store.connect();
        await service.connect();
        try {
            asgi = httpx.ASGITransport(app=app);
            base_url = "https://test.example";
            alice = httpx.AsyncClient(transport=asgi, base_url=base_url);
            tablet = httpx.AsyncClient(transport=asgi, base_url=base_url);
            bob = httpx.AsyncClient(transport=asgi, base_url=base_url);
            async with alice, tablet, bob {
                assert (await alice.post(API + "/status", json={})).status_code == 401;
                assert (await alice.post("/ingest", json={})).status_code == 404;
                assert (await alice.post("/refetch")).status_code == 401;
                for name in ["alice", "bob"] {
                    assert (
                        await alice.post(
                            "/register", json=login_data(name) | {"username": name}
                        )
                    ).status_code
                        == 200;
                }
                await login(alice, "alice");
                await login(tablet, "alice");
                await login(bob, "bob");
                a_uid = (await alice.get("/me")).json()["user_id"];
                b_uid = (await bob.get("/me")).json()["user_id"];
                assert (await status(alice))["publicKey"] == PUBLIC_KEY;
                assert (
                    await alice.post(
                        API + "/status",
                        headers={"Origin": "https://different.example"},
                        json={}
                    )
                ).status_code
                    == 403;
                a_conn = await store.create_connection(a_uid, "rss", "Kharg news");
                b_conn = await store.create_connection(b_uid, "rss", "Company news");
                a_src = await store.create_source(
                    a_uid,
                    a_conn["id"],
                    "kharg",
                    "Kharg",
                    "https://example.org/kharg",
                    include_keywords=["kharg"],
                    exclude_keywords=["wire"]
                );
                b_src = await store.create_source(
                    b_uid,
                    b_conn["id"],
                    "earnings",
                    "Earnings",
                    "https://example.org/earnings",
                    include_keywords=["earnings"]
                );
                for src in [a_src, b_src] {
                    await store.persist_batch(src["id"], [], "baseline");
                }
                a_src = await store.get_source(a_uid, a_src["id"]);
                b_src = await store.get_source(b_uid, b_src["id"]);
                device_a = await register(alice, "alice-browser");
                device_t = await register(tablet, "alice-tablet");
                device_b = await register(bob, "bob-browser");
                assert (
                    await alice.put(API + "/subscription", json=device_a)
                ).status_code
                    == 204;
                other = device_a | {"binding": device_b["binding"]};
                assert (await bob.put(API + "/subscription", json=other)).status_code
                    == 409;
                assert (
                    await bob.request("DELETE", API + "/subscription", json=other)
                ).status_code
                    == 204;
                assert (await status(alice, device_a["endpoint"]))["active"];
                assert not (await status(bob, device_a["endpoint"]))["active"];
                assert (
                    await bob.put(
                        API + "/subscription",
                        json=device_b | {"endpoint": "https://127.0.0.1/push"}
                    )
                ).status_code
                    == 422;
                post = fixture_item("9002000001");
                await collect_fixture(store, a_src, fixture_item("9002000004"));
                await collect_fixture(store, b_src, post);
                await collect_fixture(store, a_src, post);
                alerts = (await alice.get("/api/me/notifications")).json()[
                    "notifications"
                ];
                assert len(alerts) == 1;
                assert alerts[0]["text"] == post["text"];
                assert (await bob.get("/api/me/notifications")).json()["notifications"]
                    == [];
                assert len((await bob.get("/api/me/feed")).json()["items"]) == 1;
                oldest = alerts[0]["id"];
                # A notification may outlive the latest hundred news items.
                for i in range(101) {
                    await store.db.execute(
                        "INSERT INTO personal_items(user_id,source_id,external_id,title,text,url,posted_at,received_at) VALUES (?,?,?,'fixture','','','2099-01-01','2099-01-01')",
                        (a_uid, a_src["id"], f"recent-{i}")
                    );
                }
                await store.db.commit();
                latest = (await alice.get("/api/me/feed")).json()["items"];
                assert len(latest) == 100
                    and oldest not in [item["id"] for item in latest];
                linked = (await alice.get(f"/api/me/feed?linked_id={oldest}")).json()[
                    "items"
                ];
                assert len(linked) == 101 and linked[-1]["id"] == oldest;
                other_feed = (await bob.get(f"/api/me/feed?linked_id={oldest}")).json()[
                    "items"
                ];
                assert oldest not in [item["id"] for item in other_feed];
                mock.limited = True;
                await service.send_pending(None);
                assert len(mock.calls) == 2;
                await service.send_pending(None);
                assert len(mock.calls) == 2;  # both devices are in backoff
                mock.limited = False;
                mock.calls.clear();
                await service.db.execute("UPDATE web_push_deliveries SET retry_at=0");
                await asyncio.gather(
                    service.send_pending(None), service.send_pending(None)
                );
                assert len(mock.calls) == 2;
                assert {call["endpoint"] for call in mock.calls}
                    == {device_a["endpoint"], device_t["endpoint"]};
                ticket = next(
                    call["ticket"]
                    for call in mock.calls
                    if call["endpoint"] == device_a["endpoint"]
                );
                assert (
                    await alice.post(API + "/destination", json={"ticket": ticket})
                ).json()
                    == {"itemId": alerts[0]["id"]};
                assert (
                    await bob.post(API + "/destination", json={"ticket": ticket})
                ).status_code
                    == 404;
                assert (
                    await tablet.post(API + "/destination", json={"ticket": ticket})
                ).status_code
                    == 404;
                assert (
                    await bob.request("DELETE", API + "/subscription", json=device_b)
                ).status_code
                    == 204;
                assert not (await status(bob, device_b["endpoint"]))["active"];
                await collect_fixture(store, a_src, post);
                reopened = PushService(
                    settings.db_path, mock, PERSONAL_ALERT_ELIGIBILITY
                );
                await reopened.connect();
                try {
                    await reopened.send_pending(None);
                    assert len(mock.calls) == 2;

                    next_post = fixture_item("9002000002");
                    await collect_fixture(store, a_src, next_post);
                    await store.update_source(
                        a_uid, a_src["id"], {"alerts_enabled": False}
                    );
                    await collect_fixture(
                        store,
                        await store.get_source(a_uid, a_src["id"]),
                        fixture_item("9002000003")
                    );
                    await reopened.send_pending(None);
                    assert len(mock.calls) == 2;
                    await store.update_source(
                        a_uid, a_src["id"], {"alerts_enabled": True}
                    );
                    await reopened.send_pending(None);
                    assert len(mock.calls) == 2;

                    await login(alice, "bob");
                    assert (
                        await alice.put(API + "/subscription", json=device_a)
                    ).status_code
                        == 409;
                    assert (
                        await alice.post(API + "/destination", json={"ticket": ticket})
                    ).status_code
                        == 404;
                    assert (await bob.post("/logout")).status_code == 200;
                    assert (await bob.post(API + "/status", json={})).status_code
                        == 401;
                    fresh = await store.get_source(a_uid, a_src["id"]);
                    await collect_fixture(store, fresh, fixture_item("9002000005"));
                    mock.gone = device_t["endpoint"];
                    await reopened.send_pending(None);
                    assert len(mock.calls) == 3;
                    assert mock.calls[-1]["endpoint"] == device_t["endpoint"];
                    assert not (await status(tablet, device_t["endpoint"]))["active"];

                    replacement = await register(tablet, "replacement");
                    await repo.db.execute(
                        "UPDATE sessions SET expires_at = '2000-01-01 00:00:00' WHERE user_id = ?",
                        (a_uid, )
                    );
                    await repo.db.commit();
                    await reopened.prune();
                    await reopened.send_pending(None);
                    assert len(mock.calls) == 3;
                    assert (
                        await tablet.post(
                            API + "/status", json={"endpoint": replacement["endpoint"]}
                        )
                    ).status_code
                        == 401;
                } finally {
                    await reopened.close();
                }
            }
        } finally {
            await service.close();
            await store.close();
            await repo.close();
        }
    }
    asyncio.run(run());
}
