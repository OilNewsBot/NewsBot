"""Offline integration: existing notify/SSE/backfill -> durable Expo delivery."""

import asyncio;
import contextlib;
import os;
import from unittest.mock { patch }
import from fastapi { FastAPI }
import time;
import httpx;
import from app { create_app }
import from db.repo { Repo, Row }
import from mobile.push { PushService, install_mobile }
import from pipeline.notify { Bus, notify }
import from tests.helpers { make_settings, open_repo }

obj ExpoStub {
    has calls: list[Row] = [],
        status: int = 200,
        error: str = "",
        data: Row = {"status": "ok", "id": "ticket-1"};

    async def post(url: str, *, json: Row) -> httpx.Response {
        self.calls.append(json);
        if self.error == "timeout" {
            raise httpx.ReadTimeout("offline stub");
        }
        if self.error == "connect" {
            raise httpx.ConnectError("offline stub");
        }
        return httpx.Response(
            self.status, json={"data": self.data}, request=httpx.Request("POST", url)
        );
    }
}

async def publish(repo: Repo, bus: Bus, kind: str = "NEW_EVENT") -> int {
    return await notify(
        repo,
        bus,
        {
            "kind": kind,
            "post_id": 1,
            "event_id": None,
            "one_line": "Port traffic interrupted",
            "what_changed": "Details confirmed" if kind == "UPDATE" else ""
        }
    );
}

test "mobile_pipeline_delivery" {
    async def run {
        settings = make_settings();
        async with open_repo(settings) as repo {
            service = PushService(repo);
            await service.initialize();
            bus = Bus();
            # Existing history must not buzz a newly opted-in phone.
            await publish(repo, bus);
            await service.subscribe("phone", "ExpoPushToken[first]", True);
            async with bus.subscribe() as queue {
                nid = await publish(repo, bus);
                assert (await queue.get())["notification_id"] == nid;
            }
            assert (await repo.notifications_since(nid - 1))[0]["notification_id"]
                == nid;
            client = ExpoStub();
            await service.send_pending(client);
            assert len(client.calls) == 1;
            assert client.calls[0]["data"]["notification_id"] == nid;
            assert client.calls[0]["title"] == "NewsBot";
            assert client.calls[0]["channelId"] == "newsbot";
            await service.send_pending(client);
            # Even a new worker / DB connection uses the persisted claim.
            async with open_repo(settings) as reopened {
                restarted = PushService(reopened);
                await restarted.initialize();
                await restarted.send_pending(client);
            }
            assert len(client.calls) == 1;
            await publish(repo, bus, "UPDATE");
            await publish(repo, bus, "UNFILTERED");
            await service.send_pending(client);
            assert client.calls[1]["body"] == "Details confirmed";
            assert client.calls[2]["title"] == "NewsBot · Unfiltered";
        }
    }
    asyncio.run(run());
}

test "mobile_toggle_and_rotation" {
    async def run {
        async with open_repo(make_settings()) as repo {
            service = PushService(repo);
            await service.initialize();
            bus = Bus();
            client = ExpoStub();
            await service.subscribe("phone", "ExpoPushToken[old]", True);
            await publish(repo, bus);
            # Idempotent registration and rotation must preserve undelivered work.
            await service.subscribe("phone", "ExpoPushToken[new]", True);
            await service.send_pending(client);
            assert client.calls[0]["to"] == "ExpoPushToken[new]";
            await service.subscribe("phone", None, False);
            await publish(repo, bus);
            await service.send_pending(client);
            assert len(client.calls) == 1;
            await service.subscribe("phone", "ExpoPushToken[new]", True);
            await service.send_pending(client);
            assert len(client.calls) == 1;  # no disabled-period backfill
            await publish(repo, bus);
            await service.send_pending(client);
            assert len(client.calls) == 2;
        }
    }
    asyncio.run(run());
}

test "mobile_failure_semantics" {
    async def run {
        async with open_repo(make_settings()) as repo {
            service = PushService(repo);
            await service.initialize();
            await service.subscribe("phone", "ExpoPushToken[first]", True);
            await publish(repo, Bus());
            client = ExpoStub(status=429);
            try {
                await service.send_pending(client);
            } except RuntimeError {}
            assert not await repo._all("SELECT * FROM mobile_deliveries");
            client.status = 200;
            client.error = "connect";
            try {
                await service.send_pending(client);
            } except httpx.ConnectError {}
            assert not await repo._all("SELECT * FROM mobile_deliveries");
            client.error = "timeout";
            try {
                await service.send_pending(client);
            } except httpx.ReadTimeout {}
            assert len(await repo._all("SELECT * FROM mobile_deliveries")) == 1;
            client.error = "";
            await service.send_pending(client);
            assert len(client.calls) == 3;  # no duplicate after ambiguous timeout
        }
    }
    asyncio.run(run());
}

test "mobile_receipts_and_invalid_tokens" {
    async def run {
        async with open_repo(make_settings()) as repo {
            service = PushService(repo);
            await service.initialize();
            await service.subscribe("phone", "ExpoPushToken[first]", True);
            await publish(repo, Bus());
            client = ExpoStub();
            await service.send_pending(client);
            await repo._run(
                "UPDATE mobile_deliveries SET created_at = ?", (time.time() - 1000, )
            );
            await repo.db.commit();
            client.data = {
                "ticket-1": {
                    "status": "error",
                    "details": {"error": "DeviceNotRegistered"}
                }
            };
            await service.check_receipts(client);
            assert (await repo._all("SELECT * FROM mobile_subscriptions"))[0]["enabled"]
                == 0;
            assert (await repo._all("SELECT * FROM mobile_deliveries"))[0]["ticket_id"]
                is None;
            # A delayed old-token error cannot disable the new token.
            await service.subscribe("phone", "ExpoPushToken[rotated]", True);
            await service.invalidate(
                {"device_id": "phone", "token": "ExpoPushToken[first]"}
            );
            assert (await repo._all("SELECT * FROM mobile_subscriptions"))[0]["enabled"]
                == 1;
            await publish(repo, Bus());
            client.data = {
                "status": "error",
                "details": {"error": "DeviceNotRegistered"}
            };
            await service.send_pending(client);
            assert (await repo._all("SELECT * FROM mobile_subscriptions"))[0]["enabled"]
                == 0;
        }
    }
    asyncio.run(run());
}

test "mobile_http_contract" {
    async def run {
        settings = make_settings();
        with patch.dict(os.environ, {"NEWSBOT_MOBILE_PUSH": "1"}) {
            app = create_app(settings);
        }
        repo = getattr(app.state, "repo") as Repo;
        await repo.connect();
        try {
            service = PushService(repo);
            await service.initialize();
            # ASGITransport deliberately skips lifespan: no live feed adapters.
            client = httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="http://test"
            );
            async with client {
                path = "/mobile/subscription";
                headers = {"Authorization": "Bearer " + "a" * 64};
                body = {"enabled": True, "token": "ExpoPushToken[first]"};
                assert (await client.put(path, json=body)).status_code == 401;
                assert (
                    await client.put(path, headers=headers, json={"enabled": "yes"})
                ).status_code
                    == 422;
                assert (
                    await client.put(
                        path, headers=headers, json={"enabled": True, "token": "bad"}
                    )
                ).status_code
                    == 422;
                assert (
                    await client.put(path, headers=headers, content="{")
                ).status_code
                    == 422;
                assert (
                    await client.put(path, headers=headers, content="x" * 2049)
                ).status_code
                    == 413;
                assert (await client.put(path, headers=headers, json=body)).status_code
                    == 200;
                assert (await client.put(path, headers=headers, json=body)).status_code
                    == 200;
                other = {"Authorization": "Bearer " + "b" * 64};
                assert (await client.put(path, headers=other, json=body)).status_code
                    == 409;
                nid = await publish(repo, Bus());
                feed = (await client.get("/notifications")).json();
                assert feed[0]["notification_id"] == nid;
                assert (
                    await client.put(path, headers=headers, json={"enabled": False})
                ).status_code
                    == 200;
                assert (await repo._all("SELECT * FROM mobile_subscriptions"))[0][
                    "enabled"
                ]
                    == 0;
            }
        } finally {
            await repo.close();
        }
        with patch.dict(os.environ, {"NEWSBOT_MOBILE_PUSH": ""}) {
            disabled = create_app(settings);
        }
        client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=disabled), base_url="http://test"
        );
        async with client {
            assert (
                await client.put("/mobile/subscription", json={"enabled": False})
            ).status_code
                == 404;
        }
    }
    asyncio.run(run());
}

test "mobile_multiple_devices_and_successful_receipt" {
    async def run {
        async with open_repo(make_settings()) as repo {
            service = PushService(repo);
            await service.initialize();
            await service.subscribe("one", "ExpoPushToken[one]", True);
            await service.subscribe("two", "ExpoPushToken[two]", True);
            nid = await publish(repo, Bus());
            client = ExpoStub();
            await service.send_pending(client);
            assert len(client.calls) == 2;
            assert {c["to"] for c in client.calls}
                == {"ExpoPushToken[one]", "ExpoPushToken[two]"};
            assert all(c["data"]["notification_id"] == nid for c in client.calls);
            await service.send_pending(client);
            assert len(client.calls) == 2;
            await repo._run(
                "UPDATE mobile_deliveries SET created_at = ?", (time.time() - 1000, )
            );
            await repo.db.commit();
            client.data = {"ticket-1": {"status": "ok"}};
            await service.check_receipts(client);
            assert all(
                r["ticket_id"] is None
                for r in await repo._all("SELECT * FROM mobile_deliveries")
            );
            await service.subscribe("one", None, False);
            client.calls.clear();
            client.data = {"status": "ok", "id": "ticket-2"};
            await publish(repo, Bus());
            await service.send_pending(client);
            assert len(client.calls) == 1
                and client.calls[0]["to"] == "ExpoPushToken[two]";
        }
    }
    asyncio.run(run());
}

test "mobile_preserves_original_lifespan" {
    async def run {
        repo = Repo(make_settings().db_path);
        events: list[str] = [];
        @contextlib.asynccontextmanager
        async def original(app: FastAPI) -> AsyncIterator[Row] {
            events.append("original start");
            await repo.connect();
            try {
                yield {"original": True};
            } finally {
                events.append("original stop");
                await repo.close();
            }
        }
        async def worker(self: any) {
            events.append("mobile start");
            try {
                await asyncio.Event().wait();
            } finally {
                events.append("mobile stop");
            }
        }
        app = FastAPI(lifespan=original);
        routes = list(app.routes);
        with patch.dict(os.environ, {"NEWSBOT_MOBILE_PUSH": ""}) {
            install_mobile(app, repo);
            assert app.router.lifespan_context is original;
            assert app.routes == routes;
        }
        with patch.dict(os.environ, {"NEWSBOT_MOBILE_PUSH": "1"}), patch.object(
            PushService, "run", worker
        ) {
            install_mobile(app, repo);
            async with app.router.lifespan_context(app) as state {
                await asyncio.sleep(0);
                assert state == {"original": True};
                assert events == ["original start", "mobile start"];
            }
        }
        assert events
            == ["original start", "mobile start", "mobile stop", "original stop"];
    }
    asyncio.run(run());
}
