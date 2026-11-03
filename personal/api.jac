"""Account-owned sources, saved notifications, and authenticated SSE replay."""

import asyncio;
import json;
import from datetime { timedelta }
import from urllib.parse { urlsplit }
import from fastapi { FastAPI, HTTPException, Request }
import from fastapi.responses { StreamingResponse }
import from auth { require_user }
import from db.repo { Repo, Row, iso, utcnow }
import from personal.store { PersonalStore }
import from personal.providers { ProviderError, resolve_source }

type Resolver = Callable[[str, str, str], Row];

"""Cookie-authenticated writes must originate from this application."""
def check_origin(request: Request) {
    if request.headers.get("sec-fetch-site", "") == "cross-site" {
        raise HTTPException(403, "Cross-origin changes are not allowed");
    }
    origin = request.headers.get("origin");
    if not origin {
        return;
    }
    try {
        claimed = urlsplit(origin);
        actual = urlsplit(str(request.base_url));
        same = (
            claimed.scheme in ("http", "https")
            and claimed.scheme == actual.scheme
            and claimed.hostname == actual.hostname
            and (claimed.port or (443 if claimed.scheme == "https" else 80))
                == (actual.port or (443 if actual.scheme == "https" else 80))
            and not claimed.username
            and not claimed.password
            and claimed.path in ("", "/")
            and not claimed.query
            and not claimed.fragment
        );
    } except ValueError {
        same = False;
    }
    if not same {
        raise HTTPException(403, "Cross-origin changes are not allowed");
    }
}

def allowed_fields(body: Row, allowed: list[str]) {
    if any(key not in allowed for key in body) {
        raise HTTPException(422, "Unsupported setting");
    }
}

def text_value(body: Row, key: str, maximum: int, fallback: str = "") -> str {
    value = body.get(key, fallback);
    if not isinstance(value, str) or len(value) > maximum {
        raise HTTPException(422, f"Invalid {key}");
    }
    return value.strip();
}

def positive_id(value: any) -> int {
    if isinstance(value, bool) or not isinstance(value, int) or value < 1 {
        raise HTTPException(422, "Invalid connection ID");
    }
    return int(value);
}

def keywords(value: any) -> list[str] {
    if not isinstance(value, list) or len(value) > 20 {
        raise HTTPException(422, "Use at most 20 keywords");
    }
    result: list[str] = [];
    for word in value {
        if not isinstance(word, str) or not word.strip() or len(word) > 80 {
            raise HTTPException(
                422, "Keywords must be nonempty text up to 80 characters"
            );
        }
        clean = word.strip().lower();
        if clean not in result {
            result.append(clean);
        }
    }
    return result;
}

def source_preferences(body: Row) -> Row {
    changes: Row = {};
    for key in ["enabled", "alerts_enabled"] {
        if key in body {
            if not isinstance(body[key], bool) {
                raise HTTPException(422, f"{key} must be true or false");
            }
            changes[key] = body[key];
        }
    }
    for key in ["include_keywords", "exclude_keywords"] {
        if key in body {
            changes[key] = keywords(body[key]);
        }
    }
    return changes;
}

def validate_page(cursor: int, limit: int) {
    if cursor < 0 or not 1 <= limit <= 200 {
        raise HTTPException(422, "Cursor must be nonnegative and limit must be 1-200");
    }
}

def encryption_unavailable -> HTTPException {
    return HTTPException(
        503,
        "X connections need a valid NEWSBOT_CONNECTION_KEY configured on the server"
    );
}

"""The database is the replay buffer. Session revocation also ends open streams."""
async def personal_events(
    request: Request,
    repo: Repo,
    store: PersonalStore,
    user_id: int,
    since: int,
    poll_seconds: float = 1.0
) -> AsyncIterator[str] {
    cursor = since;
    idle = 0;
    yield ": connected\n\n";
    while not await request.is_disconnected() {
        try {
            user = await require_user(request, repo);
            if int(user["user_id"]) != user_id {
                raise HTTPException(401, "Session changed");
            }
        } except HTTPException {
            yield 'event: session_expired\ndata: {"detail":"Please sign in again"}\n\n';
            return;
        }
        rows = await store.notifications_since(user_id, cursor, 100);
        for row in rows {
            try {
                user = await require_user(request, repo);
                if int(user["user_id"]) != user_id {
                    raise HTTPException(401, "Session changed");
                }
                # Source removal/disable can race a fetched page. Recheck before send.
                source = await store.get_source(user_id, int(row["source_id"]));
                if not source.get("enabled", True)
                    or not source.get("alerts_enabled", True)
                    or int(row["notification_id"])
                        <= int(source.get("alert_after_id", 0)) {
                    cursor = int(row["notification_id"]);
                    continue;
                }
            } except KeyError {
                cursor = int(row["notification_id"]);
                continue;
            } except HTTPException {
                yield 'event: session_expired\ndata: {"detail":"Please sign in again"}\n\n';
                return;
            }
            cursor = int(row["notification_id"]);
            yield f"id: {cursor}\nevent: notification\ndata: {json.dumps(row)}\n\n";
        }
        if rows {
            idle = 0;
            # Drain a complete page before sleeping, so reconnect backfill is bounded
            # by database pagination rather than one second per 100 messages.
            if len(rows) == 100 {
                continue;
            }
        } else {
            idle += 1;
            if idle >= 15 {
                yield ": heartbeat\n\n";
                idle = 0;
            }
        }
        await asyncio.sleep(poll_seconds);
    }
}

def install_personal_routes(
    app: FastAPI, repo: Repo, store: PersonalStore, resolver: Resolver = resolve_source
) {
    @app.middleware("http")
    async def private_response_headers(request: Request, call_next: any) -> any {
        response = await call_next(request);
        if request.url.path.startswith("/api/me/") {
            response.headers["Cache-Control"] = "no-store";
        }
        return response;
    }

    @app.get("/api/me/connections")
    async def connections(request: Request) -> Row {
        user = await require_user(request, repo);
        return {"connections": await store.list_connections(int(user["user_id"]))};
    }

    @app.post("/api/me/connections", status_code=201)
    async def create_connection(request: Request, body: Row) -> Row {
        user = await require_user(request, repo);
        check_origin(request);
        allowed_fields(body, ["provider", "label", "api_key", "daily_limit"]);
        provider = text_value(body, "provider", 20);
        label = text_value(body, "label", 80);
        secret = text_value(body, "api_key", 1024);
        if provider not in ("rss", "x") or not label {
            raise HTTPException(422, "Choose RSS or X and enter a connection name");
        }
        if provider == "x" and not secret {
            raise HTTPException(422, "A TwitterAPI.io API key is required");
        }
        if provider == "rss" and secret {
            raise HTTPException(422, "RSS connections do not use an API key");
        }
        limit = body.get("daily_limit", 200);
        if isinstance(limit, bool)
            or not isinstance(limit, int)
            or not 1 <= limit <= 2000 {
            raise HTTPException(422, "Daily request limit must be between 1 and 2000");
        }
        try {
            connection = await store.create_connection(
                int(user["user_id"]), provider, label, secret, int(limit)
            );
        } except RuntimeError {
            raise encryption_unavailable();
        } except ValueError as error {
            raise HTTPException(422, str(error));
        }
        return {"connection": connection};
    }

    @app.patch("/api/me/connections/{connection_id}")
    async def reconnect(request: Request, connection_id: int, body: Row) -> Row {
        user = await require_user(request, repo);
        check_origin(request);
        allowed_fields(body, ["api_key"]);
        try {
            connection = await store.get_connection(
                int(user["user_id"]), connection_id
            );
            if connection["provider"] != "x" {
                raise HTTPException(422, "Only X connections use an API key");
            }
            secret = text_value(body, "api_key", 1024);
            if not secret {
                raise HTTPException(422, "A TwitterAPI.io API key is required");
            }
            connection = await store.reconnect_connection(
                int(user["user_id"]), connection_id, secret
            );
        } except KeyError {
            raise HTTPException(404, "Connection not found");
        } except RuntimeError {
            raise encryption_unavailable();
        } except ValueError as error {
            raise HTTPException(422, str(error));
        }
        return {"connection": connection};
    }

    @app.delete("/api/me/connections/{connection_id}")
    async def disconnect(request: Request, connection_id: int) -> Row {
        user = await require_user(request, repo);
        check_origin(request);
        try {
            await store.delete_connection(int(user["user_id"]), connection_id);
        } except KeyError {
            raise HTTPException(404, "Connection not found");
        }
        return {"deleted": True};
    }

    @app.get("/api/me/sources")
    async def sources(request: Request) -> Row {
        user = await require_user(request, repo);
        return {"sources": await store.list_sources(int(user["user_id"]))};
    }

    @app.post("/api/me/sources", status_code=201)
    async def create_source(request: Request, body: Row) -> Row {
        user = await require_user(request, repo);
        check_origin(request);
        allowed_fields(
            body,
            [
                "connection_id",
                "locator",
                "alerts_enabled",
                "include_keywords",
                "exclude_keywords"
            ]
        );
        connection_id = positive_id(body.get("connection_id"));
        locator = text_value(body, "locator", 2048);
        if not locator {
            raise HTTPException(422, "Enter a feed URL or X account");
        }
        preferences = source_preferences(body);
        user_id = int(user["user_id"]);
        try {
            connection = await store.get_connection(user_id, connection_id);
            if connection["status"] == "needs_reconnect" {
                raise HTTPException(
                    422, "Reconnect this service before adding a source"
                );
            }
            if connection.get("retry_at", "") > iso(utcnow()) {
                raise HTTPException(
                    429, "This connection is temporarily paused; try again later"
                );
            }
            secret = await store.connection_secret(connection_id);
            if connection["provider"] == "x"
                and not await store.claim_request(connection_id) {
                raise HTTPException(
                    429, "This connection's daily request limit is reached"
                );
            }
            resolved = await resolver(str(connection["provider"]), locator, secret);
            source = await store.create_source(
                user_id,
                connection_id,
                str(resolved["remote_id"]),
                str(resolved["name"]),
                str(resolved["url"]),
                alerts_enabled=bool(preferences.get("alerts_enabled", True)),
                include_keywords=preferences.get("include_keywords", []),
                exclude_keywords=preferences.get("exclude_keywords", [])
            );
        } except KeyError {
            raise HTTPException(404, "Connection not found");
        } except ProviderError as error {
            delay = max(1, min(86400, int(error.retry_after)));
            if connection["provider"] == "x"
                and error.status
                    in ["needs_reconnect", "rate_limited", "budget_paused"] {
                await store.connection_failure(
                    connection_id,
                    error.status,
                    error.detail,
                    iso(utcnow() + timedelta(seconds=delay))
                );
            }
            code = 429
                if error.status in ("rate_limited", "budget_paused")
                else (422 if error.status == "needs_reconnect" else 502);
            raise HTTPException(
                code,
                error.detail,
                headers={"Retry-After": str(delay)} if code == 429 else None
            );
        } except RuntimeError {
            raise encryption_unavailable();
        } except ValueError {
            raise HTTPException(
                422,
                "The source could not be added; check its address and whether it is already followed"
            );
        }
        return {"source": source};
    }

    @app.patch("/api/me/sources/{source_id}")
    async def update_source(request: Request, source_id: int, body: Row) -> Row {
        user = await require_user(request, repo);
        check_origin(request);
        allowed_fields(
            body, ["enabled", "alerts_enabled", "include_keywords", "exclude_keywords"]
        );
        changes = source_preferences(body);
        if not changes {
            raise HTTPException(422, "Choose a source setting to update");
        }
        try {
            source = await store.update_source(
                int(user["user_id"]), source_id, changes
            );
        } except KeyError {
            raise HTTPException(404, "Source not found");
        } except ValueError {
            raise HTTPException(422, "Invalid source settings");
        }
        return {"source": source};
    }

    @app.delete("/api/me/sources/{source_id}")
    async def remove_source(request: Request, source_id: int) -> Row {
        user = await require_user(request, repo);
        check_origin(request);
        try {
            await store.delete_source(int(user["user_id"]), source_id);
        } except KeyError {
            raise HTTPException(404, "Source not found");
        }
        return {"deleted": True};
    }

    @app.get("/api/me/feed")
    async def feed(request: Request, after: int = 0, limit: int = 100) -> Row {
        user = await require_user(request, repo);
        validate_page(after, limit);
        return {"items": await store.feed(int(user["user_id"]), after, limit)};
    }

    @app.get("/api/me/notifications")
    async def notifications(request: Request, since: int = 0, limit: int = 100) -> Row {
        user = await require_user(request, repo);
        validate_page(since, limit);
        return {
            "notifications": await store.notifications_since(
                int(user["user_id"]), since, limit
            )
        };
    }

    @app.get("/api/me/notifications/head")
    async def head(request: Request) -> Row {
        user = await require_user(request, repo);
        return {"notification_id": await store.notification_head(int(user["user_id"]))};
    }

    @app.get("/api/me/stream")
    async def stream(request: Request, since: int = 0) -> StreamingResponse {
        user = await require_user(request, repo);
        last_id = request.headers.get("last-event-id");
        if last_id {
            try {
                since = int(last_id);
            } except ValueError {
                raise HTTPException(422, "Invalid Last-Event-ID");
            }
        }
        validate_page(since, 100);
        return StreamingResponse(
            personal_events(request, repo, store, int(user["user_id"]), since),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"}
        );
    }
}
