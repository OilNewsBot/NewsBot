"""Public RSS directory. The bundled edition is always available without a network."""

import asyncio;
import json;
import logging;
import from operator { itemgetter }
import textwrap;
import from datetime { UTC, datetime }
import from pathlib { Path }
import from tempfile { NamedTemporaryFile }
import from urllib.parse { urlsplit }
import from config { ROOT }
import from db.repo { Row }
import from personal.providers { ProviderError, fetch_feed, parse_feed }

glob log = logging.getLogger("newsstream.directory");

def latest_stories(
    items: list[Row], previous: list[Row], checked: str, feed_url: str
) -> list[Row] {
    by_url = {story["url"]: story for story in previous};
    found = False;
    for item in items {
        url = str(item["url"]);
        date = str(item["posted_at"]);
        # Some HTTPS publishers (including FDA) put HTTP links to their own site in RSS.
        if url.startswith("http://")
            and feed_url.startswith("https://")
            and urlsplit(url).netloc == urlsplit(feed_url).netloc {
            url = "https://" + url[7:];
        }
        if not date
            or date > checked
            or url == feed_url
            or not url.startswith("https://") {
            continue;
        }
        found = True;
        old = by_url.get(url, {});
        summary = str(old.get("summary") or "")
            if old.get("title") == item["title"]
            else "";
        if not summary {
            summary = textwrap.shorten(str(item["text"]), width=260, placeholder="…");
        }
        by_url[url] = {
            "url": url,
            "title": item["title"],
            "published": date,
            "summary": summary or "The publisher provided a headline only."
        };
    }
    if not found {
        return [];
    }
    return sorted(by_url.values(), key=itemgetter("published"), reverse=True)[:3];
}

obj PublicDirectory {
    has cache: Path,
        catalog: Row = {};

    def load -> None {
        self.catalog = json.loads(
            (ROOT / "db" / "directory_seed.json").read_text(encoding="utf-8")
        );
        try {
            saved = json.loads(self.cache.read_text(encoding="utf-8"));
            for category in self.catalog["categories"] {
                for channel in category["channels"] {
                    edition = saved.get(channel["feed_url"]);
                    if not isinstance(edition, dict) {
                        continue;
                    }
                    stories = edition.get("headlines");
                    checked = str(edition.get("checked_at") or "");
                    if checked < self.catalog["captured_at"]
                        or not isinstance(stories, list)
                        or not (1 <= len(stories) <= 3) {
                        continue;
                    }
                    if all(
                        isinstance(story, dict)
                            and all(
                                isinstance(story.get(field), str)
                                for field in ["title", "url", "published", "summary"]
                            )
                            and story["url"].startswith("https://") for story in stories
                    ) {
                        channel.update({"checked_at": checked, "headlines": stories});
                    }
                }
            }
        } except FileNotFoundError {
            return;
        } except (OSError, ValueError, AttributeError) as e {
            log.warning("Could not load the saved RSS directory: %s", e);
        }
    }

    def save -> None {
        saved = {
            channel["feed_url"]: {
                "checked_at": channel["checked_at"],
                "headlines": channel["headlines"]
            } for category in self.catalog["categories"]
            for channel in category["channels"]
            if channel.get("checked_at")
        };
        self.cache.parent.mkdir(parents=True, exist_ok=True);
        with NamedTemporaryFile(
            dir=self.cache.parent, mode="w", encoding="utf-8", delete=False
        ) as out {
            tmp = Path(out.name);
            try {
                json.dump(saved, out);
                out.close();
                tmp.replace(self.cache);
            } finally {
                tmp.unlink(missing_ok=True);
            }
        }
    }

    async def refresh(fetcher: any = fetch_feed) -> None {
        updated = False;
        for category in self.catalog["categories"] {
            for channel in category["channels"] {
                try {
                    (body, _, base) = await fetcher(channel["feed_url"]);
                    (_, items) = parse_feed(body, base);
                    checked = datetime.now(UTC).isoformat();
                    stories = latest_stories(
                        items, channel["headlines"], checked, base
                    );
                    if stories {
                        channel.update({"checked_at": checked, "headlines": stories});
                        updated = True;
                    }
                } except (ProviderError, OSError) as e {
                    log.warning(
                        "Keeping saved headlines for %s: %s", channel["slug"], e
                    );
                }
            }
        }
        if updated {
            self.save();
        }
    }

    async def run -> None {
        while True {
            try {
                await self.refresh();
            } except Exception {
                log.exception("RSS refresh failed; the directory is still available");
            }
            await asyncio.sleep(3600);
        }
    }
}
