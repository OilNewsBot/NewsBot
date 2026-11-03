"""Offline ownership, durability and encryption regression tests."""

import asyncio;
import base64;
import os;
import from unittest.mock { patch }
import from personal.store { PersonalStore }
import from tests.helpers { make_settings, open_repo }

glob TEST_KEY: str = base64.urlsafe_b64encode(bytes(range(32))).decode();

def item(id: str, text: str = "Company earnings released") -> dict[str, any] {
    return {
        "external_id": id,
        "title": text,
        "text": text,
        "url": "https://example.com/news/" + id,
        "posted_at": "2026-11-01T12:00:00+00:00"
    };
}

test "personal_store_isolates_users_and_preserves_legacy" {
    async def run {
        settings = make_settings();
        async with open_repo(settings) as repo {
            alice = await repo.create_user("alice", "a@example.test", "unused");
            bob = await repo.create_user("bob", "b@example.test", "unused");
            store = PersonalStore(settings.db_path);
            await store.connect();
            ca = await store.create_connection(alice, "rss", "Alice news");
            cb = await store.create_connection(bob, "rss", "Bob news");
            sa = await store.create_source(
                alice, ca["id"], "same-feed", "News", "https://example.com/feed"
            );
            sb = await store.create_source(
                bob, cb["id"], "same-feed", "News", "https://example.com/feed"
            );
            for s in [sa, sb] {
                await store.persist_batch(s["id"], [item("old")], "baseline");
            }
            assert await store.notification_head(alice) == 0;
            await store.persist_batch(
                sa["id"], [item("new", "Alice private earnings")], "a-cursor"
            );
            await store.persist_batch(
                sb["id"], [item("new", "Bob private earnings")], "b-cursor"
            );
            assert len(await store.feed(alice)) == 2;
            assert (await store.feed(alice))[0]["text"] == "Alice private earnings";
            assert (await store.feed(bob))[0]["text"] == "Bob private earnings";
            assert len(await store.notifications_since(alice)) == 1;
            try {
                await store.get_source(bob, sa["id"]);
                assert False;
            } except KeyError {}
            try {
                await store.delete_connection(bob, ca["id"]);
                assert False;
            } except KeyError {}
            assert len(await store.list_connections(alice)) == 1;
            assert len(await repo.notifications_since(0)) == 0;
            assert len(await repo.feed()) == 0;
            assert len(await repo.suppressed()) == 0;
            await store.close();
            reopened = PersonalStore(settings.db_path);
            await reopened.connect();
            await reopened.persist_batch(
                sa["id"], [item("new", "Corrected report")], "next-cursor"
            );
            assert len(await reopened.notifications_since(alice)) == 1;
            assert (await reopened.get_source(alice, sa["id"]))["cursor"]
                == "next-cursor";
            await reopened.delete_source(alice, sa["id"]);
            await reopened.persist_batch(sa["id"], [item("late")], "ignored");
            assert len(await reopened.feed(alice)) == 0;
            assert len(await reopened.notifications_since(alice)) == 0;
            assert len(await reopened.notifications_since(bob)) == 1;
            await reopened.close();
        }
    }
    asyncio.run(run());
}

test "personal_filters_mute_pause_and_atomic_checkpoint" {
    async def run {
        settings = make_settings();
        async with open_repo(settings) as repo {
            uid = await repo.create_user("reader", "r@example.test", "unused");
            store = PersonalStore(settings.db_path);
            await store.connect();
            c = await store.create_connection(uid, "rss", "News");
            s = await store.create_source(
                uid,
                c["id"],
                "f",
                "Feed",
                "https://example.com/feed",
                include_keywords=["earnings"],
                exclude_keywords=["rumor"]
            );
            await store.persist_batch(s["id"], [], "baseline");
            await store.persist_batch(
                s["id"],
                [item("1"), item("2", "Earnings rumor"), item("3", "Football result")],
                "c1"
            );
            assert len(await store.feed(uid)) == 3;
            assert len(await store.notifications_since(uid)) == 1;
            await store.update_source(uid, s["id"], {"alerts_enabled": False});
            await store.persist_batch(s["id"], [item("4")], "c2");
            assert len(await store.feed(uid)) == 4;
            assert len(await store.notifications_since(uid)) == 0;
            await store.update_source(uid, s["id"], {"enabled": False});
            await store.persist_batch(s["id"], [item("ignored")], "bad");
            assert len(await store.feed(uid)) == 4;
            await store.update_source(
                uid, s["id"], {"enabled": True, "alerts_enabled": True}
            );
            assert (await store.get_source(uid, s["id"]))["cursor"] == "";
            await store.persist_batch(s["id"], [item("while-paused")], "resumed");
            assert await store.notification_head(uid) == 1;
            try {
                await store.persist_batch(
                    s["id"], [item("rollback"), {}], "must-not-commit"
                );
                assert False;
            } except KeyError {}
            assert (await store.get_source(uid, s["id"]))["cursor"] == "resumed";
            assert all(i["external_id"] != "rollback" for i in await store.feed(uid));
            await store.persist_batch(s["id"], [item("final")], "done");
            assert len(await store.notifications_since(uid)) == 1;
            await store.close();
        }
    }
    asyncio.run(run());
}

test "personal_feed_orders_by_publication_not_provider_batch_order" {
    async def run {
        settings = make_settings();
        async with open_repo(settings) as repo {
            uid = await repo.create_user("reader", "order@example.test", "unused");
            store = PersonalStore(settings.db_path);
            await store.connect();
            c = await store.create_connection(uid, "rss", "News");
            s = await store.create_source(
                uid, c["id"], "feed", "Feed", "https://example.com/feed"
            );
            newest = item("newest") | {"posted_at": "2026-11-02T12:00:00+00:00"};
            older = item("older") | {"posted_at": "2026-11-01T12:00:00+00:00"};
            await store.persist_batch(s["id"], [newest, older], "baseline");
            feed = await store.feed(uid);
            assert [post["external_id"] for post in feed] == ["newest", "older"];
            await store.close();
        }
    }
    asyncio.run(run());
}

test "personal_stale_collection_cannot_undo_pause_or_rekey" {
    async def run {
        settings = make_settings();
        async with open_repo(settings) as repo {
            uid = await repo.create_user("race", "race@example.test", "unused");
            store = PersonalStore(settings.db_path);
            await store.connect();
            with patch.dict(os.environ, {"NEWSBOT_CONNECTION_KEY": TEST_KEY}) {
                c = await store.create_connection(uid, "x", "X", "before");
                s = await store.create_source(
                    uid, c["id"], "42", "News", "https://x.com/news"
                );
                snap = (await store.active_sources())[0];
                await store.update_source(uid, s["id"], {"enabled": False});
                await store.update_source(uid, s["id"], {"enabled": True});
                await store.persist_batch(
                    s["id"],
                    [item("stale")],
                    "stale",
                    source_revision=snap["revision"],
                    connection_revision=snap["connection_revision"]
                );
                assert len(await store.feed(uid)) == 0;
                assert not (await store.get_source(uid, s["id"]))["initialized"];
                await store.reconnect_connection(uid, c["id"], "replacement");
                await store.source_failure(
                    s["id"],
                    "needs_reconnect",
                    "Old key rejected",
                    "2099-01-01T00:00:00+00:00",
                    source_revision=snap["revision"],
                    connection_revision=snap["connection_revision"]
                );
                assert (await store.get_connection(uid, c["id"]))["status"]
                    == "configured";
                snap = (await store.active_sources())[0];
                await store.connection_failure(
                    c["id"], "rate_limited", "Back off", "2099-01-01T00:00:00+00:00"
                );
                await store.source_success(
                    s["id"],
                    "",
                    source_revision=snap["revision"],
                    connection_revision=snap["connection_revision"]
                );
                assert (await store.get_connection(uid, c["id"]))["status"]
                    == "rate_limited";
                assert not await store.claim_request(c["id"]);
                assert len(await store.active_sources()) == 0;
                # A source-local RSS failure must not stop unrelated feed hosts.
                rss = await store.create_connection(uid, "rss", "RSS");
                rs = await store.create_source(
                    uid, rss["id"], "feed1", "F1", "https://example.com/feed1"
                );
                rs2 = await store.create_source(
                    uid, rss["id"], "feed2", "F2", "https://example.com/feed2"
                );
                await store.source_failure(
                    rs["id"], "rate_limited", "Feed paused", "2099-01-01T00:00:00+00:00"
                );
                assert (await store.get_connection(uid, rss["id"]))["status"]
                    == "connected";
                assert any(r["id"] == rs2["id"] for r in await store.active_sources());
            }
            await store.close();
        }
    }
    asyncio.run(run());
}

test "personal_credentials_fail_closed_and_budget_persists" {
    async def run {
        settings = make_settings();
        async with open_repo(settings) as repo {
            uid = await repo.create_user("reader", "r@example.test", "unused");
            store = PersonalStore(settings.db_path);
            await store.connect();
            with patch.dict(os.environ, {"NEWSBOT_CONNECTION_KEY": ""}) {
                try {
                    await store.create_connection(uid, "x", "X", "sample-secret");
                    assert False;
                } except RuntimeError {}
            }
            assert len(await store.list_connections(uid)) == 0;
            with patch.dict(os.environ, {"NEWSBOT_CONNECTION_KEY": TEST_KEY}) {
                conn = await store.create_connection(
                    uid, "x", "X", "sample-secret", daily_limit=2
                );
                assert await store.connection_secret(conn["id"]) == "sample-secret";
                assert "secret" not in conn and "fingerprint" not in conn;
                raw = await store._one(
                    "SELECT secret FROM personal_connections WHERE id=?", (conn["id"], )
                );
                assert raw is not None and "sample-secret" not in raw["secret"];
                try {
                    store.vault.open(raw["secret"], "wrong-owner");
                    assert False;
                } except RuntimeError {}
                try {
                    await store.create_connection(
                        uid, "x", "Duplicate", "sample-secret"
                    );
                    assert False;
                } except ValueError {}
                assert await store.claim_request(conn["id"]);
                await store.close();
                await store.connect();
                assert await store.claim_request(conn["id"]);
                assert not await store.claim_request(conn["id"]);
                assert (await store.get_connection(uid, conn["id"]))["requests_today"]
                    == 2;
                await store.delete_connection(uid, conn["id"]);
                try {
                    await store.connection_secret(conn["id"]);
                    assert False;
                } except KeyError {}
                raw = await store._one(
                    "SELECT secret,fingerprint FROM personal_connections WHERE id=?",
                    (conn["id"], )
                );
                assert raw is not None
                    and raw["secret"] == ""
                    and raw["fingerprint"] is None;
            }
            await store.close();
        }
    }
    asyncio.run(run());
}
