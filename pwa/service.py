"""Durable fan-out of existing account-owned notifications."""

import asyncio
import logging
import secrets
from pathlib import Path

import aiosqlite
import httpx

from personal.coverage import item_section

LOG = logging.getLogger("newsstream.web_push")
SCHEMA = Path(__file__).with_name("schema.sql").read_text(encoding="utf-8")

# A browser subscription is leased to the exact session that opted in. This join
# applies immediately on logout or replacement, even before expired rows are pruned.
ACTIVE = """
  JOIN sessions session ON session.token_hash = d.session_hash
    AND session.user_id = d.user_id AND session.expires_at > CURRENT_TIMESTAMP
"""
FRESH = "julianday(n.created_at) > julianday('now', '-5 minutes')"


class PushService:
    def __init__(self, db_path, transport, eligibility):
        self.db_path = db_path
        self.transport = transport
        self.eligible = f"""
            FROM web_push_subscriptions d
            {ACTIVE}
            JOIN personal_notifications n ON n.user_id = d.user_id AND n.id > d.since_id
            JOIN personal_sources s ON s.id = n.source_id AND s.user_id = n.user_id
            JOIN personal_connections c ON c.id = s.connection_id AND c.user_id = n.user_id
            JOIN personal_items i ON i.id = n.item_id AND i.user_id = n.user_id
            LEFT JOIN personal_source_tags t ON t.source_id = s.id
            WHERE d.vapid_key = ? AND {eligibility}
        """

    @property
    def public_key(self):
        return self.transport.public_key if self.transport else None

    async def connect(self):
        self.db = await aiosqlite.connect(self.db_path, isolation_level=None)
        self.db.row_factory = aiosqlite.Row
        await self.db.create_function("item_section", 3, item_section, deterministic=True)
        await self.db.execute("PRAGMA busy_timeout = 5000")
        await self.db.execute("PRAGMA foreign_keys = ON")
        await self.db.executescript(SCHEMA)

    async def close(self):
        await self.db.close()

    async def registered(self, user, endpoint):
        rows = await self.db.execute_fetchall(
            f"""SELECT d.p256dh, d.auth FROM web_push_subscriptions d {ACTIVE}
                WHERE d.endpoint = ? AND d.user_id = ? AND d.session_hash = ?
                AND d.vapid_key = ?""",
            (endpoint, user["user_id"], user["token_hash"], self.public_key),
        )
        return rows[0] if rows else None

    async def subscribe(self, user, endpoint, p256dh, auth):
        # The endpoint is unique. Another session cannot update a live registration.
        await self.prune(endpoint)
        await self.db.execute(
            """INSERT INTO web_push_subscriptions
               (user_id, session_hash, endpoint, p256dh, auth, vapid_key, since_id)
               SELECT session.user_id, session.token_hash, ?, ?, ?, ?,
                 (SELECT COALESCE(MAX(id), 0) FROM personal_notifications n
                  WHERE n.user_id = session.user_id)
               FROM sessions session
               WHERE session.token_hash = ? AND session.user_id = ?
                 AND session.expires_at > CURRENT_TIMESTAMP
               ON CONFLICT(endpoint) DO NOTHING""",
            (endpoint, p256dh, auth, self.public_key, user["token_hash"], user["user_id"]),
        )
        existing = await self.registered(user, endpoint)
        return bool(existing and existing["p256dh"] == p256dh and existing["auth"] == auth)

    async def revoke(self, user, endpoint):
        await self.db.execute(
            "DELETE FROM web_push_subscriptions WHERE endpoint = ? AND user_id = ? AND session_hash = ?",
            (endpoint, user["user_id"], user["token_hash"]),
        )

    async def prune(self, endpoint=None):
        sql = """DELETE FROM web_push_subscriptions
                 WHERE (vapid_key <> ? OR NOT EXISTS (
                   SELECT 1 FROM sessions WHERE token_hash = session_hash
                   AND user_id = web_push_subscriptions.user_id
                   AND expires_at > CURRENT_TIMESTAMP))"""
        if endpoint is None:
            await self.db.execute(sql, (self.public_key,))
        else:
            await self.db.execute(sql + " AND endpoint = ?", (self.public_key, endpoint))

    async def destination(self, user, ticket):
        rows = await self.db.execute_fetchall(
            f"""SELECT n.item_id {self.eligible} AND d.session_hash = ? AND d.user_id = ?
                AND EXISTS (SELECT 1 FROM web_push_deliveries claim WHERE claim.ticket = ?
                  AND claim.subscription_id = d.id AND claim.notification_id = n.id)""",
            (self.public_key, user["token_hash"], user["user_id"], ticket),
        )
        return rows[0]["item_id"] if rows else None

    async def send_pending(self, client):
        rows = await self.db.execute_fetchall(
            f"""SELECT d.*, n.id AS notification_id {self.eligible} AND {FRESH}
                AND NOT EXISTS (SELECT 1 FROM web_push_deliveries claim
                  WHERE claim.subscription_id = d.id AND claim.notification_id = n.id)
                ORDER BY n.id, d.id LIMIT 64""",
            (self.public_key,),
        )
        for offset in range(0, len(rows), 8):
            await asyncio.gather(*(self.deliver(client, row) for row in rows[offset:offset + 8]))

    async def deliver(self, client, row):
        ticket = secrets.token_urlsafe(24)
        # Recheck preferences and session atomically before claiming. Commit before I/O.
        cursor = await self.db.execute(
            f"""INSERT OR IGNORE INTO web_push_deliveries (subscription_id, notification_id, ticket)
                SELECT d.id, n.id, ? {self.eligible} AND {FRESH} AND d.id = ? AND n.id = ?""",
            (ticket, self.public_key, row["id"], row["notification_id"]),
        )
        if cursor.rowcount != 1:
            return
        # No retries after a submission attempt: a lost response may already have
        # produced an OS notification. Requests in flight carry no private content.
        try:
            status = await self.transport.send(client, row, ticket)
            if status in (404, 410):
                await self.db.execute("DELETE FROM web_push_subscriptions WHERE id = ?", (row["id"],))
            elif not 200 <= status < 300:
                LOG.warning("browser push service rejected notification (%d)", status)
        except Exception:
            LOG.warning("browser push submission failed")

    async def run(self):
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(8.0), follow_redirects=False, trust_env=False
        ) as client:
            loop = asyncio.get_running_loop()
            next_prune = 0
            while True:
                try:
                    if loop.time() >= next_prune:
                        await self.prune()
                        next_prune = loop.time() + 60
                    await self.send_pending(client)
                except Exception:
                    LOG.warning("web push sweep failed")
                await asyncio.sleep(2)
