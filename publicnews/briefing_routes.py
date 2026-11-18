"""Session-owned briefing visits and watches, with separate private source storage."""
from fastapi import HTTPException, Request, Response

from personal import briefing as private
from . import briefing as journal
from .topics import facets, taxonomy


def _number(value):
    if type(value) is not int or not 0 <= value < 2**63:
        raise HTTPException(422, "Invalid briefing cursor")
    return value


def _story_key(raw):
    private_id = raw.startswith("private-")
    digits = raw.removeprefix("private-")
    if not digits.isascii() or not digits.isdigit() or len(digits) > 19 or not 0 < int(digits) < 2**63:
        raise HTTPException(404, "Story not found")
    return private_id, int(digits)


def _owner(user, body):
    uid = user["user_id"]
    if "user_id" in body and (type(body["user_id"]) is not int or uid != body["user_id"]):
        raise HTTPException(409, "Your signed-in account changed. Reload this page.")
    return uid


def _enabled(body):
    if type(body.get("enabled")) is not bool:
        raise HTTPException(422, "Set enabled to true or false")
    return body["enabled"]


def install(app, catalog, reader, viewer, writer, has_personal):
    @app.get("/api/briefing")
    async def briefing(request: Request, response: Response):
        response.headers["Cache-Control"] = "private, no-store"
        uid = (await reader(request))["user_id"]
        if not has_personal:
            return await catalog.briefing(uid)

        def snapshot(db):
            result = journal.read_briefing(db, uid)
            topics = journal.watches(db, uid)["topics"]
            extra, head, more = private.edition(db, uid, result["first_visit"], topics)
            result["private_through"] = head
            result["has_more"] = result.get("has_more", False) or more
            if extra:
                result["cards"] = sorted([*result["cards"], *extra], key=lambda c: c["updated_at"], reverse=True)
            return result

        return await catalog.run_db(snapshot, write=True)

    @app.post("/api/briefing/seen")
    async def seen(request: Request, body: dict):
        uid = _owner(await writer(request), body)
        callback = None
        if has_personal and "private_through" in body:
            cursor = _number(body["private_through"])
            def callback(db, owner):
                private.acknowledge(db, owner, cursor)
        return await catalog.acknowledge_briefing(uid, _number(body.get("through")), callback)

    @app.get("/api/watches")
    async def watches(request: Request, response: Response):
        response.headers["Cache-Control"] = "private, no-store"
        uid = (await reader(request))["user_id"]
        result = await catalog.watches(uid)
        if has_personal:
            result["stories"].extend(await catalog.run_db(private.watches, uid))
        return {**result, "user_id": uid, "taxonomy": taxonomy(), "facets": facets()}

    @app.put("/api/watches/topics/{topic_id}")
    async def set_topic(request: Request, topic_id: str, body: dict):
        uid = _owner(await writer(request), body)
        return await catalog.follow_topic(uid, topic_id, _enabled(body))

    @app.put("/api/watches/stories/{story_id}")
    async def set_story(request: Request, story_id: str, body: dict):
        uid = _owner(await writer(request), body)
        is_private, number = _story_key(story_id)
        enabled = _enabled(body)
        if is_private:
            if not has_personal:
                raise HTTPException(404, "Story not found")
            return await catalog.run_db(private.watch, uid, number, enabled, write=True)
        return await catalog.follow_story(uid, number, enabled)

    @app.get("/api/stories/{story_id}")
    async def story(request: Request, response: Response, story_id: str):
        response.headers["Cache-Control"] = "private, no-store"
        is_private, number = _story_key(story_id)
        if is_private:
            uid = (await reader(request))["user_id"]
            if not has_personal:
                raise HTTPException(404, "Story not found")
            detail = await catalog.run_db(private.story, uid, number)
        else:
            detail = await catalog.story(number, await viewer(request))
        return {"story": detail}
