"""Two-account acceptance scenario against the ordinary FastAPI lifespan and routes."""

import httpx


async def sign_up(client, name):
    account = {"username": name, "email": f"{name}@example.org", "password": "local-test-password"}
    (await client.post("/register", json=account)).raise_for_status()
    (await client.post("/login", json=account)).raise_for_status()


async def exercise_workspace(create_app, settings):
    settings.x_push_enabled = False
    app = create_app(settings)
    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app, client=("192.0.2.5", 51000))
        async with (
            httpx.AsyncClient(transport=transport, base_url="http://test") as publisher,
            httpx.AsyncClient(transport=transport, base_url="http://test") as reader,
        ):
            assert (await reader.get("/api/following")).status_code == 401
            assert (await reader.get("/portfolio")).status_code == 403
            await sign_up(publisher, "editor")
            await sign_up(reader, "reader")
            conflict = await reader.post("/register", json={
                "username": "editor", "email": "third@example.org", "password": "local-test-password",
            })
            assert conflict.status_code == 409
            published = await publisher.post("/api/channels", json={
                "name": "Semiconductor notes", "description": "Community reports on chip production.",
                "category": "tech", "source_type": "community",
            })
            slug = published.raise_for_status().json()["channel"]["slug"]
            path = f"/api/channels/{slug}"
            directory = (await reader.get("/api/channels")).raise_for_status().json()
            assert slug in {c["slug"] for c in directory["channels"]}
            assert (await reader.post(f"{path}/click")).raise_for_status().json()["clicks"] == 1
            for action in ("subscription", "recommendation", "recommendation"):
                (await reader.put(f"{path}/{action}", json={"enabled": True})).raise_for_status()
            post = await publisher.post(f"{path}/posts", json={
                "title": "Factory update", "text": "The board published a production schedule.",
                "url": "https://example.org/report",
            })
            item_id = post.raise_for_status().json()["item"]["id"]
            (await reader.post(f"{path}/comments", json={
                "text": "Which quarter does it cover?", "item_id": item_id,
            })).raise_for_status()
            feed = (await reader.get("/api/following")).raise_for_status().json()
            assert item_id in {item["id"] for item in feed["items"]}
            session = reader.cookies["session"]

    restarted = create_app(settings)
    async with restarted.router.lifespan_context(restarted):
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=restarted), base_url="http://test",
            cookies={"session": session},
        ) as reader:
            data = (await reader.get(path)).raise_for_status().json()
            assert data["channel"]["subscribed"] and data["channel"]["recommendations"] == 1
            assert data["channel"]["clicks"] == 1
            assert data["comments"][0]["author"] == "reader"
            feed = (await reader.get("/api/following")).raise_for_status().json()
            assert feed["items"][0]["id"] == item_id
