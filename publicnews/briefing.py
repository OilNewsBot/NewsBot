"""A public story journal. Every development points to a persisted source item."""
import json
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from fastapi import HTTPException

from . import topics
from .storytext import changed_excerpt, compact, meaningful_change, words


def _url_key(url):
    if not url:
        return ""
    parts = urlsplit(url)
    query = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True)
             if not k.lower().startswith("utm_") and k.lower() not in ("fbclid", "gclid")]
    return urlunsplit((parts.scheme.lower(), parts.netloc.lower(), parts.path or "/", urlencode(query), ""))


def _channel(db, source_id, uid=None):
    return db.execute("""SELECT c.slug,c.name,c.category,s.publisher,s.kind,s.mixed FROM news_channels c
        JOIN news_sources s ON c.source_id=s.id WHERE c.source_id=?
        ORDER BY EXISTS(SELECT 1 FROM news_subscriptions f WHERE f.slug=c.slug AND f.user_id=?) DESC,
        (c.owner_id IS NULL) DESC,c.created_at,c.slug LIMIT 1""", (source_id, uid)).fetchone()


_STOP = set("the a an by after with says said about over for and under as its from will this into their new to of on in at".split())


def _label_ids(labels):
    return {v["id"] for values in labels.values() for v in values}


def _related(db, item, url_key, title_key, labels):
    if url_key:
        same = db.execute("SELECT story_id FROM news_story_items WHERE url_key=? ORDER BY item_id LIMIT 1",
                          (url_key,)).fetchone()
        if same:
            return same[0]
    tokens = set(title_key.split()) - _STOP
    if len(tokens) < 4:
        return None
    try:
        observed = datetime.fromisoformat(item["published"].replace("Z", "+00:00"))
        day = observed.date()
    except ValueError:
        return None
    bounds = ((day - timedelta(days=2)).isoformat(), (day + timedelta(days=3)).isoformat())
    if len(title_key.split()) >= 6:
        exact = db.execute("""SELECT m.story_id FROM news_story_items m JOIN news_items i ON i.id=m.item_id
            WHERE m.title_key=? AND i.published>=? AND i.published<? ORDER BY i.id LIMIT 1""",
                           (title_key, day.isoformat(), (day + timedelta(days=1)).isoformat())).fetchone()
        if exact:
            return exact[0]
    # A broad sector match is never evidence of a common incident. Require a
    # shared named entity, an event or place, and substantial headline overlap.
    anchor = {v["id"] for v in labels["entities"]}
    context = {v["id"] for v in labels["events"] + labels["places"]}
    if not anchor or not context:
        return None
    scores = {}
    nearby = db.execute("""SELECT m.story_id,m.title_key,m.labels FROM news_items i
        JOIN news_story_items m ON m.item_id=i.id WHERE i.published>=? AND i.published<?
        ORDER BY i.published DESC,i.id DESC LIMIT 400""", bounds)
    for candidate in nearby:
        words = set(candidate["title_key"].split()) - _STOP
        common = tokens & words
        score = len(common) / len(tokens | words)
        if len(common) < 4 or score < 0.48:
            continue
        ids = _label_ids(json.loads(candidate["labels"]))
        if anchor & ids and context & ids:
            sid = candidate["story_id"]
            scores[sid] = max(scores.get(sid, 0), score)
    ranked = sorted(scores, key=scores.get, reverse=True)
    if ranked and (len(ranked) == 1 or scores[ranked[0]] - scores[ranked[1]] >= 0.10):
        return ranked[0]
    return None


def record(db, item_id):
    item = db.execute("SELECT * FROM news_items WHERE id=?", (item_id,)).fetchone()
    channel = _channel(db, item["source_id"])
    if not channel:
        return
    tags = [r[0] for r in db.execute("SELECT category FROM news_channel_tags WHERE slug=?", (channel["slug"],))]
    section, topic = topics.channel_topic(item["title"], item["body"], item["section"], channel["category"],
                                         tags, channel["mixed"])
    labels = topics.article_labels(item["title"], item["body"], section)
    stored_labels = json.dumps(labels, ensure_ascii=False, separators=(",", ":"))
    url_key = _url_key(item["url"])
    title_key = " ".join(words(item["title"]))
    publisher_key = ((urlsplit(item["url"]).hostname or "").lower().removeprefix("www.")
                     if item["url"] else "") or f"source:{item['source_id']}"
    member = db.execute("SELECT story_id FROM news_story_items WHERE item_id=?", (item_id,)).fetchone()
    if member:
        sid = member[0]
        previous = db.execute("""SELECT title,body FROM news_developments WHERE story_id=? AND item_id=?
            ORDER BY id DESC LIMIT 1""", (sid, item_id)).fetchone()
        if not previous and url_key:
            previous = db.execute("""SELECT d.title,d.body FROM news_developments d JOIN news_story_items m
                ON m.item_id=d.item_id WHERE d.story_id=? AND m.url_key=? ORDER BY d.id DESC LIMIT 1""",
                                  (sid, url_key)).fetchone()
        kind = "updated"
    else:
        sid = _related(db, item, url_key, title_key, labels)
        previous = None
        if sid is None:
            sid = db.execute("INSERT INTO news_stories DEFAULT VALUES").lastrowid
            kind = "reported"
        else:
            prior = db.execute("""SELECT url_key,publisher_key FROM news_story_items WHERE story_id=?""", (sid,)).fetchall()
            if url_key and any(r["url_key"] == url_key for r in prior):
                kind = None
            elif any(r["publisher_key"] == publisher_key for r in prior):
                # Republishing the same headline on the same publisher's site
                # should add a citation without claiming independent coverage.
                previous = db.execute("""SELECT d.title,d.body FROM news_developments d
                    JOIN news_story_items m ON m.item_id=d.item_id WHERE d.story_id=? AND m.publisher_key=?
                    ORDER BY d.id DESC LIMIT 1""", (sid, publisher_key)).fetchone()
                kind = "updated"
            else:
                kind = "additional_source"
    db.execute("""INSERT INTO news_story_items(item_id,story_id,url_key,title_key,publisher_key,labels)
        VALUES(?,?,?,?,?,?) ON CONFLICT(item_id) DO UPDATE SET url_key=excluded.url_key,
        title_key=excluded.title_key,publisher_key=excluded.publisher_key,labels=excluded.labels""",
               (item_id, sid, url_key, title_key, publisher_key, stored_labels))
    if not kind or (previous and not meaningful_change(previous["title"], previous["body"], item["title"], item["body"])):
        return
    db.execute("""INSERT INTO news_developments(story_id,item_id,kind,title,body,url,author,published,
        observed_at,section,topic,labels) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
               (sid, item_id, kind, item["title"], item["body"], item["url"], item["author"],
                item["published"], item["collected_at"], section, topic, stored_labels))


def watch_label(value):
    if not isinstance(value, str) or len(value) > 300:
        raise HTTPException(422, "Choose a valid topic")
    parts = value.split("~")
    if len(parts) > 4 or len(set(parts)) != len(parts):
        raise HTTPException(422, "Choose up to four different labels for a topic")
    ids = sorted(topics.watch_ids(parts))
    entries = [t for group in topics.taxonomy() for t in group["topics"]]
    entries.extend(t for group in topics.facets().values() for t in group)
    names = {entry["id"]: entry["label"] for entry in entries}
    return {"id": "~".join(ids), "label": " + ".join(names[key] for key in ids)}


def _enabled(value):
    if type(value) is not bool:
        raise HTTPException(422, "Set enabled to true or false")


def follow_topic(db, uid, topic_id, enabled):
    _enabled(enabled)
    watch = watch_label(topic_id)
    if enabled:
        db.execute("INSERT OR IGNORE INTO news_topic_follows(user_id,topic_id) VALUES(?,?)", (uid, watch["id"]))
    else:
        db.execute("DELETE FROM news_topic_follows WHERE user_id=? AND topic_id=?", (uid, watch["id"]))
    return {**watch, "enabled": enabled}


def follow_story(db, uid, story_id, enabled):
    _enabled(enabled)
    if not db.execute("SELECT 1 FROM news_stories WHERE id=?", (story_id,)).fetchone():
        raise HTTPException(404, "Story not found")
    if enabled:
        db.execute("INSERT OR IGNORE INTO news_story_follows(user_id,story_id) VALUES(?,?)", (uid, story_id))
    else:
        db.execute("DELETE FROM news_story_follows WHERE user_id=? AND story_id=?", (uid, story_id))
    return {"id": story_id, "enabled": enabled}


def watches(db, uid):
    followed = db.execute("""SELECT f.story_id AS id,(SELECT d.title FROM news_developments d
        WHERE d.story_id=f.story_id ORDER BY d.id DESC LIMIT 1) AS title
        FROM news_story_follows f WHERE f.user_id=? ORDER BY title,f.story_id""", (uid,))
    saved = db.execute("SELECT topic_id FROM news_topic_follows WHERE user_id=? ORDER BY topic_id", (uid,))
    return {"stories": [dict(row) for row in followed], "topics": [watch_label(row[0]) for row in saved]}


_CHANGES = {"reported": "New story", "updated": "Publisher update", "additional_source": "Additional source"}


def read_story(db, story_id, uid=None, through=None, include_timeline=True):
    rows = db.execute("""SELECT d.*,i.source_id,m.publisher_key FROM news_developments d
        JOIN news_items i ON i.id=d.item_id JOIN news_story_items m ON m.item_id=i.id
        WHERE d.story_id=? AND (? IS NULL OR d.id<=?) ORDER BY d.id""", (story_id, through, through))
    timeline = []
    citations = {}
    publishers = set()
    previous = {}
    channels = {}
    for row in rows:
        source_id = row["source_id"]
        if source_id not in channels:
            channels[source_id] = _channel(db, source_id, uid)
        channel = channels[source_id]
        source = {"item_id": row["item_id"], "url": row["url"], "name": channel["name"],
                  "channel_slug": channel["slug"], "publisher": channel["publisher"],
                  "published": row["published"]}
        citations[_url_key(row["url"]) or ("item", row["item_id"])] = source
        publishers.add(row["publisher_key"])
        event = {key: row[key] for key in ("id", "story_id", "kind", "title", "section", "topic", "observed_at")}
        event.update(source, summary=compact(row["body"]), labels=json.loads(row["labels"]),
                     delta=changed_excerpt(previous.get(row["item_id"]), row["title"], row["body"]),
                     source_type=channel["kind"], change=_CHANGES[row["kind"]])
        previous[row["item_id"]] = row["body"]
        timeline.append(event)
    if not timeline:
        raise HTTPException(404, "Story not found")
    latest = timeline[-1]
    followed = bool(db.execute("SELECT 1 FROM news_story_follows WHERE user_id=? AND story_id=?",
                               (uid, story_id)).fetchone())
    return {**latest, "id": story_id, "development_id": latest["id"], "updated_at": latest["observed_at"],
            "channel_name": latest["name"], "sources": list(citations.values()), "source_count": len(publishers),
            "development_count": len(timeline), **({"developments": timeline[::-1]} if include_timeline else {}),
            "followed": followed, "ai_generated": False}


def read_briefing(db, uid):
    visit = db.execute("SELECT checkpoint,visited_at FROM news_brief_visits WHERE user_id=?", (uid,)).fetchone()
    first = not visit or visit["checkpoint"] is None
    checkpoint = 0 if first else visit["checkpoint"]
    latest = db.execute("SELECT COALESCE(MAX(id),0) FROM news_developments").fetchone()[0]
    saved = watches(db, uid)
    stories = {row["id"] for row in saved["stories"]}
    watched = [(set(w["id"].split("~")), w["label"]) for w in saved["topics"]]
    selected = {r[0] for r in db.execute("SELECT category FROM news_feed_categories WHERE user_id=?", (uid,))}
    subscriptions = {r[0]: r[1] for r in db.execute("""SELECT c.source_id,c.name FROM news_subscriptions f
        JOIN news_channels c ON f.slug=c.slug WHERE f.user_id=? ORDER BY c.slug""", (uid,))}
    fallback = not (saved["topics"] or stories or subscriptions)
    if fallback and db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='personal_sources'").fetchone():
        fallback = not db.execute("""SELECT 1 FROM personal_sources s JOIN personal_connections c
            ON c.id=s.connection_id AND c.user_id=s.user_id WHERE s.user_id=? AND s.enabled=1
            AND s.deleted_at IS NULL AND c.deleted_at IS NULL AND c.status<>'disconnected' LIMIT 1""", (uid,)).fetchone()
    followed_sources = {}
    for source_id, name in subscriptions.items():
        for r in db.execute("""SELECT DISTINCT m.story_id FROM news_items i JOIN news_story_items m ON i.id=m.item_id
                                WHERE i.source_id=?""", (source_id,)):
            followed_sources[r[0]] = name
    sort = "d.observed_at DESC,d.published DESC,d.id DESC" if first else "d.id"
    candidates = db.execute(f"""SELECT d.id,d.story_id,d.section,d.labels,
        EXISTS(SELECT 1 FROM news_channels c WHERE c.source_id=i.source_id AND c.owner_id IS NULL) AS editorial
        FROM news_developments d JOIN news_items i ON d.item_id=i.id WHERE d.id>? ORDER BY {sort}""", (checkpoint,))
    chosen = {}
    matched = 0
    through = latest
    has_more = False
    for r in candidates:
        sid = r["story_id"]
        if sid in stories:
            reason = "You follow this story"
        else:
            evidence = _label_ids(json.loads(r["labels"])) if watched else set()
            topic = next((name for required, name in watched if required <= evidence), "")
            if topic:
                reason = "You follow " + topic
            elif selected and r["section"] not in selected:
                continue
            elif sid in followed_sources:
                reason = "You follow " + followed_sources[sid]
            elif fallback and r["editorial"]:
                reason = "From the public directory"
            else:
                continue
        if first and sid in chosen:
            continue
        if not first and matched >= 100:
            has_more = True
            break
        chosen[sid] = (r["id"], reason)
        matched += 1
        if first and len(chosen) == 12:
            break
        if not first:
            through = r["id"]
    if not has_more:
        through = latest
    cards = []
    for sid, (development, reason) in chosen.items():
        card = read_story(db, sid, uid, development, include_timeline=False)
        card["reason"] = reason
        cards.append(card)
    cards.sort(key=lambda c: (c["updated_at"], c["published"], c["development_id"]), reverse=True)
    if uid is not None:
        offered_at = datetime.now(timezone.utc).isoformat()
        db.execute("""INSERT INTO news_brief_visits(user_id,offered,offered_at) VALUES(?,?,?) ON CONFLICT(user_id)
            DO UPDATE SET offered=max(offered,excluded.offered),offered_at=excluded.offered_at""", (uid, through, offered_at))
    return {"user_id": uid, "first_visit": first, "through": through, "since": visit["visited_at"] if visit else None,
            "has_more": has_more, "cards": cards}


def acknowledge(db, uid, through, additional=None):
    visit = db.execute("SELECT * FROM news_brief_visits WHERE user_id=?", (uid,)).fetchone()
    if type(through) is not int or through < 0 or not visit or through > visit["offered"]:
        raise HTTPException(422, "Acknowledge the briefing that was displayed")
    if visit["checkpoint"] is None or through >= visit["checkpoint"]:
        visited_at = visit["offered_at"]
        db.execute("UPDATE news_brief_visits SET checkpoint=?,visited_at=? WHERE user_id=?", (through, visited_at, uid))
    else:
        through, visited_at = visit["checkpoint"], visit["visited_at"]
    if additional is not None:
        additional(db, uid)
    return {"checkpoint": through, "through": through, "visited_at": visited_at}
