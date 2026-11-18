"""Inject five fake, significant tweets through the twitterapi.io path.

    jac run fake_tweets [-- --no-wait] [--exit] [--interval 10] [--port 8000]
                        [--vendor-port 8790] [--keep-db] [--verbose]
    jac run fake_tweets -- --remote https://<server> [--no-wait] [--interval 10]

Starts a fake twitterapi.io (REST rule/backfill endpoints and the tweet
WebSocket) and an in-process NewsBot whose x_push adapter connects to it, then
pushes five tweets about major military or government events through the
WebSocket, exactly as the vendor would. The real adapter, classifier, dedup,
notifications, SSE and UI all run.

Isolation: NewsBot runs on a temporary copy of the configured database (your
sign-in works; nothing is written to the real one), Telegram and the official
X API are off, X_PUSH_API_KEY is a fake key, and Expo mobile push is off. Model
calls are real when ANTHROPIC_API_KEY is set (a few cents). Quit the NewsBot app
or `jac run` first: this script serves on the same port so the desktop app can
attach to it.

--remote sends the same five tweets to an already running server instead (a
hosted demo), through its POST /ingest with the X-Admin-Token header from
NEWSBOT_ADMIN_TOKEN or --admin-token. That path skips the X adapter, and the
server's own database and API keys are used.
"""

import argparse;
import asyncio;
import json;
import logging;
import os;
import shutil;
import socket;
import sqlite3;
import sys;
import tempfile;
import time;
import httpx;
import uvicorn;
import from datetime { UTC, datetime }
import from pathlib { Path }
import from fastapi { FastAPI, WebSocket, WebSocketDisconnect }
import adapters.x_push as x_push_module;
import from adapters.base { Json }
import from app { create_app, ensure_ui }
import from config { Settings, load_settings }

glob log: logging.Logger = logging.getLogger("newsstream.fake_tweets");

glob FAKE_KEY: str = "fake-twitterapi-key";

"""One tweet to inject: who posts it and what it says ({hhmm} is the UTC time)."""
obj FakeTweet {
    has handle: str,
        text: str;
}

# Five separate oil-material events (the live classifier is crude-oil
# specific), from configured accounts across the three tiers.
glob TWEETS: list[FakeTweet] = [
         FakeTweet(
             handle="UK_MTO",
             text="UKMTO WARNING: Incident 47NM east of Fujairah. At {hhmm} UTC a laden crude tanker reported being struck by an unknown projectile on her starboard side. Fire on deck, crew reported safe, vessel proceeding to anchorage. Vessels are advised to transit with caution and report any suspicious activity to UKMTO."
         ),
         FakeTweet(
             handle="TankerTrackers",
             text="BREAKING: IRGC Navy fast boats have boarded and seized the Panama-flagged VLCC ARCTIC DAWN in the Strait of Hormuz. AIS shows the tanker turned toward Bandar Abbas at {hhmm} UTC. She was carrying roughly 2 million barrels of Saudi crude loaded at Ras Tanura."
         ),
         FakeTweet(
             handle="FaytuksNetwork",
             text="BREAKING: Israeli Air Force jets have struck Iran's Kharg Island crude export terminal, two Israeli officials say. Iranian state TV confirms explosions and large fires at the loading jetties, which handle about 90% of Iran's crude exports."
         ),
         FakeTweet(
             handle="financialjuice",
             text="WHITE HOUSE: PRESIDENT ORDERS EMERGENCY SALE OF 60 MILLION BARRELS FROM THE STRATEGIC PETROLEUM RESERVE, CITING SUPPLY DISRUPTION IN THE GULF. FIRST DELIVERIES WITHIN 14 DAYS - ENERGY DEPARTMENT"
         ),
         FakeTweet(
             handle="MoloWarMonitor",
             text="Houthi military spokesman announces the group will target every oil tanker transiting Bab el-Mandeb, effective immediately, and claims a ballistic missile strike on a Greek-owned crude tanker in the southern Red Sea at {hhmm} UTC."
         )
     ];

# ---------- fake twitterapi.io ----------

"""Open WebSocket connections from the x_push adapter."""
obj VendorState {
    has clients: list[WebSocket] = [],
        rules: int = 0;
}

def fake_vendor(state: VendorState) -> FastAPI {
    vendor = FastAPI(title="fake twitterapi.io");

    @vendor.get("/oapi/tweet_filter/get_rules")
    async def get_rules -> Json {
        return {"status": "success", "rules": []};
    }

    @vendor.post("/oapi/tweet_filter/add_rule")
    async def add_rule -> Json {
        state.rules += 1;
        return {"status": "success", "rule_id": f"fake-rule-{state.rules}"};
    }

    @vendor.post("/oapi/tweet_filter/update_rule")
    async def update_rule -> Json {
        return {"status": "success"};
    }

    @vendor.delete("/oapi/tweet_filter/delete_rule")
    async def delete_rule -> Json {
        return {"status": "success"};
    }

    # Backfill and the REST polling fallback: nothing to recover.
    @vendor.get("/twitter/user/last_tweets")
    async def last_tweets -> Json {
        return {"status": "success", "tweets": [], "has_next_page": False};
    }

    @vendor.get("/twitter/tweet/advanced_search")
    async def advanced_search -> Json {
        return {"tweets": [], "has_next_page": False, "next_cursor": ""};
    }

    @vendor.websocket("/twitter/tweet/websocket")
    async def tweet_socket(ws: WebSocket) {
        await ws.accept();
        state.clients.append(ws);
        try {
            while True {
                await ws.receive_text();
            }
        } except WebSocketDisconnect {} finally {
            if ws in state.clients {
                state.clients.remove(ws);
            }
        }
    }

    return vendor;
}

"""A vendor "tweet" event for one fake tweet, as the real WebSocket sends it."""
def tweet_event(t: FakeTweet, tweet_id: str, author_id: str) -> Json {
    now = datetime.now(UTC);
    return {
        "event_type": "tweet",
        "rule_tag": "newsstream-0",
        "tweets": [
            {
                "id": tweet_id,
                "type": "tweet",
                "text": t.text.replace("{hhmm}", now.strftime("%H%M")),
                "createdAt": now.strftime(x_push_module.LEGACY_TIME_FMT),
                "author": {"id": author_id, "userName": t.handle}
            }
        ]
    };
}

# ---------- setup and reporting ----------

def port_in_use(host: str, port: int) -> bool {
    with socket.socket() as s {
        s.settimeout(0.3);
        return s.connect_ex((host, port)) == 0;
    }
}

"""Copy the database with SQLite's backup API (safe with WAL files)."""
def copy_db(src: Path, dst: Path) {
    if not src.exists() {
        return;  # a fresh database is created on startup
    }
    source = sqlite3.connect(str(src));
    target = sqlite3.connect(str(dst));
    try {
        source.backup(target);
    } finally {
        target.close();
        source.close();
    }
}

"""Stable account IDs from the database, so posts attach to the real accounts."""
def account_ids(db: Path) -> dict[str, str] {
    out: dict[str, str] = {};
    if not db.exists() {
        return out;
    }
    con = sqlite3.connect(str(db));
    try {
        for (handle, account_id) in con.execute(
            "SELECT handle, account_id FROM accounts WHERE source = 'x'"
        ) {
            out[str(handle).lower()] = str(account_id);
        }
    } finally {
        con.close();
    }
    return out;
}

"""What the pipeline did with one injected tweet, or None while still working."""
def outcome(con: sqlite3.Connection, tweet_id: str, threshold: int) -> str | None {
    row = con.execute(
        "SELECT id FROM posts WHERE source = 'x' AND source_post_id = ?", (tweet_id, )
    ).fetchone();
    if row is None {
        return None;
    }
    post_id = row[0];
    note = con.execute(
        "SELECT kind FROM notifications WHERE post_id = ? ORDER BY id DESC LIMIT 1",
        (post_id, )
    ).fetchone();
    decision = con.execute(
        "SELECT materiality_score, category, error FROM decisions "
        "WHERE post_id = ? AND is_final = 1 ORDER BY id DESC LIMIT 1",
        (post_id, )
    ).fetchone();
    score = "" if decision is None else f"score {decision[0]}, {decision[1]}";
    if decision is not None and decision[2] {
        score += f", {decision[2]}";
    }
    if note is not None {
        return f"{note[0]} ({score})";
    }
    role = con.execute(
        "SELECT role FROM event_posts WHERE post_id = ?", (post_id, )
    ).fetchone();
    if role is not None and role[0] == "duplicate" {
        return f"DUPLICATE of an open event ({score})";
    }
    if decision is not None and decision[2] == "llm_unavailable" {
        return "held: classifier unavailable (no or failing ANTHROPIC_API_KEY)";
    }
    if decision is not None and int(decision[0] or 0) < threshold {
        return f"suppressed below threshold {threshold} ({score})";
    }
    return None;
}

async def wait_for_outcomes(
    db: Path, sent: list[tuple[FakeTweet, str]], threshold: int, timeout: float
) -> dict[str, str] {
    results: dict[str, str] = {};
    deadline = time.monotonic() + timeout;
    while len(results) < len(sent) and time.monotonic() < deadline {
        await asyncio.sleep(1);
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True);
        try {
            for (t, tweet_id) in sent {
                if tweet_id not in results {
                    got = outcome(con, tweet_id, threshold);
                    if got {
                        results[tweet_id] = got;
                        print(f"  @{t.handle}: {got}", flush=True);
                    }
                }
            }
        } finally {
            con.close();
        }
    }
    return results;
}

"""Wait for Enter when interactive, so the presenter picks the moment."""
async def wait_for_go(args: argparse.Namespace) {
    if not args.no_wait and sys.stdin.isatty() {
        await asyncio.to_thread(input, "Press Enter here to send the tweets. ");
    }
}

"""--remote: queue the tweets on a running server's /ingest. Tiers come from
this checkout's config.yaml, as the X adapter would set them."""
async def send_remote(args: argparse.Namespace) -> int {
    settings = load_settings();
    token = args.admin_token or os.environ.get("NEWSBOT_ADMIN_TOKEN", "");
    headers = {"X-Admin-Token": token} if token else {};
    base = args.remote.rstrip("/");
    http = httpx.AsyncClient(base_url=base, timeout=20, headers=headers);
    async with http {
        try {
            await http.get("/status");
        } except httpx.HTTPError as e {
            print(f"Cannot reach {base}: {e}");
            return 2;
        }
        await wait_for_go(args);
        stamp = int(time.time() * 1000);
        for (i, t) in enumerate(TWEETS) {
            if i {
                await asyncio.sleep(args.interval);
            }
            now = datetime.now(UTC);
            tweet_id = f"9{stamp}{i}";
            r = await http.post(
                "/ingest",
                json={
                    "source": "x",
                    "source_post_id": tweet_id,
                    "account_handle": t.handle,
                    "url": f"https://x.com/{t.handle}/status/{tweet_id}",
                    "text": t.text.replace("{hhmm}", now.strftime("%H%M")),
                    "posted_at": now.isoformat(),
                    "tier": settings.tier_for_handle(t.handle)
                }
            );
            if r.status_code == 403 {
                print(
                    "The server refused /ingest: set NEWSBOT_ADMIN_TOKEN to its token."
                );
                return 2;
            }
            r.raise_for_status();
            print(f"sent {i + 1}/{len(TWEETS)}: @{t.handle}", flush=True);
        }
    }
    print("All five are queued. Watch the app for the new cards.");
    return 0;
}

"""Settings for the isolated run: temp database, fake vendor, other feeds off."""
def test_settings(args: argparse.Namespace, db: Path, vendor: str) -> Settings {
    settings = load_settings(db_path=db);
    settings.x_push_enabled = True;
    settings.x_push_api_key = FAKE_KEY;
    settings.x_push_url = vendor.replace("http://", "ws://")
        + "/twitter/tweet/websocket";
    settings.x_api_enabled = False;
    settings.x_bearer_token = "";
    settings.telegram_channels = [];
    if args.port {
        settings.port = args.port;
    }
    # load_settings has already read .env; these win over it
    os.environ["NEWSBOT_MOBILE_PUSH"] = "0";
    return settings;
}

async def run(args: argparse.Namespace) -> int {
    if args.remote {
        return await send_remote(args);
    }
    real = load_settings();
    host = real.host;
    port = args.port or real.port;
    if port_in_use(host, port) {
        print(
            f"Port {port} is in use. Quit the NewsBot app (or stop `jac run`) first, "
            "or pass --port."
        );
        return 2;
    }
    if port_in_use("127.0.0.1", args.vendor_port) {
        print(f"Port {args.vendor_port} is in use; pass --vendor-port.");
        return 2;
    }
    missing = [
        t.handle
        for t in TWEETS
        if t.handle.lower() not in {a.handle.lower() for a in real.accounts}
    ];
    if missing {
        print(f"These handles are not in config.yaml accounts: {', '.join(missing)}");
        return 2;
    }

    tmp = Path(tempfile.mkdtemp(prefix="newsbot-fake-tweets-"));
    db = tmp / "newsstream.db";
    copy_db(real.db_path, db);
    vendor_url = f"http://127.0.0.1:{args.vendor_port}";
    settings = test_settings(args, db, vendor_url);
    # The adapter's REST base is a module constant; point it at the fake too,
    # so rule sync and backfill never reach the real twitterapi.io.
    x_push_module.REST_BASE = vendor_url;
    if not settings.anthropic_api_key {
        print(
            "Note: ANTHROPIC_API_KEY is not set, so tweets cannot be classified and "
            "will be held (official/tracker posts surface UNFILTERED)."
        );
    }

    ensure_ui();
    state = VendorState();
    vendor_server = uvicorn.Server(
        uvicorn.Config(
            fake_vendor(state),
            host="127.0.0.1",
            port=args.vendor_port,
            log_level="warning"
        )
    );
    app_server = uvicorn.Server(
        uvicorn.Config(
            create_app(settings),
            host=settings.host,
            port=settings.port,
            log_level="warning",
            timeout_graceful_shutdown=5
        )
    );
    tasks = [
        asyncio.create_task(vendor_server.serve()),
        asyncio.create_task(app_server.serve())
    ];
    code = 0;
    try {
        deadline = time.monotonic() + 60;
        while not state.clients {
            if time.monotonic() > deadline or any(t.done() for t in tasks) {
                print("NewsBot's x_push adapter did not connect to the fake vendor.");
                return 1;
            }
            await asyncio.sleep(0.5);
        }
        page = f"http://{settings.host}:{settings.port}";
        print(f"NewsBot is running on a copy of your database at {page}");
        print("Its X push feed is connected to the fake twitterapi.io.");
        if not args.no_wait and sys.stdin.isatty() {
            print(
                "Open it in the desktop app (npm run dev in desktop/) or a browser, "
                "sign in, tick Desktop notifications, and switch to another window."
            );
        }
        await wait_for_go(args);

        ids = account_ids(db);
        stamp = int(time.time() * 1000);
        sent: list[tuple[FakeTweet, str]] = [];
        for (i, t) in enumerate(TWEETS) {
            if i {
                await asyncio.sleep(args.interval);
            }
            tweet_id = f"9{stamp}{i}";
            author_id = ids.get(t.handle.lower(), f"fake-{t.handle.lower()}");
            message = json.dumps(tweet_event(t, tweet_id, author_id));
            for ws in list(state.clients) {
                await ws.send_text(message);
            }
            sent.append((t, tweet_id));
            print(
                f"sent {i + 1}/{len(TWEETS)}: @{t.handle} (id {tweet_id})", flush=True
            );
        }

        print("Waiting for the pipeline:");
        results = await wait_for_outcomes(
            db, sent, settings.market.threshold, args.timeout
        );
        surfaced = [
            r
            for r in results.values()
            if r.startswith("NEW_EVENT") or r.startswith("UNFILTERED")
        ];
        print(f"{len(surfaced)}/{len(sent)} tweets surfaced as new cards.");
        if len(surfaced) < len(sent) {
            code = 1;
            for (t, tweet_id) in sent {
                if tweet_id not in results {
                    print(f"  @{t.handle}: no result within {int(args.timeout)}s");
                }
            }
        }
        if not args.exit {
            print(f"Still serving {page}. Press Ctrl+C to stop.");
            await asyncio.gather(*tasks);
        }
    } except (KeyboardInterrupt, asyncio.CancelledError) {
        # Ctrl+C: fall through to shutdown
    } finally {
        # NewsBot first: on shutdown it deactivates its rules at the vendor.
        app_server.should_exit = True;
        await asyncio.gather(tasks[1], return_exceptions=True);
        vendor_server.should_exit = True;
        await asyncio.gather(tasks[0], return_exceptions=True);
        if args.keep_db {
            print(f"Test database kept at {db}");
        } else {
            shutil.rmtree(tmp, ignore_errors=True);
        }
    }
    return code;
}

def main {
    parser = argparse.ArgumentParser(
        description="Inject five fake, significant tweets through the twitterapi.io path."
    );
    parser.add_argument(
        "--no-wait", action="store_true", help="send as soon as the feed connects"
    );
    parser.add_argument(
        "--exit", action="store_true", help="stop once every tweet has a result"
    );
    parser.add_argument(
        "--interval", `type=float, `default=10.0, help="seconds between tweets"
    );
    parser.add_argument(
        "--timeout", `type=float, `default=240.0, help="seconds to wait for results"
    );
    parser.add_argument(
        "--port", `type=int, `default=0, help="NewsBot port (default: config.yaml)"
    );
    parser.add_argument(
        "--vendor-port", `type=int, `default=8790, help="fake twitterapi.io port"
    );
    parser.add_argument(
        "--keep-db", action="store_true", help="keep the temporary database"
    );
    parser.add_argument("--verbose", action="store_true", help="show pipeline logs");
    parser.add_argument(
        "--remote",
        `default="",
        help="send to this running server's /ingest instead (e.g. a hosted demo)"
    );
    parser.add_argument(
        "--admin-token",
        `default="",
        help="--remote: the server's NEWSBOT_ADMIN_TOKEN (default: from the environment)"
    );
    args = parser.parse_args();
    logging.basicConfig(
        level=logging.INFO if args.verbose else logging.WARNING,
        format="%(asctime)s %(levelname)-7s %(name)s | %(message)s",
        force=True
    );
    logging.getLogger("httpx").setLevel(logging.WARNING);
    try {
        sys.`exit(asyncio.run(run(args)));
    } except KeyboardInterrupt {
        sys.`exit(130);
    }
}

with entry:__main__ {
    main();
}
