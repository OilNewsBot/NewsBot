"""Expo push fan-out of persisted NewsBot notifications. No second news pipeline.

Claims are durable before HTTP submission. Ambiguous submissions are never retried:
Expo has no idempotency key, so retrying a timeout could show duplicate phone alerts.
"""

import asyncio;
import contextlib;
import os;
import hashlib;
import json;
import logging;
import re;
import time;
import httpx;
import from pathlib { Path }
import from fastapi { FastAPI, HTTPException, Request }
import from sqlite3 { IntegrityError }
import from db.repo { Repo, Row }

glob log: logging.Logger = logging.getLogger("newsstream.mobile"),
     SCHEMA: str = (Path(__file__).parent / "schema.sql").read_text(),
     EXPO_URL: str = "https://exp.host/--/api/v2/push/";

def push_message(row: Row) -> Row {
    card = json.loads(row["payload"]);
    kind = str(card.get("kind", "NEW_EVENT"));
    body = str(card.get("what_changed") or card.get("one_line") or "NewsBot update");
    return {
        "to": row["token"],
        "title": "NewsBot"
            + (
                " · Update"
                    if kind == "UPDATE"
                    else " · Unfiltered" if kind == "UNFILTERED" else ""
            ),
        "body": body[:500],
        "sound": "default",
        "channelId": "newsbot",
        "priority": "high",
        "ttl": 3600,
        "data": {"notification_id": row["notification_id"], "kind": kind}
    };
}

obj PushService {
    has repo: Repo,
        access_token: str = "";

    async def initialize {
        await self.repo.db.executescript(SCHEMA);
        await self.repo.db.commit();
    }

    async def subscribe(device_id: str, token: str | None, enabled: bool) {
        # A token belongs to one installation. Knowing somebody else's Expo
        # token is insufficient to modify or disable their subscription.
        owner = await self.repo._one(
            "SELECT device_id FROM mobile_subscriptions WHERE token = ?", (token, )
        );
        if owner and owner["device_id"] != device_id {
            raise HTTPException(
                409, "Push token already registered to another installation"
            );
        }
        await self.repo._run(
            """INSERT INTO mobile_subscriptions (device_id, token, enabled, since_id)
               VALUES (?, ?, ?, (SELECT COALESCE(MAX(id), 0) FROM notifications))
               ON CONFLICT(device_id) DO UPDATE SET
                 token = COALESCE(excluded.token, mobile_subscriptions.token),
                 enabled = excluded.enabled,
                 since_id = CASE WHEN mobile_subscriptions.enabled = 0 OR excluded.enabled = 0
                   THEN excluded.since_id ELSE mobile_subscriptions.since_id END""",
            (device_id, token, int(enabled))
        );
        await self.repo.db.commit();
    }

    async def invalidate(row: Row) {
        await self.repo._run(
            "UPDATE mobile_subscriptions SET enabled = 0 WHERE device_id = ? AND token = ?",
            (row["device_id"], row["token"])
        );
        await self.repo.db.commit();
    }

    async def send_pending(client: any) {
        rows = await self.repo._all(
            """SELECT s.device_id, s.token, n.id AS notification_id, n.payload
               FROM mobile_subscriptions s JOIN notifications n ON n.id > s.since_id
               WHERE s.enabled = 1 AND NOT EXISTS (
                 SELECT 1 FROM mobile_deliveries d
                 WHERE d.device_id = s.device_id AND d.notification_id = n.id)
               ORDER BY n.id LIMIT 100"""
        );
        for row in rows {
            # Recheck enabled/since_id after selection, and atomically claim.
            claim = await self.repo._run(
                """INSERT OR IGNORE INTO mobile_deliveries
                   (device_id, notification_id, token, created_at)
                   SELECT device_id, ?, token, ? FROM mobile_subscriptions
                   WHERE device_id = ? AND enabled = 1 AND token = ? AND since_id < ?""",
                (
                    row["notification_id"],
                    time.time(),
                    row["device_id"],
                    row["token"],
                    row["notification_id"]
                )
            );
            await self.repo.db.commit();
            if claim.rowcount != 1 {
                continue;
            }
            try {
                response = await client.post(EXPO_URL + "send", json=push_message(row));
                if response.status_code == 429 {
                    # Explicit refusal: Expo did not enqueue the message.
                    await self.release(row);
                    raise RuntimeError("Expo rate limit; backing off");
                }
                response.raise_for_status();
                ticket = response.json()["data"];
                if ticket.get("status") == "ok" and ticket.get("id") {
                    await self.repo._run(
                        "UPDATE mobile_deliveries SET ticket_id = ? WHERE device_id = ? AND notification_id = ?",
                        (str(ticket["id"]), row["device_id"], row["notification_id"])
                    );
                    await self.repo.db.commit();
                } else {
                    error = str(
                        ticket.get("details", {}).get("error", "InvalidTicket")
                    );
                    if error == "DeviceNotRegistered" {
                        await self.invalidate(row);
                    }
                    log.warning("push %s rejected: %s", row["notification_id"], error);
                }
            } except (httpx.ConnectError, httpx.ConnectTimeout) {
                # No HTTP request reached Expo; safe to retry after backoff.
                await self.release(row);
                raise;
            } except RuntimeError {
                raise;
            } except Exception {
                log.warning(
                    "push %s submission uncertain; not retrying", row["notification_id"]
                );
                raise;
            }
        }
    }

    async def release(row: Row) {
        await self.repo._run(
            "DELETE FROM mobile_deliveries WHERE device_id = ? AND notification_id = ?",
            (row["device_id"], row["notification_id"])
        );
        await self.repo.db.commit();
    }

    async def check_receipts(client: any) {
        rows = await self.repo._all(
            "SELECT * FROM mobile_deliveries WHERE ticket_id IS NOT NULL AND created_at < ? ORDER BY created_at LIMIT 100",
            (time.time() - 900, )
        );
        if not rows {
            return;
        }
        response = await client.post(
            EXPO_URL + "getReceipts", json={"ids": [r["ticket_id"] for r in rows]}
        );
        response.raise_for_status();
        receipts = response.json()["data"];
        for row in rows {
            receipt = receipts.get(row["ticket_id"]);
            if not receipt and time.time() - row["created_at"] < 86400 {
                continue;
            }
            if receipt and receipt.get("status") != "ok" {
                if receipt.get("details", {}).get("error") == "DeviceNotRegistered" {
                    await self.invalidate(row);
                }
                log.warning("push %s receipt rejected", row["notification_id"]);
            }
            await self.repo._run(
                "UPDATE mobile_deliveries SET ticket_id = NULL WHERE device_id = ? AND notification_id = ?",
                (row["device_id"], row["notification_id"])
            );
        }
        await self.repo.db.commit();
    }

    async def run {
        headers = {"Authorization": "Bearer " + self.access_token}
            if self.access_token
            else {};
        delay = 1;
        receipt_check = 0.0;
        client = httpx.AsyncClient(timeout=15, headers=headers);
        async with client {
            while True {
                try {
                    if time.time() - receipt_check >= 60 {
                        await self.check_receipts(client);
                        receipt_check = time.time();
                    }
                    await self.send_pending(client);
                    delay = 1;
                } except asyncio.CancelledError {
                    raise;
                } except Exception {
                    # Never log tokens, authorization headers, or provider bodies.
                    log.warning(
                        "mobile push worker failed; retrying eligible work in %ss",
                        delay
                    );
                    delay = min(delay * 2, 60);
                }
                await asyncio.sleep(delay);
            }
        }
    }
}

def install_routes(app: FastAPI, service: PushService) {
    @app.put("/mobile/subscription")
    async def subscription(request: Request) -> Row {
        authorization = request.headers.get("authorization", "");
        if not re.fullmatch(r"Bearer [0-9a-f]{64}", authorization) {
            raise HTTPException(401, "Installation bearer secret required");
        }
        raw = b"";
        async for chunk in request.stream() {
            raw += chunk;
            if len(raw) > 2048 {
                raise HTTPException(413, "Subscription body too large");
            }
        }
        try {
            data = json.loads(raw);
        } except (ValueError, UnicodeDecodeError) {
            raise HTTPException(422, "Invalid JSON");
        }
        if not isinstance(data, dict) or type(data.get("enabled")) != bool {
            raise HTTPException(422, "enabled must be a boolean");
        }
        token = data.get("token");
        if token is not None
            and (
                not isinstance(token, str)
                or not re.fullmatch(
                    r"(?:Expo|Exponent)PushToken\[[A-Za-z0-9_-]{1,200}\]", token
                )
            ) {
            raise HTTPException(422, "Invalid Expo push token");
        }
        if data["enabled"] and not token {
            raise HTTPException(422, "Push token required");
        }
        device_id = hashlib.sha256(authorization[7:].encode()).hexdigest();
        try {
            await service.subscribe(device_id, token, data["enabled"]);
        } except IntegrityError {
            # The UNIQUE token constraint also protects simultaneous registrations.
            raise HTTPException(
                409, "Push token already registered to another installation"
            );
        }
        return {"enabled": data["enabled"]};
    }
}


"""Only integration hook: leave the original app/lifespan untouched when disabled."""
def install_mobile(app: FastAPI, repo: Repo) {
    if os.environ.get("NEWSBOT_MOBILE_PUSH") != "1" {
        return;
    }
    service = PushService(repo, os.environ.get("EXPO_ACCESS_TOKEN", ""));
    original = app.router.lifespan_context;

    @contextlib.asynccontextmanager
    async def lifespan(application: FastAPI) -> AsyncIterator[any] {
        # The original lifespan owns the database, adapters, and pipeline.
        async with original(application) as state {
            await service.initialize();
            task = asyncio.create_task(service.run(), name="mobile-push");
            try {
                yield state;
            } finally {
                task.cancel();
                await asyncio.gather(task, return_exceptions=True);
            }
        }
    }
    app.router.lifespan_context = lifespan;
    install_routes(app, service);
}
