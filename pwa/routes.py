"""NewsDrop's same-origin PWA assets and session-authenticated API."""

import asyncio
import hashlib
import hmac
import json
import os
import re
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, Response

from .service import LOG, PushService
from .transport import WebPush, browser_key, decode, endpoint_url

ASSETS = Path(__file__).with_name("assets")
ICON_512 = ASSETS.parents[1] / "desktop" / "src-tauri" / "icons" / "icon.png"
HEAD = """
    <meta name="theme-color" content="#232323">
    <link rel="manifest" href="/pwa/manifest.webmanifest">
    <link rel="apple-touch-icon" href="/pwa/icon-192.png">
    <link rel="stylesheet" href="/pwa/controls.css">
    <script src="/pwa/controls.js" defer></script>
"""
API = "/api/me/web-push"
PUBLIC_SESSION_ROUTES = {
    "/refetch", "/status", "/stream", "/notifications", "/feed", "/suppressed",
    "/portfolio", "/suggestions", "/prices",
}
NO_STORE = {"Cache-Control": "no-store"}


async def pwa_index(path) -> Response:
    html = await asyncio.to_thread(Path(path).read_text, encoding="utf-8")
    html = html.replace("</head>", HEAD + "</head>", 1)
    return HTMLResponse(html, headers={"Cache-Control": "no-cache"})


def push_transport():
    key = os.environ.get("NEWSBOT_VAPID_PRIVATE_KEY", "")
    subject = os.environ.get("NEWSBOT_VAPID_SUBJECT", "")
    if key or subject:
        try:
            return WebPush(key, subject)
        except (ValueError, TypeError):
            LOG.warning("Web Push disabled: invalid VAPID configuration")
    return None


def session_binding(user):
    # A one-way session marker, used solely to reject stale browser operations.
    return hashlib.sha256(("newsstream web push:" + user["token_hash"]).encode()).hexdigest()


async def read_json(request):
    if request.headers.get("content-type", "").split(";", 1)[0] != "application/json":
        raise HTTPException(415, "Expected JSON")
    data = bytearray()
    async for chunk in request.stream():
        if len(data) + len(chunk) > 4096:
            raise HTTPException(413, "Request body too large")
        data.extend(chunk)
    try:
        body = json.loads(data)
        if isinstance(body, dict):
            return body
    except (ValueError, RecursionError):
        pass
    raise HTTPException(422, "Expected a JSON object")


def checked_endpoint(value):
    try:
        endpoint_url(value)
        return value
    except ValueError as exc:
        raise HTTPException(422, "Unsupported browser push endpoint") from exc


def install_pwa(app, repo, db_path, require_user, check_origin, eligibility) -> None:
    public = os.environ.get("NEWSBOT_PUBLIC_PWA") == "1"
    service = PushService(db_path, push_transport(), eligibility)
    original = app.router.lifespan_context

    @asynccontextmanager
    async def lifespan(application):
        async with original(application) as state:
            await service.connect()
            task = asyncio.create_task(service.run(), name="web-push") if service.transport else None
            try:
                yield state
            finally:
                if task:
                    task.cancel()
                    await asyncio.gather(task, return_exceptions=True)
                await service.close()

    app.router.lifespan_context = lifespan
    app.state.web_push = service

    @app.middleware("http")
    async def pwa_policy(request: Request, call_next):
        path = request.url.path.rstrip("/")
        if public:
            if path == "/ingest":
                return Response(status_code=404)
            if path in PUBLIC_SESSION_ROUTES or path in {"/login", "/register"}:
                if request.url.scheme != "https":
                    return JSONResponse({"detail": "HTTPS required"}, status_code=403)
            if path in PUBLIC_SESSION_ROUTES:
                try:
                    await require_user(request, repo)
                    if request.method not in {"GET", "HEAD", "OPTIONS"}:
                        check_origin(request)
                except HTTPException as exc:
                    return JSONResponse({"detail": exc.detail}, status_code=exc.status_code)
        response = await call_next(request)
        if path.startswith(API + "/") or (public and path in PUBLIC_SESSION_ROUTES):
            response.headers["Cache-Control"] = "no-store"
        return response

    @app.get("/pwa/{asset}", include_in_schema=False)
    async def asset_file(asset: str):
        files = {
            "manifest.webmanifest": (ASSETS / "manifest.webmanifest", "application/manifest+json"),
            "icon-192.png": (ASSETS / "icon-192.png", "image/png"),
            "icon-512.png": (ICON_512, "image/png"),
            "controls.js": (ASSETS / "controls.js", "application/javascript"),
            "controls.css": (ASSETS / "controls.css", "text/css"),
        }
        if asset not in files:
            raise HTTPException(404)
        path, media_type = files[asset]
        return FileResponse(path, media_type=media_type, headers={"Cache-Control": "no-cache"})

    @app.get("/newsstream-sw.js", include_in_schema=False)
    async def service_worker():
        return FileResponse(
            ASSETS / "sw.js", media_type="application/javascript",
            headers={"Cache-Control": "no-cache", "Service-Worker-Allowed": "/"},
        )

    async def authorized(request):
        if request.url.scheme != "https" and (
            public or request.url.hostname not in {"localhost", "127.0.0.1", "::1"}
        ):
            raise HTTPException(403, "Web Push requires HTTPS or localhost")
        check_origin(request)
        return await require_user(request, repo)

    @app.post(API + "/status")
    async def status(request: Request):
        user = await authorized(request)
        body = await read_json(request)
        endpoint = body.get("endpoint")
        subscribed = bool(endpoint and await service.registered(user, checked_endpoint(endpoint)))
        return {"publicKey": service.public_key, "binding": session_binding(user), "active": subscribed}

    @app.put(API + "/subscription")
    @app.delete(API + "/subscription")
    async def subscription(request: Request):
        user = await authorized(request)
        body = await read_json(request)
        binding = body.get("binding")
        if not isinstance(binding, str) or not hmac.compare_digest(
            binding.encode(), session_binding(user).encode()
        ):
            raise HTTPException(409, "Session changed; refresh and try again")
        endpoint = checked_endpoint(body.get("endpoint"))
        if request.method == "DELETE":
            await service.revoke(user, endpoint)
            return Response(status_code=204, headers=NO_STORE)
        if not service.public_key:
            raise HTTPException(503, "Web Push is disabled on this server")
        keys = body.get("keys")
        try:
            if not isinstance(keys, dict):
                raise ValueError("Invalid keys")
            p256dh, auth = keys.get("p256dh"), keys.get("auth")
            browser_key(decode(p256dh, 65))
            decode(auth, 16)
        except ValueError as exc:
            raise HTTPException(422, "Invalid browser push keys") from exc
        if not await service.subscribe(user, endpoint, p256dh, auth):
            raise HTTPException(409, "Push subscription unavailable for this session")
        return Response(status_code=204, headers=NO_STORE)

    @app.post(API + "/destination")
    async def destination(request: Request):
        user = await authorized(request)
        ticket = (await read_json(request)).get("ticket")
        if not isinstance(ticket, str) or not re.fullmatch(r"[A-Za-z0-9_-]{32}", ticket):
            raise HTTPException(404)
        item = await service.destination(user, ticket)
        if item is None:
            raise HTTPException(404)
        return {"itemId": item}
