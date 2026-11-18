"""Account pairing and selective publication of private provider items."""

import contextlib;
import hashlib;
import hmac;
import json;
import os;
import re;
import secrets;
import time;
import aiosqlite;
import from datetime { UTC, datetime }
import from fastapi { FastAPI, HTTPException, Request }
import from auth { require_user }
import from db.repo { Repo, Row }
import from personal.api { allowed_fields, check_origin, positive_id, text_value }
import from personal.store { PersonalStore }

def bot_settings -> tuple[str, str] {
    name = os.environ.get("NEWSSTREAM_TELEGRAM_BOT_USERNAME", "").strip().lstrip("@");
    secret = os.environ.get("NEWSSTREAM_TELEGRAM_WEBHOOK_SECRET", "");
    if re.fullmatch(r"[A-Za-z0-9_]{5,32}", name)
        and re.fullmatch(r"[A-Za-z0-9_-]{32,256}", secret) {
        return (name, secret);
    }
    return ("", "");
}

@contextlib.asynccontextmanager
async def inbox_write(store: PersonalStore) -> AsyncIterator[aiosqlite.Connection] {
    async with aiosqlite.connect(store.db_path) as db {
        db.row_factory = aiosqlite.Row;
        await db.execute("PRAGMA foreign_keys = ON");
        await db.execute("BEGIN IMMEDIATE");
        try {
            yield db;
            await db.commit();
        } except BaseException {
            await db.rollback();
            raise;
        }
    }
}

def digest(token: str) -> str {
    return hashlib.sha256(token.encode()).hexdigest();
}

async def pair_link(store: PersonalStore, owner: int, name: str) -> str {
    token = str(secrets.token_urlsafe(24));
    async with inbox_write(store) as db {
        await db.execute(
            "INSERT INTO personal_telegram_pairing(user_id,challenge_hash,expires_at) VALUES(?,?,?) ON CONFLICT(user_id) DO UPDATE SET challenge_hash=excluded.challenge_hash,expires_at=excluded.expires_at",
            (owner, digest(token), int(time.time()) + 600)
        );
    }
    return f"https://t.me/{name}?start={token}";
}

async def receive_message(store: PersonalStore, update: Row) -> Row {
    msg = update.get("message");
    if not isinstance(msg, dict) or msg.get("has_protected_content") {
        return {};
    }
    sender = msg.get("from");
    chat = msg.get("chat");
    if not isinstance(sender, dict)
        or sender.get("is_bot")
        or not isinstance(chat, dict)
        or chat.get("type") != "private"
        or not isinstance(sender.get("id"), int)
        or sender["id"] <= 0
        or sender["id"] != chat.get("id") {
        return {};
    }
    tid = sender["id"];
    mid = msg.get("message_id");
    sent = msg.get("date");
    if not isinstance(mid, int)
        or mid < 1
        or not isinstance(sent, int)
        or sent < 1
        or sent > int(time.time()) + 300 {
        return {};
    }
    content = msg.get("text") or msg.get("caption") or "";
    if not isinstance(content, str) or not content.strip() or len(content) > 8192 {
        return {};
    }
    answer = "";
    async with inbox_write(store) as db {
        if content.startswith("/start ") and not msg.get("forward_origin") {
            token = content[7:].strip();
            hit = await (
                await db.execute(
                    "SELECT p.user_id,u.username FROM personal_telegram_pairing p JOIN users u ON u.id=p.user_id WHERE p.challenge_hash=? AND p.expires_at>=?",
                    (digest(str(token)), int(time.time()))
                ) as aiosqlite.Cursor
            ).fetchone();
            if hit {
                linked = list(
                    await (
                        await db.execute(
                            "SELECT user_id,telegram_id FROM personal_telegram_accounts WHERE user_id=? OR telegram_id=?",
                            (hit["user_id"], tid)
                        ) as aiosqlite.Cursor
                    ).fetchall()
                );
                if not linked {
                    await db.execute(
                        "INSERT INTO personal_telegram_accounts(user_id,telegram_id,linked_at,linked_message_id) VALUES(?,?,?,?)",
                        (hit["user_id"], tid, sent, mid)
                    );
                    answer = f"Connected to NewsDrop as {hit[
                        'username'
                    ]}. Send or forward text you may share here, then review it in My Sources.";
                } elif len(linked) == 1
                    and linked[0]["telegram_id"] == tid
                    and linked[0]["user_id"] == hit["user_id"] {
                    answer = "This Telegram account is already connected. Open My Sources to review your inbox.";
                } else {
                    answer = "An account is already paired. Disconnect it in My Sources before linking again.";
                }
                await db.execute(
                    "DELETE FROM personal_telegram_pairing WHERE user_id=?",
                    (hit["user_id"], )
                );
            } else {
                answer = "This link has expired or has already been used. Check My Sources for your connection.";
            }
        } elif not content.startswith("/") {
            owner = await (
                await db.execute(
                    "SELECT user_id FROM personal_telegram_accounts WHERE telegram_id=? AND linked_at<=? AND linked_message_id<?",
                    (tid, sent, mid)
                ) as aiosqlite.Cursor
            ).fetchone();
            if owner {
                origin = msg.get("forward_origin");
                date = origin.get("date") if isinstance(origin, dict) else None;
                published = date
                    if isinstance(date, int) and 0 < date <= sent
                    else sent;
                # A forwarded message may include private chat or participant metadata.
                # Only the chosen text and its timestamp enter the inbox.
                await db.execute(
                    "INSERT INTO personal_telegram_inbox(user_id,message_id,body,published_at) VALUES(?,?,?,?) ON CONFLICT(user_id,message_id) DO NOTHING",
                    (
                        owner["user_id"],
                        mid,
                        content.strip(),
                        datetime.fromtimestamp(published, UTC).isoformat()
                    )
                );
                answer = "Saved to your private NewsDrop inbox. Open My Sources to choose what to publish.";
            }
        }
    }
    return {"method": "sendMessage", "chat_id": tid, "text": answer} if answer else {};
}

def install_publishing_routes(
    app: FastAPI, repo: Repo, store: PersonalStore, catalog: any
) {
    @app.get("/api/me/telegram")
    async def telegram_status(request: Request) -> Row {
        user = await require_user(request, repo);
        owner = int(user["user_id"]);
        (name, _) = bot_settings();
        linked = await store._read_one(
            "SELECT 1 AS connected FROM personal_telegram_accounts WHERE user_id=?",
            (owner, )
        );
        rows = await store._all(
            "SELECT id, body, published_at FROM personal_telegram_inbox WHERE user_id=? ORDER BY id DESC LIMIT 100",
            (owner, )
        );
        return {"available": bool(name), "linked": bool(linked), "items": rows};
    }

    @app.post("/api/me/telegram/pair")
    async def create_pair(request: Request) -> Row {
        user = await require_user(request, repo);
        check_origin(request);
        (name, _) = bot_settings();
        if not name {
            raise HTTPException(
                503, "The Telegram inbox bot is unavailable on this server"
            );
        }
        return {"url": await pair_link(store, int(user["user_id"]), name)};
    }

    @app.delete("/api/me/telegram")
    async def disconnect(request: Request) -> Row {
        user = await require_user(request, repo);
        check_origin(request);
        owner = int(user["user_id"]);
        async with inbox_write(store) as db {
            await db.execute(
                "DELETE FROM personal_telegram_pairing WHERE user_id=?", (owner, )
            );
            await db.execute(
                "DELETE FROM personal_telegram_accounts WHERE user_id=?", (owner, )
            );
        }
        return {"disconnected": True};
    }

    @app.post("/api/telegram/updates")
    async def telegram_update(request: Request) -> Row {
        (_, secret) = bot_settings();
        supplied = request.headers.get("x-telegram-bot-api-secret-token", "");
        if not secret or not hmac.compare_digest(supplied.encode(), secret.encode()) {
            raise HTTPException(403, "Invalid webhook credential");
        }
        raw = bytearray();
        async for part in request.stream() {
            if len(raw) + len(part) > 131072 {
                raise HTTPException(413, "Telegram update exceeds the size limit");
            }
            raw.extend(part);
        }
        try {
            update = json.loads(raw);
        } except (ValueError, UnicodeError) {
            raise HTTPException(422, "Invalid Telegram update");
        }
        return await receive_message(store, update) if isinstance(update, dict) else {};
    }

    @app.post("/api/me/share-item")
    async def share_item(request: Request, body: Row) -> Row {
        user = await require_user(request, repo);
        check_origin(request);
        owner = int(user["user_id"]);
        allowed_fields(
            body, ["provider", "id", "slug", "title", "excerpt", "confirmed"]
        );
        if body.get("confirmed") is not True {
            raise HTTPException(
                422, "Confirm you may publish this selection to the public channel"
            );
        }
        kind = text_value(body, "provider", 20);
        item_id = positive_id(body.get("id"));
        slug = text_value(body, "slug", 180);
        if kind == "telegram" {
            record = await store._read_one(
                "SELECT body,published_at FROM personal_telegram_inbox WHERE id=? AND user_id=?",
                (item_id, owner)
            );
            if record is None {
                raise HTTPException(404, "Inbox item not found");
            }
            text = text_value(body, "excerpt", 8192);
            title = text_value(body, "title", 180);
            if not title or not text or text not in record["body"] {
                raise HTTPException(
                    422, "Enter a title and select an excerpt from this message"
                );
            }
            author = str(user["username"]);
            url = "";
            published = str(record["published_at"]);
            external = f"telegram:{owner}:{item_id}";
        } elif kind == "x" {
            record = await store._read_one(
                "SELECT i.*,s.remote_id,s.url AS profile_url FROM personal_items i JOIN personal_sources s ON s.id=i.source_id AND s.user_id=i.user_id JOIN personal_connections c ON c.id=s.connection_id WHERE i.id=? AND i.user_id=? AND s.deleted_at IS NULL AND c.deleted_at IS NULL AND c.provider='x'",
                (item_id, owner)
            );
            if record is None {
                raise HTTPException(404, "X post not found");
            }
            text = str(record["text"]);
            title = str(record["title"])[:180] or text[:120];
            url = str(record["url"]);
            if not re.fullmatch(
                r"https://x\.com/(?:[A-Za-z0-9_]{1,15}/status|i/status)/[0-9]+", url
            ) {
                raise HTTPException(422, "The provider returned an invalid post link");
            }
            author = str(record["profile_url"]).rstrip("/").split("/")[-1];
            published = str(record["posted_at"]);
            external = f"x:{record['remote_id']}:{record['external_id']}";
        } else {
            raise HTTPException(422, "Choose an X post or Telegram message");
        }
        try {
            item = await catalog.publish_selected(
                slug, owner, author, title, text, url, external, published, kind
            );
        } except KeyError {
            raise HTTPException(404, "Owned channel not found");
        } except ValueError as error {
            raise HTTPException(422, str(error));
        }
        return {"item": item};
    }
}
