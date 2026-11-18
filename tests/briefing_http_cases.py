"""Briefing contract across ordinary app routes, account switches and restarts."""
import httpx

from tests.workspace_flow import sign_up


async def check_home(create_app, settings):
    settings.x_push_enabled = False
    app = create_app(settings)
    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app, client=("192.0.2.61", 51200))
        async with (
            httpx.AsyncClient(transport=transport, base_url="http://test") as alice,
            httpx.AsyncClient(transport=transport, base_url="http://test") as bob,
        ):
            for path in ("/api/briefing", "/api/watches", "/api/stories/private-1"):
                assert (await alice.get(path)).status_code == 401
            await sign_up(alice, "brief-alice")
            await sign_up(bob, "brief-bob")
            mine = (await alice.get("/api/watches")).raise_for_status().json()
            uid = mine["user_id"]
            assert len(mine["taxonomy"]) == 8 and all(s["topics"] for s in mine["taxonomy"])
            assert set(mine["facets"]) == {"entities", "events", "places"}
            # Build the watch using exact stable IDs returned by the server.
            event_id = next(x["id"] for x in mine["facets"]["events"] if "export" in x["id"])
            path = "/api/watches/topics/" + "~".join(sorted([event_id, "tech.semiconductor-equipment"]))
            assert (await alice.put(path, json={"enabled": True}, headers={"Origin": "https://elsewhere.example"})).status_code == 403
            (await alice.put(path, json={"enabled": True, "user_id": uid})).raise_for_status()
            (await alice.put(path, json={"enabled": True})).raise_for_status()
            assert len((await alice.get("/api/watches")).json()["topics"]) == 1
            assert (await bob.get("/api/watches")).json()["topics"] == []
            assert (await bob.put(path, json={"enabled": True, "user_id": uid})).status_code == 409
            assert (await alice.put("/api/watches/topics/unknown", json={"enabled": True})).status_code == 422
            initial = (await alice.get("/api/briefing")).raise_for_status().json()
            assert initial["first_visit"] and not initial["cards"]
            async def ack(client, board):
                return await client.post("/api/briefing/seen", json={
                    "through": board["through"], "private_through": board["private_through"], "user_id": board["user_id"]})
            assert (await bob.post("/api/briefing/seen", json={"through": 0,"user_id": uid})).status_code == 409
            (await ack(alice, initial)).raise_for_status()
            store = app.state.personal
            connection = await store.create_connection(uid, "rss", "My desk")
            source = await store.create_source(uid, connection["id"], "market-news", "My private desk", "https://example.org/feed")
            item = {"external_id": "r1", "title": "Chip equipment export restrictions",
                    "text": "A private report on semiconductor equipment and export restrictions.",
                    "url": "https://example.org/announcement", "posted_at": "2026-10-01T18:00:00+00:00"}
            await store.persist_batch(source["id"], [item], "cursor1")
            await store.persist_batch(source["id"], [item], "cursor2")
            board = (await alice.get("/api/briefing")).raise_for_status().json()
            assert not board["first_visit"] and len(board["cards"]) == 1
            card = board["cards"][0]
            sid = card["story_id"]
            assert sid.startswith("private-") and card["private_source"] and card["labels"]["subsectors"]
            assert (await bob.get("/api/stories/" + sid)).status_code == 404
            assert (await bob.put("/api/watches/stories/" + sid, json={"enabled": True})).status_code == 404
            assert sid not in {x["story_id"] for x in (await bob.get("/api/briefing")).json()["cards"]}
            (await alice.put("/api/watches/stories/" + sid, json={"enabled": True})).raise_for_status()
            assert sid in {x["id"] for x in (await alice.get("/api/watches")).json()["stories"]}
            (await ack(alice, board)).raise_for_status()
            caught_up = (await alice.get("/api/briefing")).raise_for_status().json()
            assert not caught_up["cards"] and caught_up["previous_cards"][0]["title"] == item["title"]
            assert sid not in {c["story_id"] for c in (await bob.get("/api/briefing")).json().get("previous_cards", [])}
            await store.persist_batch(source["id"], [{**item, "title": "New rules approved for chip equipment",
                "text": "The revised source confirms the rules were approved."}], "cursor3")
            revised = (await alice.get("/api/briefing")).json()
            assert revised["cards"][0]["story_id"] == sid and "follow" in revised["cards"][0]["reason"].lower()
            timeline = (await alice.get("/api/stories/" + sid)).json()["story"]
            assert len(timeline["developments"]) == 2 and timeline["title"] != item["title"]
            assert (await alice.post("/api/briefing/seen", json={"through": revised["through"],
                "private_through": revised["private_through"] + 10})).status_code == 422
            # A slow earlier tab cannot skip a development or rewind the reader.
            (await ack(alice, initial)).raise_for_status()
            assert (await alice.get("/api/briefing")).json()["cards"]
            (await ack(alice, revised)).raise_for_status()
            token = alice.cookies["session"]

    app = create_app(settings)
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test",
                                     cookies={"session": token}) as alice:
            empty = (await alice.get("/api/briefing")).raise_for_status().json()
            assert not empty["cards"] and not empty["first_visit"]
            assert empty["previous_cards"][0]["title"] == revised["cards"][0]["title"]
            assert (await alice.get("/api/stories/" + sid)).json()["story"]["followed"]
            assert len((await alice.get("/api/watches")).json()["topics"]) == 1
            await app.state.personal.delete_source(uid, source["id"])
            assert not (await alice.get("/api/briefing")).json()["previous_cards"]
            assert (await alice.get("/api/stories/" + sid)).status_code == 404
            assert not (await alice.get("/api/watches")).json()["stories"]
