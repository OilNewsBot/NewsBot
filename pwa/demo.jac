"""Local browser demo. Replay existing test news through the personal collector."""

import argparse;
import asyncio;
import os;
import uvicorn;
import from pathlib { Path }
import from unittest.mock { patch }
import from app { create_app, ensure_ui }
import from config { ROOT, load_settings }
import from db.repo { Repo, Row }
import from personal.store { PersonalStore }
import from personal.worker { PersonalWorker }
import from replay { load_posts }

glob DEMO_DB: Path = ROOT / "data" / "pwa-demo.db",
     DEMO_LABEL: str = "Web Push fixture replay",
     SOURCE_A: str = "kharg-fixture",
     SOURCE_B: str = "other-fixture";

def fixture_item(post_id: str) -> Row {
    for post in load_posts(ROOT / "tests" / "fixtures") {
        if str(post["source_post_id"]) == post_id {
            return {
                "external_id": post_id,
                "text": post["text"],
                "title": "",
                "url": post["url"],
                "posted_at": post["posted_at"]
            };
        }
    }
    raise ValueError("Unknown fixture post ID");
}

async def idle_fetch(source: Row, _secret: str) -> tuple[list[Row], str] {
    return ([], source["cursor"]);
}

async def collect_fixture(store: PersonalStore, source: Row, item: Row) {
    async def fetch(row: Row, _secret: str) -> tuple[list[Row], str] {
        return ([item], str(item["external_id"]));
    }
    worker = PersonalWorker(store, fetcher=fetch);
    await worker.collect(source);
}

async def demo_source(
    store: PersonalStore, repo: Repo, email: str, locator: str, create: bool
) -> Row {
    user = await repo.get_user_by_email(email.lower());
    if not user {
        raise ValueError("Register both demo accounts in NewsStream first");
    }
    uid = int(user["id"]);
    for source in await store.list_sources(uid) {
        if source["remote_id"] == locator {
            return source;
        }
    }
    if not create {
        raise ValueError("Seed the demo sources first");
    }
    connections = await store.list_connections(uid);
    connection = next(
        (
            c
            for c in connections
            if c["label"] == DEMO_LABEL
        ),
        None
    );
    if not connection {
        connection = await store.create_connection(uid, "rss", DEMO_LABEL);
    }
    source = await store.create_source(
        uid,
        connection["id"],
        locator,
        "Demo feed: " + locator,
        "https://example.invalid/" + locator,
        include_keywords=["kharg"],
        exclude_keywords=["wire"]
    );
    await store.persist_batch(source["id"], [], "baseline");
    return await store.get_source(uid, source["id"]);
}

async def replay_to_demo(args: any) {
    if args.alice.lower() == args.bob.lower() {
        raise ValueError("Use two different demo accounts");
    }
    if not DEMO_DB.is_file() {
        raise ValueError("Start the local PWA demo server first");
    }
    repo = Repo(DEMO_DB);
    store = PersonalStore(DEMO_DB);
    await repo.connect();
    await store.connect();
    try {
        seed = args.command == "seed";
        alice = await demo_source(store, repo, args.alice, SOURCE_A, seed);
        await demo_source(store, repo, args.bob, SOURCE_B, seed);
        if not seed {
            await collect_fixture(store, alice, fixture_item(args.post_id));
        }
        for email in [args.alice, args.bob] {
            user = await repo.get_user_by_email(email.lower());
            print(
                email, "notification head:", await store.notification_head(user["id"])
            );
        }
    } finally {
        await store.close();
        await repo.close();
    }
}

def main {
    parser = argparse.ArgumentParser(description=__doc__);
    commands = parser.add_subparsers(dest="command", required=True);
    commands.add_parser("serve");
    seed = commands.add_parser("seed");
    emit = commands.add_parser("emit");
    for command in [seed, emit] {
        command.add_argument("--alice", required=True);
        command.add_argument("--bob", required=True);
    }
    emit.add_argument("post_id");
    args = parser.parse_args();
    if args.command != "serve" {
        asyncio.run(replay_to_demo(args));
        return;
    }
    # This server uses a separate DB, a loopback listener, and offline collection.
    for key in (
        "ANTHROPIC_API_KEY",
        "TELEGRAM_API_ID",
        "TELEGRAM_API_HASH",
        "TELEGRAM_BOT_TOKEN",
        "X_BEARER_TOKEN",
        "X_PUSH_API_KEY",
        "NEWSBOT_MOBILE_PUSH",
        "NEWSBOT_PUBLIC_PWA"
    ) {
        os.environ[key] = "";
    }
    settings = load_settings(db_path=DEMO_DB);
    settings.host = "127.0.0.1";
    settings.port = 8011;
    ensure_ui();
    with patch("personal.worker.fetch_source", new=idle_fetch) {
        uvicorn.run(
            create_app(settings),
            host=settings.host,
            port=settings.port,
            timeout_graceful_shutdown=5
        );
    }
}

with entry:__main__ {
    main();
}
