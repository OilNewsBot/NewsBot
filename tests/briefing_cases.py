"""Offline regression scenarios for story identity and account-owned briefing visits."""
import sqlite3
import tempfile
from pathlib import Path

from fastapi import HTTPException

from publicnews.catalog import Catalog
from publicnews.storytext import changed_excerpt, meaningful_change


async def briefing_regressions():
    assert meaningful_change("Outlook", "Expected growth of +2%.", "Outlook", "Expected growth of -2%.")
    assert changed_excerpt("Expected growth of +2%.", "Outlook", "Expected growth of -2%.") == "Expected growth of -2%."
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "news.db"
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE users(id INTEGER PRIMARY KEY)")
            db.executemany("INSERT INTO users VALUES(?)", [(1,), (2,)])
        channels = [{"name": name, "slug": name, "description": "Industry reports", "publisher": name,
                     "feed_url": f"https://{name}.example/rss", "headlines": []} for name in ("wire", "desk")]
        edition = {"curator": "Editors", "captured_at": "2025-01-01", "categories": [
            {"slug": "tech", "channels": channels}]}
        catalog = Catalog(path, edition)
        await catalog.start()
        ids = await catalog.run_db(lambda db: {row["slug"]: row["source_id"] for row in db.execute(
            "SELECT slug,source_id FROM news_channels")})
        async def ingest(source, external, title, body, url=None):
            return await catalog.run_db(Catalog._item, ids[source], external,
                url or f"https://{source}.example/{external}", title, body, source,
                "2025-01-02T10:00:00+00:00", "tech", False, "2025-01-02T11:00:00+00:00", write=True)
        title = "Export restrictions tighten on advanced semiconductor manufacturing equipment in Texas"
        body = "Officials identified two plants in the report."
        await ingest("wire", "report", title, body)
        first = await catalog.briefing(1)
        assert first["first_visit"] and len(first["cards"]) == 1 and first["since"] is None
        card = first["cards"][0]
        sid = card["story_id"]
        assert card["sources"][0]["url"] == "https://wire.example/report" and not card["followed"]
        assert card["labels"]["events"] and card["labels"]["places"]
        assert (await catalog.briefing(1))["first_visit"], "Reading must not consume updates"
        await catalog.follow_story(1, sid, True)
        seen = await catalog.acknowledge_briefing(1, first["through"])
        assert not (await catalog.briefing(1))["cards"]
        revisit = await catalog.acknowledge_briefing(1, first["through"])
        assert revisit["visited_at"] > seen["visited_at"]
        assert (await catalog.acknowledge_briefing(1, first["through"])) == revisit
        await ingest("wire", "report", title + "!", body.upper())
        await ingest("desk", "syndicated", title, body, "https://wire.example/report?utm_source=reader")
        assert not (await catalog.briefing(1))["cards"], "Cosmetic edits and syndicated links should stay silent"
        await ingest("desk", "coverage", title, "A second publisher reports on the restrictions.")
        updates = await catalog.briefing(1)
        assert len(updates["cards"]) == 1
        revised = updates["cards"][0]
        assert revised["change"] == "Additional source" and revised["source_count"] == 2 and revised["followed"]
        assert {s["name"] for s in revised["sources"]} == {"wire", "desk"}
        assert revised["reason"] and revised["development_count"] == 2
        await ingest("wire", "report", "Revised export restrictions on semiconductor equipment",
                     "Officials now identify four affected plants in Texas.")
        # Acknowledging the previously rendered snapshot must leave this later item visible.
        await catalog.acknowledge_briefing(1, updates["through"])
        current = (await catalog.briefing(1))["cards"]
        assert len(current) == 1 and current[0]["story_id"] == sid
        assert current[0]["change"] == "Publisher update" and "four" in current[0]["delta"]
        original = (await catalog.story(sid))["developments"][-1]
        assert original["title"] == title and "two" in original["summary"]
        try:
            await catalog.acknowledge_briefing(1, 10**8)
        except HTTPException as exc:
            assert exc.status_code == 422
        else:
            raise AssertionError("A visit advanced beyond its rendered snapshot")
        assert (await catalog.watches(2))["stories"] == []
        assert not (await catalog.story(sid, 2))["followed"]
        await catalog.follow_topic(2, "place.texas~event.export-restrictions", True)
        await catalog.follow_topic(2, "event.export-restrictions~place.texas", True)
        watched = (await catalog.watches(2))["topics"]
        assert len(watched) == 1 and watched[0]["id"] == "event.export-restrictions~place.texas"
        await ingest("wire", "weather", "Weather in Texas", "A cold front is expected.")
        second = await catalog.briefing(2)
        assert second["first_visit"] and [c["id"] for c in second["cards"]] == [sid]
        assert watched[0]["label"] in second["cards"][0]["reason"]
        for bad in ("no.such.label", "", "place.texas~place.texas"):
            try:
                await catalog.follow_topic(2, bad, True)
            except HTTPException as exc:
                assert exc.status_code == 422
            else:
                raise AssertionError("An invalid topic watch was accepted")
        restarted = Catalog(path, edition)
        await restarted.start()
        assert (await restarted.story(sid, 1))["followed"]
        assert len((await restarted.story(sid))["developments"]) == 3
        await restarted.acknowledge_briefing(1, (await restarted.briefing(1))["through"])
        def burst(db):
            for n in range(103):
                Catalog._item(db, ids["wire"], "report", "https://wire.example/report", title,
                              f"Officials identified {n} plants in Texas.", "wire", "2025-01-02", "tech",
                              False, "2025-01-03")
        await restarted.run_db(burst, write=True)
        page = await restarted.briefing(1)
        assert page["has_more"] and page["cards"][0]["delta"] == "Officials identified 99 plants in Texas."
        await restarted.acknowledge_briefing(1, page["through"])
        final = await restarted.briefing(1)
        assert not final["has_more"] and final["cards"][0]["delta"] == "Officials identified 102 plants in Texas."
        acknowledged = await restarted.acknowledge_briefing(1, final["through"])
        assert (await restarted.acknowledge_briefing(1, page["through"])) == acknowledged

        # Exercise a prior installation whose normalized items predate the story journal.
        with sqlite3.connect(path) as db:
            for table in ("news_brief_visits", "news_topic_follows", "news_story_follows",
                          "news_developments", "news_story_items", "news_stories"):
                db.execute(f"DROP TABLE {table}")
        await restarted.start()
        counts = await restarted.run_db(lambda db: db.execute("""SELECT (SELECT COUNT(*) FROM news_items),
                                                (SELECT COUNT(*) FROM news_story_items)""").fetchone())
        assert counts[0] == counts[1] == 4
        a = await ingest("wire", "opec", "OPEC reviews crude production cuts following sanctions", "OPEC met yesterday.")
        b = await ingest("desk", "cuts", "OPEC discusses crude production cuts following sanctions", "OPEC held a meeting.")
        c = await ingest("desk", "unrelated", "Sanctions spur OPEC members to change shipping insurance", "OPEC held a meeting.")
        assigned = await restarted.run_db(lambda db: dict(db.execute(
            "SELECT item_id,story_id FROM news_story_items WHERE item_id IN (?,?,?)", (a, b, c))))
        assert assigned[a] == assigned[b] and assigned[c] != assigned[a]
