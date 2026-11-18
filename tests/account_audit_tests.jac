"""Offline service regressions for registration and personal RSS ingestion."""

import asyncio;
import httpx;
import from app { create_app }
import from db.repo { Repo }
import from personal.providers { parse_feed }
import from personal.store { PersonalStore }
import from tests.helpers { make_settings, open_repo }

test "duplicate username gives a recoverable registration conflict" {
    async def run {
        app = create_app(make_settings());
        repo: Repo = getattr(app.state, "repo");
        await repo.connect();
        try {
            client = httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="http://test"
            );
            async with client {
                account = {
                    "username": "Auditor",
                    "email": "first@example.test",
                    "password": "offline-testing-only"
                };
                assert (await client.post("/register", json=account)).status_code
                    == 200;
                account["email"] = "second@example.test";
                conflict = await client.post("/register", json=account);
                assert conflict.status_code == 409
                    and "username" in conflict.json()["detail"].lower();
                # Another SQLite writer can continue immediately after the conflict.
                peer = Repo(repo.db_path);
                await peer.connect();
                try {
                    assert await peer.create_user(
                        "Peer", "peer@example.test", "unused"
                    );
                } finally {
                    await peer.close();
                }
                account["username"] = "AnotherAuditor";
                assert (await client.post("/register", json=account)).status_code
                    == 200;
            }
        } finally {
            await repo.close();
        }
    }
    asyncio.run(run());
}

test "personal RSS delivers description-only bulletins and full-text keyword matches" {
    async def run {
        settings = make_settings();
        async with open_repo(settings) as repo {
            owner = await repo.create_user("owner", "owner@example.test", "unused");
            store = PersonalStore(settings.db_path);
            await store.connect();
            try {
                conn = await store.create_connection(owner, "rss", "Bulletins");
                url = "https://example.test/rss";
                source = await store.create_source(
                    owner, conn["id"], "test", "Alerts", url
                );
                sid = int(source["id"]);
                (_, items) = parse_feed(
                    b"<rss><channel><item><description>First bulletin</description></item><item><description>Second bulletin</description></item></channel></rss>",
                    url
                );
                await store.persist_batch(sid, [], "baseline");
                await store.persist_batch(sid, items, "both");
                await store.persist_batch(sid, items, "repeat");
                assert len(await store.feed(owner)) == 2;
                assert len(await store.notifications_since(owner)) == 2;
                # Simulate a pre-upgrade row and verify the next poll preserves
                # its item ID and notification rather than alerting again.
                await store._run(
                    "UPDATE personal_items SET external_id=? WHERE source_id=? AND text=?",
                    (items[0]["legacy_external_id"], sid, "First bulletin")
                );
                await store.db.commit();
                await store.persist_batch(sid, items, "upgrade");
                assert len(await store.feed(owner)) == 2
                    and len(await store.notifications_since(owner)) == 2;

                await store.update_source(
                    owner, sid, {"include_keywords": ["refinery"]}
                );
                (_, full) = parse_feed(
                    b'<rss xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><item><guid>news-1</guid><title>Update</title><description>Read more</description><content:encoded>Refinery closed due to flooding.</content:encoded></item></channel></rss>',
                    url
                );
                await store.persist_batch(sid, full, "full");
                messages = await store.notifications_since(owner);
                assert len(messages) == 1
                    and messages[0]["text"] == "Refinery closed due to flooding.";
            } finally {
                await store.close();
            }
        }
    }
    asyncio.run(run());
}

test "Atom article resolves inherited xml bases from feed entry and link" {
    (_, items) = parse_feed(
        b'<feed xmlns="http://www.w3.org/2005/Atom" xml:base="https://news.example.org/articles/"><entry xml:base="daily/"><title>Bulletin</title><link xml:base="reports/" href="dispatch.html"/></entry></feed>',
        "https://feeds.example.net/current.xml"
    );
    assert items[0]["url"]
        == "https://news.example.org/articles/daily/reports/dispatch.html";
}
