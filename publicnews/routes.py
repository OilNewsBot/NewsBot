"""Public read APIs and same-origin, session-owned community writes."""
from fastapi import HTTPException, Request, Response


def install(app, repo, catalog, require_user, check_origin):
    async def viewer(request):
        if request.cookies.get("session"):
            try:
                return (await require_user(request, repo))["user_id"]
            except HTTPException as exc:
                if exc.status_code != 401:
                    raise
        return None

    async def writer(request):
        check_origin(request)
        return await require_user(request, repo)

    @app.get("/api/channels")
    async def channels(request: Request, response: Response):
        response.headers["Cache-Control"] = "private, no-store"
        return {"channels": await catalog.channels(await viewer(request))}

    @app.get("/api/channels/{slug}")
    async def detail(slug: str, request: Request, response: Response):
        response.headers["Cache-Control"] = "private, no-store"
        return await catalog.detail(slug, await viewer(request))

    @app.get("/api/following")
    async def following(request: Request, response: Response):
        response.headers["Cache-Control"] = "private, no-store"
        user = await require_user(request, repo)
        return await catalog.following(user["user_id"])

    @app.post("/api/channels", status_code=201)
    async def create(request: Request, body: dict):
        user = await writer(request)
        return {"channel": await catalog.create(user["user_id"], user["username"], body)}

    @app.post("/api/channels/{slug}/click")
    async def click(slug: str, request: Request):
        check_origin(request)
        return {"clicks": await catalog.click(slug)}

    async def set_choice(slug, request, body, kind):
        user = await writer(request)
        if type(body.get("enabled")) is not bool:
            raise HTTPException(422, "Set enabled to true or false")
        return {"channel": await catalog.toggle(slug, user["user_id"], kind, body["enabled"])}

    @app.put("/api/channels/{slug}/subscription")
    async def subscription(slug: str, request: Request, body: dict):
        return await set_choice(slug, request, body, "subscription")

    @app.put("/api/channels/{slug}/recommendation")
    async def recommendation(slug: str, request: Request, body: dict):
        return await set_choice(slug, request, body, "recommendation")

    @app.post("/api/channels/{slug}/comments", status_code=201)
    async def comment(slug: str, request: Request, body: dict):
        user = await writer(request)
        return {"comment": await catalog.comment(slug, user["user_id"], user["username"], body)}

    @app.post("/api/channels/{slug}/posts", status_code=201)
    async def post(slug: str, request: Request, body: dict):
        user = await writer(request)
        return {"item": await catalog.post(slug, user["user_id"], user["username"], body)}
