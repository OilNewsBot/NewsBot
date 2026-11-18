"""Replay fixture posts through the live pipeline at 10x speed (docs/spec.md §11).

    jac run replay -- tests/fixtures/ [--base-url http://localhost:8000]
                                      [--speed 10] [--preserve-timestamps]

Posts go to the running server's /ingest endpoint so the real pipeline and UI
are exercised without live platform credentials. A local server accepts them
from this machine; a server with NEWSBOT_ADMIN_TOKEN set needs the same token
here (environment or --admin-token). By default posted_at is
rewritten to ~20s before send time so cards look current and latency badges
are sensible; --preserve-timestamps keeps the original September 2026 times.
Gaps between posts are capped at 300s of original time, then divided by
--speed. Works offline if cassettes are recorded (NEWSSTREAM_CASSETTE on the
server process).
"""

import argparse;
import asyncio;
import json;
import logging;
import math;
import os;
import sys;
import httpx;
import from datetime { UTC, datetime, timedelta }
import from pathlib { Path }
import from adapters.base { Json }

glob MAX_GAP_S: float = 300.0;

def posted_time(post: Json) -> datetime {
    dt = datetime.fromisoformat(post["posted_at"]);
    return dt.astimezone(UTC) if dt.tzinfo else dt.replace(tzinfo=UTC);
}

def load_posts(fixtures_dir: Path) -> list[Json] {
    posts: list[Json] = [];
    files = sorted(fixtures_dir.glob("*.json"));
    if not files {
        sys.`exit(f"no fixture .json files in {fixtures_dir}");
    }
    for f in files {
        data = json.loads(f.read_text());
        for p in data.get("posts", []) {
            post = dict(p);
            post.pop("expect", None);
            posts.append(post);
        }
    }
    posts.sort(key=posted_time);
    return posts;
}

async def replay(
    posts: list[Json], base_url: str, speed: float, preserve_ts: bool, token: str
) {
    if not math.isfinite(speed) or speed <= 0 {
        sys.`exit("--speed must be a finite number greater than zero");
    }
    headers = {"X-Admin-Token": token} if token else {};
    http = httpx.AsyncClient(base_url=base_url, timeout=10, headers=headers);
    async with http {
        try {
            await http.get("/status");
        } except httpx.HTTPError {
            sys.`exit(f"cannot reach {base_url} - start the server first: jac run");
        }
        prev_ts: datetime | None = None;
        for (i, p) in enumerate(posts, 1) {
            ts = posted_time(p);
            if prev_ts is not None {
                gap = min((ts - prev_ts).total_seconds(), MAX_GAP_S);
                await asyncio.sleep(max(0.0, gap) / speed);
            }
            prev_ts = ts;
            if not preserve_ts {
                p["posted_at"] = (
                    datetime.now(UTC) - timedelta(seconds=20)
                ).isoformat();
                p.pop("received_at", None);
            }
            r = await http.post("/ingest", json=p);
            if r.status_code == 403 {
                sys.`exit(
                    "the server refused /ingest: set NEWSBOT_ADMIN_TOKEN to its token"
                );
            }
            r.raise_for_status();
            print(
                f"[{i}/{len(posts)}] @{p['account_handle']}: {p['text'][:70]!r} -> queued"
            );
        }
    }
    print("replay complete - watch the UI");
}

def main {
    ap = argparse.ArgumentParser(
        prog="jac run replay --",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter
    );
    ap.add_argument("fixtures", `type=Path, help="directory of fixture .json files");
    ap.add_argument("--base-url", `default="http://localhost:8000");
    ap.add_argument("--speed", `type=float, `default=10.0);
    ap.add_argument("--preserve-timestamps", action="store_true");
    ap.add_argument(
        "--admin-token",
        `default=os.environ.get("NEWSBOT_ADMIN_TOKEN", ""),
        help="the server's NEWSBOT_ADMIN_TOKEN (default: from the environment)"
    );
    args = ap.parse_args();
    # The jac runtime's root log handler would print one line per HTTP request.
    logging.getLogger("httpx").setLevel(logging.WARNING);
    asyncio.run(
        replay(
            load_posts(args.fixtures),
            args.base_url,
            args.speed,
            args.preserve_timestamps,
            args.admin_token
        )
    );
}

with entry:__main__ {
    main();
}
