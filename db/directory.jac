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
import from pipeline.forum_routing { ForumRouter }
import from personal.providers { ProviderError, fetch_feed, parse_feed }

glob log = logging.getLogger("newsstream.directory");

def latest_stories(
    items: list[Row], previous: list[Row], checked: str, feed_url: str, limit: int = 3
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
            ** (old if old.get("title") == item["title"] else {}),
            "url": url,
            "title": item["title"],
            "published": date,
            "summary": summary or "The publisher provided a headline only."
        };
    }
    if not found {
        return [];
    }
    return sorted(by_url.values(), key=itemgetter("published"), reverse=True)[:limit];
}

obj PublicDirectory {
    has cache: Path,
        catalog: Row = {},
        router: ForumRouter = ForumRouter();

    def sections -> list[str] {
        return [section["slug"] for section in self.catalog["categories"]];
    }

    def channels -> list[Row] {
        return [
            channel for category in self.catalog["categories"]
            for channel in category["channels"]
        ]
            + self.catalog.get("publishers", []);
    }

    def rss_channels -> list[Row] {
        return [
            channel
            for channel in self.channels()
            if channel.get("feed_url")
        ];
    }

    def view -> Row {
        categories: list[Row] = [];
        for category in self.catalog["categories"] {
            channels = list(category["channels"]);
            for publisher in self.catalog.get("publishers", []) {
                matches = [
                    story
                    for story in publisher["headlines"]
                    if story.get("section") == category["slug"]
                ];
                if matches {
                    channels.append({** publisher, "headlines": matches[:3]});
                }
            }
            categories.append({** category, "channels": channels});
        }
        return {** self.catalog, "categories": categories};
    }

    def load -> None {
        self.catalog = json.loads(
            (ROOT / "db" / "directory_seed.json").read_text(encoding="utf-8")
        );
        try {
            saved = json.loads(self.cache.read_text(encoding="utf-8"));
        } except FileNotFoundError {
            saved = {};
        } except (OSError, ValueError) as e {
            log.warning("Could not load the saved RSS directory: %s", e);
            saved = {};
        }
        publishers = self.catalog.get("publishers", []);
        sections = self.sections();
        for channel in self.rss_channels() {
            edition = saved.get(channel["feed_url"])
                if isinstance(saved, dict)
                else None;
            if isinstance(edition, dict) {
                stories = edition.get("headlines");
                checked = str(edition.get("checked_at") or "");
                limit = 24 if channel in publishers else 3;
                if checked >= self.catalog["captured_at"]
                    and isinstance(stories, list)
                    and 1 <= len(stories) <= limit
                    and all(
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
            if channel in publishers {
                self.router.assign_local(channel["headlines"], sections);
            }
        }
    }

    def save -> None {
        saved = {
            channel["feed_url"]: {
                "checked_at": channel["checked_at"],
                "headlines": channel["headlines"]
            }
            for channel in self.rss_channels()
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
        publishers = self.catalog.get("publishers", []);
        for channel in self.rss_channels() {
            mixed = channel in publishers;
            try {
                (body, _, base) = await fetcher(channel["feed_url"]);
                (_, items) = parse_feed(body, base);
                checked = datetime.now(UTC).isoformat();
                stories = latest_stories(
                    items, channel["headlines"], checked, base, 24 if mixed else 3
                );
                if stories {
                    if mixed {
                        self.router.assign_local(stories, self.sections());
                    }
                    channel.update({"checked_at": checked, "headlines": stories});
                    updated = True;
                }
            } except (ProviderError, OSError) as e {
                log.warning("Keeping saved headlines for %s: %s", channel["slug"], e);
            }
        }
        if updated {
            self.save();
        }
        # New articles and local assignments are durable before any hosted call.
        for publisher in publishers {
            if publisher.get("checked_at")
                and await self.router.review(publisher["headlines"], self.sections()) {
                self.save();
            }
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
