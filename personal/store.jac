"""Private source storage. Every public read includes authenticated ownership.

Items, their notification intent, and polling checkpoints commit together. The
private tables never participate in legacy oil summaries or mobile broadcasts.
"""

import asyncio;
import json;
import os;
import aiosqlite;
import from datetime { UTC, datetime }
import from pathlib { Path }
import from db.repo { Row, iso, utcnow }
import from personal.secrets { SecretBox, credential_fingerprint }

glob SCHEMA: str = Path(__file__).with_name("schema.sql").read_text();

def keywords(value: any) -> list[str] {
    if not isinstance(value, list) or len(value) > 20 {
        raise ValueError("Use at most 20 keywords");
    }
    out: list[str] = [];
    for word in value {
        if not isinstance(word, str) or not word.strip() or len(word) > 80 {
            raise ValueError("Keywords must be nonempty text, at most 80 characters");
        }
        clean = word.strip().lower();
        if clean not in out {
            out.append(clean);
        }
    }
    return out;
}

obj PersonalStore {
    has db_path: Path | str,
        _db: aiosqlite.Connection | None = None;

    has _lock: asyncio.Lock postinit,
        vault: SecretBox postinit;

    def postinit {
        self._lock = asyncio.Lock();
        self.vault = SecretBox();
    }

    has db: aiosqlite.Connection {
        getter -> aiosqlite.Connection {
            assert self._db is not None , "PersonalStore.connect() not called";
            return self._db;
        }
    }

    async def connect {
        self._db = await aiosqlite.connect(self.db_path);
        self.db.row_factory = aiosqlite.Row;
        await self.db.execute("PRAGMA busy_timeout = 5000");
        await self.db.execute("PRAGMA foreign_keys = ON");
        await self.db.executescript(SCHEMA);
        await self.db.commit();
    }

    async def close {
        if self._db is not None {
            await self._db.close();
            self._db = None;
        }
    }

    async def _run(sql: str, args: tuple[any, ...] = ()) -> aiosqlite.Cursor {
        return (await self.db.execute(sql, args)) as aiosqlite.Cursor;
    }

    async def _all(sql: str, args: tuple[any, ...] = ()) -> list[Row] {
        return [dict(r) for r in await (await self._run(sql, args)).fetchall()];
    }

    async def _one(sql: str, args: tuple[any, ...] = ()) -> Row | None {
        row = await (await self._run(sql, args)).fetchone();
        return dict(row) if row else None;
    }

    static def _connection(row: Row) -> Row {
        return {
            key: row[key]
            for key in [
                "id",
                "provider",
                "label",
                "status",
                "last_error",
                "daily_limit",
                "created_at"
            ]
        }
            | {
                "requests_today": row["requests_today"]
                    if row["request_day"] == datetime.now(UTC).date().isoformat()
                    else 0
            };
    }

    static def _source(row: Row) -> Row {
        out = dict(row);
        out["include_keywords"] = json.loads(out["include_keywords"]);
        out["exclude_keywords"] = json.loads(out["exclude_keywords"]);
        out["enabled"] = bool(out["enabled"]);
        out["alerts_enabled"] = bool(out["alerts_enabled"]);
        return out;
    }

    async def list_connections(user_id: int) -> list[Row] {
        rows = await self._all(
            "SELECT * FROM personal_connections WHERE user_id=? AND deleted_at IS NULL ORDER BY id",
            (user_id, )
        );
        return [self._connection(r) for r in rows];
    }

    async def get_connection(user_id: int, connection_id: int) -> Row {
        row = await self._one(
            "SELECT * FROM personal_connections WHERE user_id=? AND id=? AND deleted_at IS NULL",
            (user_id, connection_id)
        );
        if row is None {
            raise KeyError("Connection not found");
        }
        return self._connection(row);
    }

    async def create_connection(
        user_id: int,
        provider: str,
        label: str,
        secret: str = "",
        daily_limit: int = 200
    ) -> Row {
        if provider not in ["rss", "x"] or not label.strip() or len(label) > 80 {
            raise ValueError("Choose RSS or X and a name up to 80 characters");
        }
        if not 1 <= daily_limit <= 10000 {
            raise ValueError("Daily request limit must be 1-10000");
        }
        secret = secret.strip();
        if provider == "x" and (not secret or len(secret) > 1024) {
            raise ValueError("A TwitterAPI.io key is required");
        }
        if provider == "x" and secret == os.environ.get("X_PUSH_API_KEY", "") {
            raise ValueError(
                "Use a separate key from the server's shared X connection"
            );
        }
        async with self._lock {
            try {
                count = await self._one(
                    "SELECT COUNT(*) AS n FROM personal_connections WHERE user_id=? AND deleted_at IS NULL",
                    (user_id, )
                );
                if count and count["n"] >= 10 {
                    raise ValueError("At most 10 active connections per account");
                }
                cur = await self._run(
                    "INSERT INTO personal_connections(user_id,provider,label,daily_limit,created_at) VALUES (?,?,?,?,?)",
                    (user_id, provider, label.strip(), daily_limit, iso(utcnow()))
                );
                cid = int(cur.lastrowid or 0);
                if provider == "x" {
                    encrypted = self.vault.seal(secret, f"{user_id}:{cid}:x");
                    await self._run(
                        "UPDATE personal_connections SET secret=?,fingerprint=? WHERE id=?",
                        (encrypted, credential_fingerprint(secret), cid)
                    );
                }
                await self.db.commit();
            } except aiosqlite.IntegrityError {
                await self.db.rollback();
                raise ValueError("This credential is already configured");
            } except Exception {
                await self.db.rollback();
                raise;
            }
        }
        return await self.get_connection(user_id, cid);
    }

    async def connection_secret(connection_id: int) -> str {
        row = await self._one(
            "SELECT * FROM personal_connections WHERE id=? AND deleted_at IS NULL",
            (connection_id, )
        );
        if row is None {
            raise KeyError("Connection not found");
        }
        if row["provider"] == "rss" {
            return "";
        }
        return self.vault.open(row["secret"], f"{row['user_id']}:{connection_id}:x");
    }

    async def reconnect_connection(
        user_id: int, connection_id: int, secret: str
    ) -> Row {
        conn = await self.get_connection(user_id, connection_id);
        if conn["provider"] != "x" or not secret.strip() or len(secret) > 1024 {
            raise ValueError("A TwitterAPI.io key is required");
        }
        secret = secret.strip();
        if secret == os.environ.get("X_PUSH_API_KEY", "") {
            raise ValueError(
                "Use a separate key from the server's shared X connection"
            );
        }
        async with self._lock {
            try {
                encrypted = self.vault.seal(secret, f"{user_id}:{connection_id}:x");
                await self._run(
                    "UPDATE personal_connections SET secret=?,fingerprint=?,status='connected',last_error='' WHERE id=? AND user_id=? AND deleted_at IS NULL",
                    (encrypted, credential_fingerprint(secret), connection_id, user_id)
                );
                await self._run(
                    "UPDATE personal_sources SET next_poll_at='',status='pending',last_error='' WHERE connection_id=? AND deleted_at IS NULL",
                    (connection_id, )
                );
                await self.db.commit();
            } except aiosqlite.IntegrityError {
                await self.db.rollback();
                raise ValueError("This credential is already configured");
            } except Exception {
                await self.db.rollback();
                raise;
            }
        }
        return await self.get_connection(user_id, connection_id);
    }

    async def delete_connection(user_id: int, connection_id: int) {
        async with self._lock {
            await self.get_connection(user_id, connection_id);
            now = iso(utcnow());
            await self._run(
                "UPDATE personal_connections SET status='disconnected',secret='',fingerprint=NULL,deleted_at=? WHERE user_id=? AND id=?",
                (now, user_id, connection_id)
            );
            await self._run(
                "UPDATE personal_sources SET enabled=0,deleted_at=? WHERE connection_id=? AND user_id=?",
                (now, connection_id, user_id)
            );
            await self.db.commit();
        }
    }

    async def list_sources(user_id: int) -> list[Row] {
        rows = await self._all(
            "SELECT s.*,c.provider FROM personal_sources s JOIN personal_connections c ON c.id=s.connection_id WHERE s.user_id=? AND s.deleted_at IS NULL AND c.deleted_at IS NULL ORDER BY s.id",
            (user_id, )
        );
        return [self._source(r) for r in rows];
    }

    async def get_source(user_id: int, source_id: int) -> Row {
        row = await self._one(
            "SELECT s.*,c.provider FROM personal_sources s JOIN personal_connections c ON c.id=s.connection_id WHERE s.user_id=? AND s.id=? AND s.deleted_at IS NULL AND c.deleted_at IS NULL",
            (user_id, source_id)
        );
        if row is None {
            raise KeyError("Source not found");
        }
        return self._source(row);
    }

    async def create_source(
        user_id: int,
        connection_id: int,
        remote_id: str,
        name: str,
        url: str,
        alerts_enabled: bool = True,
        include_keywords: list[str] = [],
        exclude_keywords: list[str] = []
    ) -> Row {
        inc = keywords(include_keywords);
        exc = keywords(exclude_keywords);
        if not remote_id
            or len(remote_id) > 2048
            or not name
            or len(name) > 300
            or len(url) > 2048 {
            raise ValueError("Invalid source details");
        }
        async with self._lock {
            await self.get_connection(user_id, connection_id);
            count = await self._one(
                "SELECT COUNT(*) AS n FROM personal_sources WHERE user_id=? AND deleted_at IS NULL",
                (user_id, )
            );
            if count and count["n"] >= 50 {
                raise ValueError("At most 50 sources per account");
            }
            try {
                cur = await self._run(
                    "INSERT INTO personal_sources(user_id,connection_id,remote_id,name,url,alerts_enabled,include_keywords,exclude_keywords,created_at) VALUES (?,?,?,?,?,?,?,?,?)",
                    (
                        user_id,
                        connection_id,
                        remote_id,
                        name,
                        url,
                        int(alerts_enabled),
                        json.dumps(inc),
                        json.dumps(exc),
                        iso(utcnow())
                    )
                );
                sid = int(cur.lastrowid or 0);
                await self.db.commit();
            } except aiosqlite.IntegrityError {
                await self.db.rollback();
                raise ValueError("This source is already followed on that connection");
            }
        }
        return await self.get_source(user_id, sid);
    }

    async def update_source(user_id: int, source_id: int, changes: Row) -> Row {
        allowed = ["enabled", "alerts_enabled", "include_keywords", "exclude_keywords"];
        if not changes or any(k not in allowed for k in changes) {
            raise ValueError("Unsupported source setting");
        }
        for k in ["enabled", "alerts_enabled"] {
            if k in changes and not isinstance(changes[k], bool) {
                raise ValueError("Source switches must be true or false");
            }
        }
        async with self._lock {
            source = await self.get_source(user_id, source_id);
            inc = keywords(changes.get("include_keywords", source["include_keywords"]));
            exc = keywords(changes.get("exclude_keywords", source["exclude_keywords"]));
            enabled = bool(changes.get("enabled", source["enabled"]));
            resumed = enabled and not source["enabled"];
            await self._run(
                "UPDATE personal_sources SET enabled=?,alerts_enabled=?,include_keywords=?,exclude_keywords=?,next_poll_at=?,initialized=?,status=? WHERE id=? AND user_id=?",
                (
                    int(enabled),
                    int(changes.get("alerts_enabled", source["alerts_enabled"])),
                    json.dumps(inc),
                    json.dumps(exc),
                    "" if resumed else source["next_poll_at"],
                    0 if resumed else source["initialized"],
                    "pending"
                        if resumed
                        else (source["status"] if enabled else "paused"),
                    source_id,
                    user_id
                )
            );
            await self.db.commit();
        }
        return await self.get_source(user_id, source_id);
    }

    async def delete_source(user_id: int, source_id: int) {
        async with self._lock {
            await self.get_source(user_id, source_id);
            await self._run(
                "UPDATE personal_sources SET enabled=0,deleted_at=? WHERE id=? AND user_id=?",
                (iso(utcnow()), source_id, user_id)
            );
            await self.db.commit();
        }
    }

    async def active_sources -> list[Row] {
        rows = await self._all(
            "SELECT s.*,c.provider,c.status AS connection_status,c.daily_limit FROM personal_sources s JOIN personal_connections c ON c.id=s.connection_id WHERE s.deleted_at IS NULL AND c.deleted_at IS NULL AND s.enabled=1 AND c.status NOT IN ('needs_reconnect','disconnected') AND s.next_poll_at<=? ORDER BY s.next_poll_at,s.id",
            (iso(utcnow()), )
        );
        return [self._source(r) for r in rows];
    }

    async def claim_request(connection_id: int) -> bool {
        today = datetime.now(UTC).date().isoformat();
        async with self._lock {
            row = await self._one(
                "SELECT * FROM personal_connections WHERE id=? AND deleted_at IS NULL",
                (connection_id, )
            );
            if row is None or row["status"] in ["needs_reconnect", "disconnected"] {
                return False;
            }
            if row["provider"] == "rss" {
                return True;
            }
            used = int(row["requests_today"]) if row["request_day"] == today else 0;
            if used >= int(row["daily_limit"]) {
                await self._run(
                    "UPDATE personal_connections SET status='budget_paused',last_error='Daily request limit reached' WHERE id=?",
                    (connection_id, )
                );
                await self.db.commit();
                return False;
            }
            await self._run(
                "UPDATE personal_connections SET request_day=?,requests_today=? WHERE id=?",
                (today, used + 1, connection_id)
            );
            await self.db.commit();
            return True;
        }
    }

    async def source_success(source_id: int, next_poll_at: str) {
        async with self._lock {
            await self._run(
                "UPDATE personal_sources SET status='live',last_error='',last_success=?,next_poll_at=? WHERE id=? AND enabled=1 AND deleted_at IS NULL",
                (iso(utcnow()), next_poll_at, source_id)
            );
            await self._run(
                "UPDATE personal_connections SET status='connected',last_error='' WHERE id=(SELECT connection_id FROM personal_sources WHERE id=?) AND deleted_at IS NULL AND status NOT IN ('needs_reconnect','disconnected')",
                (source_id, )
            );
            await self.db.commit();
        }
    }

    async def source_failure(
        source_id: int, status: str, detail: str, next_poll_at: str
    ) {
        async with self._lock {
            await self._run(
                "UPDATE personal_sources SET status=?,last_error=?,next_poll_at=? WHERE id=? AND enabled=1 AND deleted_at IS NULL",
                (status, detail[:200], next_poll_at, source_id)
            );
            if status in ["needs_reconnect", "rate_limited", "budget_paused"] {
                await self._run(
                    "UPDATE personal_connections SET status=?,last_error=? WHERE id=(SELECT connection_id FROM personal_sources WHERE id=?) AND deleted_at IS NULL",
                    (status, detail[:200], source_id)
                );
            }
            await self.db.commit();
        }
    }

    async def persist_batch(
        source_id: int, items: list[Row], cursor: str, initial: bool = False
    ) {
        async with self._lock {
            source = await self._one(
                "SELECT s.* FROM personal_sources s JOIN personal_connections c ON c.id=s.connection_id WHERE s.id=? AND s.enabled=1 AND s.deleted_at IS NULL AND c.deleted_at IS NULL AND c.status NOT IN ('needs_reconnect','disconnected')",
                (source_id, )
            );
            if source is None {
                return;
            }
            silent = initial or not source["initialized"];
            inc = json.loads(source["include_keywords"]);
            exc = json.loads(source["exclude_keywords"]);
            now = iso(utcnow());
            try {
                for item in items {
                    ext = str(item["external_id"]);
                    if not ext or len(ext) > 4096 {
                        continue;
                    }
                    old = await self._one(
                        "SELECT id FROM personal_items WHERE source_id=? AND external_id=?",
                        (source_id, ext)
                    );
                    title = str(item.get("title", ""))[:500];
                    body = str(item.get("text", ""))[:20000];
                    url = str(item.get("url", ""))[:2048];
                    if not url.lower().startswith(("http://", "https://")) {
                        url = "";
                    }
                    if old {
                        await self._run(
                            "UPDATE personal_items SET title=?,text=?,url=? WHERE id=?",
                            (title, body, url, old["id"])
                        );
                        continue;
                    }
                    cur = await self._run(
                        "INSERT INTO personal_items(user_id,source_id,external_id,title,text,url,posted_at,received_at) VALUES (?,?,?,?,?,?,?,?)",
                        (
                            source["user_id"],
                            source_id,
                            ext,
                            title,
                            body,
                            url,
                            str(item.get("posted_at") or now),
                            now
                        )
                    );
                    content = (title + " " + body).lower();
                    matches = (not inc or any(k in content for k in inc))
                        and not any(k in content for k in exc);
                    if not silent and source["alerts_enabled"] and matches {
                        await self._run(
                            "INSERT INTO personal_notifications(user_id,item_id,source_id,created_at) VALUES (?,?,?,?)",
                            (source["user_id"], cur.lastrowid, source_id, now)
                        );
                    }
                }
                await self._run(
                    "UPDATE personal_sources SET cursor=?,initialized=1 WHERE id=?",
                    (cursor, source_id)
                );
                await self.db.commit();
            } except BaseException {
                await self.db.rollback();
                raise;
            }
        }
    }

    async def feed(user_id: int, after: int = 0, limit: int = 100) -> list[Row] {
        return await self._all(
            "SELECT i.*,s.name AS source_name,c.provider FROM personal_items i JOIN personal_sources s ON s.id=i.source_id JOIN personal_connections c ON c.id=s.connection_id WHERE i.user_id=? AND s.deleted_at IS NULL AND c.deleted_at IS NULL AND i.id>? ORDER BY i.id DESC LIMIT ?",
            (user_id, max(0, after), min(200, max(1, limit)))
        );
    }

    async def notifications_since(
        user_id: int, since: int = 0, limit: int = 100
    ) -> list[Row] {
        return await self._all(
            "SELECT i.*,n.id AS notification_id,'SOURCE_POST' AS kind,s.name AS source_name,c.provider FROM personal_notifications n JOIN personal_items i ON i.id=n.item_id JOIN personal_sources s ON s.id=n.source_id JOIN personal_connections c ON c.id=s.connection_id WHERE n.user_id=? AND n.id>? AND s.deleted_at IS NULL AND c.deleted_at IS NULL AND s.enabled=1 AND s.alerts_enabled=1 AND c.status<>'disconnected' ORDER BY n.id ASC LIMIT ?",
            (user_id, max(0, since), min(200, max(1, limit)))
        );
    }

    async def notification_head(user_id: int) -> int {
        row = await self._one(
            "SELECT COALESCE(MAX(id),0) AS n FROM personal_notifications WHERE user_id=?",
            (user_id, )
        );
        return int(row["n"]) if row else 0;
    }
}
