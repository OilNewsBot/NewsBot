"""Transactional storage and reads shared by every public channel type."""
import asyncio
import hashlib
import ipaddress
import re
import sqlite3
import uuid
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit, urlunsplit

from fastapi import HTTPException

from personal.coverage import item_section
from . import briefing as journal
from .topics import SECTORS, article_labels, categories, channel_topic

PROMPT_VERSION = "attributed-v1"


def now():
    return datetime.now(timezone.utc).isoformat()


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def field(body, key, maximum, required=True):
    value = body.get(key, "")
    if not isinstance(value, str) or len(value) > maximum or (required and not value.strip()):
        raise HTTPException(422, f"Enter a valid {key.replace('_', ' ')} (up to {maximum} characters)")
    return value.strip()


def public_url(value):
    if not value:
        return ""
    try:
        parsed = urlsplit(value)
        host = parsed.hostname or ""
        if (parsed.scheme not in ("https", "http") or not host or parsed.username is not None
                or parsed.password is not None or "\\" in value or re.search(r"[\x00-\x20]", value)
                or host.lower().rstrip(".") in ("localhost", "localhost.localdomain")
                or host.lower().endswith((".local", ".localhost", ".internal"))):
            raise ValueError
        try:
            address = ipaddress.ip_address(host.strip("[]"))
        except ValueError:
            address = None
        if address and not address.is_global:
            raise ValueError
        _ = parsed.port
        return urlunsplit((parsed.scheme, parsed.netloc.lower(), parsed.path, parsed.query, ""))
    except ValueError:
        raise HTTPException(422, "Use a public HTTP or HTTPS address") from None


def channel_address(kind, mode, value):
    if kind == "community":
        if value:
            raise HTTPException(422, "Community channels do not need a source address")
        return ""
    if kind == "rss":
        url = public_url(value)
        if not url or urlsplit(url).port not in (None, 80, 443):
            raise HTTPException(422, "Enter a public RSS or Atom feed address")
        secret_keys = {"access_token", "api_key", "apikey", "auth", "authorization", "key",
                       "password", "secret", "signature", "token", "x-amz-signature"}
        if any(k.lower() in secret_keys for k, _ in parse_qsl(urlsplit(url).query, keep_blank_values=True)):
            raise HTTPException(422, "Publish a public feed URL without credentials")
        return url
    if not value and mode == "api":
        return ""
    if kind == "telegram" and mode == "api":
        raise HTTPException(422, "Publish selected Telegram messages without a private chat address")
    if value.startswith("@"):
        value = ("https://x.com/" if kind == "x" else "https://t.me/") + value[1:]
    parsed = urlsplit(public_url(value))
    hosts = ("x.com", "www.x.com", "twitter.com", "www.twitter.com") if kind == "x" else ("t.me",)
    profile = parsed.path.strip("/")
    pattern = r"[A-Za-z0-9_]{1,15}" if kind == "x" else r"[A-Za-z][A-Za-z0-9_]{3,31}(?:/[1-9][0-9]{0,12})?"
    if (parsed.hostname not in hosts or parsed.query or parsed.port or not re.fullmatch(pattern, profile)
            or (kind == "telegram" and profile.split("/")[0].lower() in {"joinchat", "login", "proxy", "share", "addstickers"})):
        raise HTTPException(422, f"Enter a public {kind} profile address")
    return ("https://x.com/" if kind == "x" else "https://t.me/") + profile


class Catalog:
    def __init__(self, path, edition, model="", summary_sources="rss"):
        self.path = Path(path)
        self.edition = edition
        self.editorial_slugs = {}
        self.model = model
        self.ai_enabled = bool(model)
        self.summary_sources = frozenset(summary_sources.lower().replace(" ", "").split(",")) & {"rss", "x", "community"}
        self.ready = False

    async def run_db(self, work, *args, write=False):
        def run():
            with closing(sqlite3.connect(self.path, timeout=10)) as db:
                db.row_factory = sqlite3.Row
                db.execute("PRAGMA foreign_keys=ON")
                with db:
                    db.execute("BEGIN IMMEDIATE" if write else "BEGIN")
                    return work(db, *args)
        return await asyncio.to_thread(run)

    async def start(self):
        def initialize(db):
            db.executescript(Path(__file__).with_name("schema.sql").read_text(encoding="utf-8"))
            db.execute("BEGIN IMMEDIATE")
            db.execute("INSERT OR IGNORE INTO news_channel_tags SELECT slug,category FROM news_channels")
            missing = db.execute("""SELECT i.id FROM news_items i LEFT JOIN news_story_items m ON i.id=m.item_id
                WHERE m.item_id IS NULL ORDER BY i.collected_at,i.id""").fetchall()
            for item in missing:
                journal.record(db, item[0])
            seed = self.edition
            existing = self._seed_channels(seed)
            editorial_slugs = {}
            for category, entry, mixed in existing:
                # An older user channel can already own a newly introduced default's slug.
                slug = entry["slug"]
                suffix = 1
                while db.execute("SELECT 1 FROM news_channels WHERE slug=? AND owner_id IS NOT NULL", (slug,)).fetchone():
                    slug = f"{entry['slug']}-newsstream" + (f"-{suffix}" if suffix > 1 else "")
                    suffix += 1
                editorial_slugs[entry["slug"]] = slug
                kind = entry.get("source_type", "rss")
                address = entry["feed_url"] if kind == "rss" else entry["source_url"]
                source = self._source(db, kind, address, entry["publisher"], mixed)
                inserted = db.execute(
                    """INSERT OR IGNORE INTO news_channels
                    (slug,name,description,category,curator,source_id,source_url,mode,created_at)
                    VALUES(?,?,?,?,?,?,?,?,?)""",
                    (slug, entry["name"], entry["description"], category,
                     seed["curator"], source, address, entry.get("mode", kind), seed["captured_at"]))
                self._add_tags(db, slug, category, entry.get("tags", []))
                if inserted.rowcount:
                    for story in entry["headlines"]:
                        self._item(db, source, story["url"], story["url"], story["title"],
                                   story["summary"], entry["publisher"], story["published"],
                                   story.get("section", category), False, seed["captured_at"], notify=False)
                    if entry.get("checked_at"):
                        db.execute("UPDATE news_sources SET checked_at=? WHERE id=?",
                                   (entry["checked_at"], source))
            return editorial_slugs
        self.editorial_slugs = await self.run_db(initialize, write=True)
        self.ready = True

    @staticmethod
    def _add_tags(db, slug, primary, tags):
        db.executemany("INSERT OR IGNORE INTO news_channel_tags(slug,category) VALUES(?,?)",
                       [(slug, tag) for tag in [primary, *categories(tags)]])

    @staticmethod
    def _tags(db, slug, primary):
        return [primary, *(r[0] for r in db.execute(
            "SELECT category FROM news_channel_tags WHERE slug=? AND category<>? ORDER BY category", (slug, primary)))]

    @staticmethod
    def _seed_channels(seed):
        for category in seed["categories"]:
            for channel in category["channels"]:
                yield category["slug"], channel, False
        for publisher in seed.get("publishers", []):
            yield "general", publisher, True

    @staticmethod
    def _source(db, kind, locator, publisher, mixed=False):
        db.execute("""INSERT OR IGNORE INTO news_sources(kind,locator,publisher,mixed)
                    VALUES(?,?,?,?)""", (kind, locator, publisher, int(mixed)))
        return db.execute("SELECT id FROM news_sources WHERE kind=? AND locator=?",
                          (kind, locator)).fetchone()[0]

    @staticmethod
    def _item(db, source, external, url, title, body, author, published, section, eligible, collected,
              rss_alias=False, notify=True):
        stable = digest(external)
        # A seed snapshot can identify a story by its URL before its feed GUID is known.
        original = db.execute("SELECT id,title,body FROM news_items WHERE source_id=? AND external_id=?",
                              (source, stable)).fetchone()
        if not original and url and rss_alias:
            original = db.execute("SELECT id,title,body FROM news_items WHERE source_id=? AND url=? ORDER BY id LIMIT 1",
                                  (source, url)).fetchone()
        signature = digest("\n".join(" ".join(x.split()) for x in (title, body, author)))
        # A matching long headline on the same UTC day can group editions from multiple sources.
        normalized = " ".join(re.findall(r"\w+", title.casefold()))
        group = digest((published[:10] + " " + normalized) if len(normalized.split()) >= 6 else (url or stable))
        values = (stable, url, title, body, author, published, collected, section, signature, group, int(eligible))
        if original:
            db.execute("""UPDATE news_items SET external_id=?,url=?,title=?,body=?,author=?,
                       published=?,collected_at=?,section=?,revision=?,story_key=?,eligible=?
                       WHERE id=? AND (revision<>? OR published<>? OR url<>? OR eligible<>? OR section<>?)""",
                       (*values, original[0], signature, published, url, int(eligible), section))
            if original["title"] != title or original["body"] != body:
                journal.record(db, original[0])
            return original[0]
        item_id = db.execute("""INSERT INTO news_items(external_id,url,title,body,author,published,
                          collected_at,section,revision,story_key,eligible,source_id)
                          VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""", (*values, source)).lastrowid
        journal.record(db, item_id)
        if notify:
            Catalog._notify(db, source, item_id, title, body, section, published)
        return item_id

    @staticmethod
    def _notify(db, source, item_id, title, body, assigned, published):
        subscribers = db.execute("""SELECT a.user_id,a.slug,c.category,s.mixed FROM news_alert_settings a
            JOIN news_channels c ON c.slug=a.slug JOIN news_sources s ON s.id=c.source_id
            WHERE c.source_id=? AND (s.kind<>'rss' OR julianday(?) >= julianday(a.enabled_at))
            ORDER BY a.slug,a.user_id""", (source, published))
        topics = {}
        for uid, slug, category, mixed in subscribers:
            if slug not in topics:
                tags = Catalog._tags(db, slug, category)
                topics[slug] = channel_topic(title, body, assigned, category, tags, mixed)
            section, topic = topics[slug]
            selected = Catalog._categories(db, uid)
            if not selected or section in selected:
                db.execute("""INSERT OR IGNORE INTO news_alerts(user_id,slug,item_id,section,topic)
                    VALUES(?,?,?,?,?)""", (uid, slug, item_id, section, topic))

    @staticmethod
    def _by_slug(db, slug):
        row = db.execute("""SELECT c.*,s.kind AS source_type,s.publisher AS original_publisher
                         FROM news_channels c JOIN news_sources s ON s.id=c.source_id WHERE slug=?""",
                         (slug,)).fetchone()
        if not row:
            raise HTTPException(404, "Channel not found")
        return row

    def _stories(self, db, source, slug, category, tags, mixed, limit, kind, selected=(), item_id=None):
        if selected and not mixed and category != "general" and set(tags).isdisjoint(selected):
            return []
        rows = db.execute("""SELECT i.id,i.title,i.body AS text,i.url,i.author,i.published,i.collected_at,
                          i.section,i.story_key,m.story_id,i.eligible,k.summary AS ai,k.generated_at,k.attempts
                          FROM news_items i LEFT JOIN news_story_items m ON i.id=m.item_id
                          LEFT JOIN news_summaries k ON i.eligible=1 AND k.rowid=(
                              SELECT candidate.rowid FROM news_summaries candidate
                              WHERE candidate.revision=i.revision AND candidate.prompt_version=?
                              AND (candidate.model=? OR (? AND candidate.generated_at IS NOT NULL))
                              ORDER BY (candidate.generated_at IS NOT NULL AND candidate.model=?) DESC,
                                       candidate.generated_at DESC LIMIT 1)
                          WHERE i.source_id=? AND (? IS NULL OR i.id=?)
                          ORDER BY i.published DESC,i.id DESC LIMIT ?""",
                          (PROMPT_VERSION, self.model, not self.ai_enabled, self.model, source, item_id, item_id, -1 if selected else limit))
        stories = []
        for row in rows:
            section, topic = channel_topic(row["title"], row["text"], row["section"], category, tags, mixed)
            if selected and section not in selected:
                continue
            data = dict(row)
            generated = bool(data.pop("ai"))
            if generated:
                summary = row["ai"]
            else:
                summary = data["text"][:260].rstrip()
                if len(data["text"]) > 260:
                    summary += "…"
            tries = data.pop("attempts") or 0
            eligible = data.pop("eligible")
            data.update(summary=summary, ai_generated=generated, generated_at=data["generated_at"] or "",
                        labels=article_labels(row["title"], row["text"], section),
                        channel_slug=slug, source_type=kind, section=section, topic=topic,
                        status=("summarized" if generated else "retry" if tries else
                                "pending" if eligible and self.ai_enabled and kind in self.summary_sources else "source"))
            stories.append(data)
            if len(stories) >= limit:
                break
        return stories

    def _channels(self, db, uid, slug=None, following=False, limit=3, selected=(), item_id=None):
        sql = """SELECT c.*,s.kind AS source_type,s.publisher AS source_publisher,s.mixed,s.checked_at,s.failures,
               (SELECT COUNT(*) FROM news_subscriptions f WHERE f.slug=c.slug) AS subscribers,
               EXISTS(SELECT 1 FROM news_subscriptions f WHERE f.slug=c.slug AND f.user_id=?) AS subscribed,
               EXISTS(SELECT 1 FROM news_alert_settings a WHERE a.slug=c.slug AND a.user_id=?) AS notifications_enabled,
               (SELECT COUNT(*) FROM news_votes r WHERE r.slug=c.slug) AS recommendations,
               EXISTS(SELECT 1 FROM news_votes r WHERE r.slug=c.slug AND r.user_id=?) AS recommended
               FROM news_channels c JOIN news_sources s ON s.id=c.source_id """
        args = [uid, uid, uid]
        if slug is not None:
            sql += " WHERE c.slug=?"
            args.append(slug)
        elif following:
            sql += " WHERE EXISTS(SELECT 1 FROM news_subscriptions f WHERE f.slug=c.slug AND f.user_id=?)"
            args.append(uid)
        channels = []
        for row in db.execute(sql + " ORDER BY c.name COLLATE NOCASE,c.slug", args):
            public = dict(row)
            is_mixed = public.pop("mixed")
            failures = public.pop("failures")
            public["refresh_status"] = ("retrying" if failures else "current" if row["checked_at"] else
                                        "pending" if row["source_type"] == "rss" else "manual")
            public.update(owned=public.pop("owner_id") == uid and uid is not None,
                          tags=self._tags(db, row["slug"], row["category"]),
                          notifications_enabled=bool(public["notifications_enabled"]),
                          subscribed=bool(public["subscribed"]), recommended=bool(public["recommended"]),
                          publisher=public["curator"] if row["owner_id"] else public["source_publisher"],
                          checked_at=public["checked_at"] or "")
            source = public.pop("source_id")
            public["headlines"] = self._stories(db, source, row["slug"], row["category"], public["tags"],
                                                is_mixed, max(24, limit) if is_mixed else limit,
                                                row["source_type"], selected)
            if item_id is not None and all(item["id"] != item_id for item in public["headlines"]):
                public["headlines"].extend(self._stories(db, source, row["slug"], row["category"], public["tags"],
                                                        is_mixed, 1, row["source_type"], item_id=item_id))
            channels.append(public)
        return channels

    async def channels(self, uid=None):
        return await self.run_db(self._channels, uid)

    async def editorial_view(self):
        """Preserve the original directory contract while reading current public editions."""
        rows = {c["slug"]: c for c in await self.channels()}
        def edition(entry, mixed=False):
            channel = rows[self.editorial_slugs.get(entry["slug"], entry["slug"])]
            headlines = []
            original = {h["url"]: h for h in entry["headlines"]}
            for story in channel["headlines"][:24 if mixed else 3]:
                head = {k: story[k] for k in ("title", "url", "summary", "published", "section", "topic",
                                              "labels", "story_id")}
                if mixed:
                    head.update(section=story["section"], routed_by=original.get(story["url"], {}).get("routed_by", "local"))
                headlines.append(head)
            result = {**entry, "slug": channel["slug"], "headlines": headlines, "tags": channel["tags"]}
            if channel["checked_at"]:
                result["checked_at"] = channel["checked_at"]
            return result
        publishers = [edition(entry, True) for entry in self.edition.get("publishers", [])]
        categories = []
        for sector in self.edition["categories"]:
            channels = [edition(entry) for entry in sector["channels"]]
            for publisher in publishers:
                matching = [h for h in publisher["headlines"] if h["section"] == sector["slug"]]
                if matching:
                    channels.append({**publisher, "headlines": matching[:3]})
            categories.append({**sector, "channels": channels})
        return {**self.edition, "categories": categories, "publishers": publishers}

    async def detail(self, slug, uid=None, item_id=None):
        def read(db):
            rows = self._channels(db, uid, slug=slug, limit=100, item_id=item_id)
            if not rows:
                raise HTTPException(404, "Channel not found")
            comments = db.execute("""SELECT id,item_id,parent_id,author,text,created_at FROM news_comments
                                  WHERE slug=? ORDER BY id""", (slug,))
            return {"channel": rows[0], "comments": [dict(c) for c in comments]}
        return await self.run_db(read)

    async def following(self, uid):
        def read(db):
            selected = self._categories(db, uid)
            channels = self._channels(db, uid, following=True, limit=50, selected=selected)
            groups = {}
            for channel in channels:
                for item in channel["headlines"]:
                    key = item["story_id"] or item["story_key"]
                    group = groups.setdefault(key, {**item, "sources": []})
                    if item["published"] > group["published"]:
                        group.update(item)
                    ref = {"channel_slug": channel["slug"], "name": channel["name"], "url": item["url"], "item_id": item["id"]}
                    if ref not in group["sources"]:
                        group["sources"].append(ref)
            return {"channels": channels, "categories": selected, "items": sorted(groups.values(),
                    key=lambda i: (i["published"], i["id"]), reverse=True)[:200]}
        return await self.run_db(read)

    @staticmethod
    def _categories(db, uid):
        return [r[0] for r in db.execute("SELECT category FROM news_feed_categories WHERE user_id=? ORDER BY category",
                                        (uid,))]

    async def feed_preferences(self, uid):
        return {"categories": await self.run_db(self._categories, uid)}

    async def briefing(self, uid):
        return await self.run_db(journal.read_briefing, uid, write=True)

    async def acknowledge_briefing(self, uid, through, additional=None):
        return await self.run_db(journal.acknowledge, uid, through, additional, write=True)

    async def story(self, story_id, uid=None):
        return await self.run_db(journal.read_story, story_id, uid)

    async def watches(self, uid):
        return await self.run_db(journal.watches, uid)

    async def follow_story(self, uid, story_id, enabled):
        return await self.run_db(journal.follow_story, uid, story_id, enabled, write=True)

    async def follow_topic(self, uid, topic_id, enabled):
        return await self.run_db(journal.follow_topic, uid, topic_id, enabled, write=True)

    async def set_preferences(self, uid, value):
        selected = categories(value)
        def update(db):
            db.execute("DELETE FROM news_feed_categories WHERE user_id=?", (uid,))
            db.executemany("INSERT INTO news_feed_categories(user_id,category) VALUES(?,?)",
                           [(uid, sector) for sector in selected])
            if selected:
                db.execute("""DELETE FROM news_alerts WHERE user_id=? AND section NOT IN
                    (SELECT category FROM news_feed_categories WHERE user_id=?)""", (uid, uid))
                if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='personal_source_tags'").fetchone():
                    db.create_function("item_section", 3, item_section, deterministic=True)
                    db.execute("""DELETE FROM personal_notifications WHERE user_id=? AND item_id IN (
                        SELECT i.id FROM personal_notifications n
                        JOIN personal_items i ON n.item_id=i.id AND n.user_id=i.user_id
                        LEFT JOIN personal_source_tags t ON t.source_id=i.source_id
                        WHERE n.user_id=? AND item_section(i.title,i.text,t.tags) NOT IN
                            (SELECT category FROM news_feed_categories WHERE user_id=?))""", (uid, uid, uid))
            return {"categories": self._categories(db, uid)}
        return await self.run_db(update, write=True)

    async def notification_head(self, uid):
        return await self.run_db(lambda db: {"user_id": uid, "head": db.execute(
            "SELECT COALESCE(MAX(id),0) FROM news_alerts WHERE user_id=?", (uid,)).fetchone()[0]})

    async def notifications(self, uid, since):
        def read(db):
            rows = [dict(r) for r in db.execute("""SELECT a.id,a.item_id,i.title,i.url,a.section,a.topic,
                a.slug AS channel_slug,c.name AS channel_name FROM news_alerts a
                JOIN news_channels c ON c.slug=a.slug JOIN news_items i ON i.id=a.item_id
                WHERE a.user_id=? AND a.id>? ORDER BY a.id LIMIT 100""", (uid, since))]
            return {"user_id": uid, "head": rows[-1]["id"] if rows else since, "notifications": rows}
        return await self.run_db(read)

    async def create(self, uid, username, body):
        name = field(body, "name", 100)
        description = field(body, "description", 1000)
        kind = field(body, "source_type", 16)
        category = field(body, "category", 24).lower()
        if category not in SECTORS or kind not in ("rss", "community", "x", "telegram"):
            raise HTTPException(422, "Choose a supported category and source type")
        tags = categories(body.get("tags", []))
        default_mode = "embed" if kind in ("x", "telegram") else kind
        mode = body.get("mode") or default_mode
        allowed_modes = ("embed", "api") if kind in ("x", "telegram") else (kind,)
        if mode not in allowed_modes:
            raise HTTPException(422, "Unsupported channel mode")
        url = channel_address(kind, mode, field(body, "source_url", 2048, False))
        def insert(db):
            if db.execute("SELECT COUNT(*) FROM news_channels WHERE owner_id=?", (uid,)).fetchone()[0] >= 100:
                raise HTTPException(429, "Your channel limit has been reached")
            base = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:60] or "channel"
            slug = base
            while db.execute("SELECT 1 FROM news_channels WHERE slug=?", (slug,)).fetchone():
                slug = base + "-" + uuid.uuid4().hex[:8]
            # Only public RSS editions share an ingestion identity. Each curated inbox
            # publishes into a separate channel even when two creators use the same provider.
            locator = url if kind == "rss" else slug
            publisher = urlsplit(url).hostname if kind == "rss" else username
            source = self._source(db, kind, locator, publisher)
            db.execute("""INSERT INTO news_channels(slug,name,description,category,owner_id,curator,
                       source_id,source_url,mode,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)""",
                       (slug, name, description, category, uid, username, source, url, mode, now()))
            self._add_tags(db, slug, category, tags)
            return self._channels(db, uid, slug)[0]
        return await self.run_db(insert, write=True)

    async def click(self, slug):
        def count(db):
            self._by_slug(db, slug)
            db.execute("UPDATE news_channels SET clicks=clicks+1 WHERE slug=?", (slug,))
            return db.execute("SELECT clicks FROM news_channels WHERE slug=?", (slug,)).fetchone()[0]
        return await self.run_db(count, write=True)

    async def toggle(self, slug, uid, key, enabled):
        if key == "notifications":
            def alert(db):
                self._by_slug(db, slug)
                if not db.execute("SELECT 1 FROM news_subscriptions WHERE user_id=? AND slug=?", (uid, slug)).fetchone():
                    raise HTTPException(409, "Follow this channel to manage its notifications")
                if enabled:
                    db.execute("INSERT OR IGNORE INTO news_alert_settings(user_id,slug,enabled_at) VALUES(?,?,?)",
                               (uid, slug, now()))
                else:
                    db.execute("DELETE FROM news_alert_settings WHERE user_id=? AND slug=?", (uid, slug))
                return self._channels(db, uid, slug, limit=100)[0]
            return await self.run_db(alert, write=True)
        table = {"subscription": "news_subscriptions", "recommendation": "news_votes"}[key]
        def change(db):
            self._by_slug(db, slug)
            if enabled:
                db.execute(f"INSERT OR IGNORE INTO {table}(user_id,slug) VALUES(?,?)", (uid, slug))
            else:
                db.execute(f"DELETE FROM {table} WHERE user_id=? AND slug=?", (uid, slug))
            return self._channels(db, uid, slug, limit=100)[0]
        return await self.run_db(change, write=True)

    async def comment(self, slug, uid, author, body):
        text = field(body, "text", 4000)
        item_id, parent = body.get("item_id"), body.get("parent_id")
        for val in (item_id, parent):
            if val is not None and (type(val) is not int or not 0 < val < 2**63):
                raise HTTPException(422, "Invalid thread identifier")
        def insert(db):
            channel = self._by_slug(db, slug)
            if item_id is not None and not db.execute(
                    "SELECT 1 FROM news_items WHERE id=? AND source_id=?", (item_id, channel["source_id"])).fetchone():
                raise HTTPException(404, "Story not found in this channel")
            if parent is not None and not db.execute(
                    "SELECT 1 FROM news_comments WHERE id=? AND slug=? AND item_id IS ?", (parent, slug, item_id)).fetchone():
                raise HTTPException(404, "Parent comment not found in this thread")
            created = now()
            cid = db.execute("""INSERT INTO news_comments(slug,item_id,parent_id,user_id,author,text,created_at)
                             VALUES(?,?,?,?,?,?,?)""", (slug, item_id, parent, uid, author, text, created)).lastrowid
            return dict(id=cid, item_id=item_id, parent_id=parent, text=text, author=author, created_at=created)
        return await self.run_db(insert, write=True)

    async def post(self, slug, uid, author, body):
        title = field(body, "title", 300)
        text = field(body, "text", 12000, False)
        url = public_url(field(body, "url", 2048, False))
        if not text and not url:
            raise HTTPException(422, "Provide a description or a source link")
        return await self._publish(slug, uid, author, title, text, url, uuid.uuid4().hex, now(), None)

    async def publish_selected(self, slug, user_id, author, title, text, url, external_id, published, source_type):
        if source_type not in ("x", "telegram") or not external_id:
            raise HTTPException(422, "Invalid provider selection")
        return await self._publish(slug, user_id, str(author)[:200], str(title)[:300], str(text)[:12000],
                                   public_url(url or ""), external_id, published or now(), source_type)

    async def _publish(self, slug, uid, author, title, body, url, external, published, source_type):
        def insert(db):
            c = self._by_slug(db, slug)
            if source_type:
                if c["owner_id"] != uid or c["mode"] != "api" or c["source_type"] != source_type:
                    raise HTTPException(403, "Select your own matching API channel")
                if source_type == "x" and c["source_url"]:
                    handle = urlsplit(c["source_url"]).path.strip("/").casefold()
                    u = urlsplit(url)
                    if u.hostname not in ("x.com", "twitter.com", "www.x.com", "www.twitter.com") or not re.fullmatch(
                            "/" + re.escape(handle) + r"/status/\d+/?", u.path.casefold()):
                        raise HTTPException(422, "The selected post must belong to this channel's account")
            elif c["source_type"] != "community" and (c["source_type"] not in ("x", "telegram") or c["owner_id"] != uid):
                raise HTTPException(403, "Post in a community or your own social channel")
            # A manual link post on an embedded social channel has no authorized post body.
            eligible = (source_type == "x" or c["source_type"] == "community") and bool(body.strip())
            return_id = self._item(db, c["source_id"], external, url, title, body, author, published,
                                   c["category"], eligible, now())
            return self._stories_one(db, return_id, slug, c["category"], c["source_type"])
        return await self.run_db(insert, write=True)

    @staticmethod
    def _stories_one(db, iid, slug, category, kind):
        item = dict(db.execute("""SELECT i.id,i.url,i.title,i.body AS text,i.author,i.published,i.collected_at,i.story_key,m.story_id
                               FROM news_items i LEFT JOIN news_story_items m ON m.item_id=i.id WHERE i.id=?""", (iid,)).fetchone())
        section, topic = channel_topic(item["title"], item["text"], "", category, Catalog._tags(db, slug, category), False)
        return {**item, "channel_slug": slug, "source_type": kind, "section": section, "topic": topic,
                "labels": article_labels(item["title"], item["text"], section), "summary": item["text"][:260],
                "ai_generated": False, "generated_at": "", "status": "source"}
