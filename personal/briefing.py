"""Owner-only developments from private RSS and authorized account sources."""
from fastapi import HTTPException

from personal.coverage import item_topic
from publicnews.storytext import changed_excerpt, compact
from publicnews.topics import article_labels


# Visibility is checked for every read, even for a previously followed item.
_ROWS = """
    SELECT d.*, i.posted_at,
           (SELECT prev.body FROM personal_developments prev
            WHERE prev.item_id=d.item_id AND prev.id<d.id ORDER BY prev.id DESC LIMIT 1) AS prior_body,
           s.name, s.enabled, t.tags, c.provider,
           EXISTS (SELECT 1 FROM personal_story_watches w
                   WHERE w.item_id=i.id AND w.user_id=i.user_id) AS followed
    FROM personal_developments d
    JOIN personal_items i ON i.id=d.item_id AND i.user_id=d.user_id
    JOIN personal_sources s ON s.id=i.source_id AND s.user_id=i.user_id
    JOIN personal_connections c ON c.id=s.connection_id AND c.user_id=i.user_id
    LEFT JOIN personal_source_tags t ON t.source_id=s.id
    WHERE d.user_id=? AND s.deleted_at IS NULL AND c.deleted_at IS NULL
"""


def _labels(row):
    section, topic = item_topic(row["title"], row["body"], row["tags"])
    return section, topic, article_labels(row["title"], row["body"], section)


def _card(row, reason, classification):
    section, topic, labels = classification
    story_id = f"private-{row['item_id']}"
    return {"id": story_id, "story_id": story_id, "title": row["title"], "summary": compact(row["body"]),
            "delta": changed_excerpt(row["prior_body"] or "", row["title"], row["body"]),
            "change": "Source updated its report" if row["kind"] == "updated" else "New report",
            "updated_at": row["observed_at"], "published": row["posted_at"], "url": row["url"],
            "channel_name": row["name"], "channel_slug": "", "source_type": row["provider"],
            "private_source": True, "development_id": row["id"], "followed": bool(row["followed"]), "reason": reason,
            "section": section, "topic": topic, "labels": labels, "source_count": 1,
            "sources": [{"item_id": story_id, "name": row["name"], "publisher": row["name"],
                         "url": row["url"], "published": row["posted_at"]}], "ai_generated": False}


def previous_card(db, uid, development, reason):
    row = db.execute(_ROWS + " AND d.id=?", (uid, development)).fetchone()
    return _card(row, reason, _labels(row)) if row is not None else None


def _development(row):
    return {"id": row["id"], "kind": row["kind"], "change": "Publisher update" if row["kind"] == "updated" else "New report",
            "title": row["title"], "summary": compact(row["body"]),
            "delta": changed_excerpt(row["prior_body"] or "", row["title"], row["body"]),
            "publisher": row["name"], "url": row["url"], "published": row["posted_at"],
            "observed_at": row["observed_at"]}


def story(db, uid, item_id):
    rows = db.execute(_ROWS + " AND d.item_id=? ORDER BY d.id DESC", (uid, item_id))
    latest = rows.fetchone()
    if latest is None:
        raise HTTPException(404, "Story not found")
    card = _card(latest, "From your private source", _labels(latest))
    card["developments"] = [_development(latest), *(_development(row) for row in rows)]
    return card


def watch(db, uid, item_id, enabled):
    if not db.execute(_ROWS + " AND d.item_id=? LIMIT 1", (uid, item_id)).fetchone():
        raise HTTPException(404, "Story not found")
    if enabled:
        db.execute("INSERT OR IGNORE INTO personal_story_watches(user_id,item_id) VALUES (?,?)", (uid, item_id))
    else:
        db.execute("DELETE FROM personal_story_watches WHERE user_id=? AND item_id=?", (uid, item_id))
    return {"enabled": enabled}


def watches(db, uid):
    rows = db.execute("""SELECT i.id,i.title FROM personal_story_watches w
        JOIN personal_items i ON i.id=w.item_id AND i.user_id=w.user_id
        JOIN personal_sources s ON s.id=i.source_id AND s.user_id=w.user_id
        JOIN personal_connections c ON c.id=s.connection_id AND c.user_id=w.user_id
        WHERE w.user_id=? AND s.deleted_at IS NULL AND c.deleted_at IS NULL ORDER BY i.title""", (uid,))
    return [{"id": f"private-{row['id']}", "title": row["title"], "private_source": True} for row in rows]


def edition(db, uid, first_visit, topics):
    visit = db.execute("SELECT seen FROM personal_briefing_visits WHERE user_id=?", (uid,)).fetchone()
    since = visit["seen"] if visit else 0
    head = db.execute("SELECT COALESCE(MAX(id),0) FROM personal_developments WHERE user_id=?", (uid,)).fetchone()[0]
    selected = {r[0] for r in db.execute("SELECT category FROM news_feed_categories WHERE user_id=?", (uid,))}
    rules = [(set(t["id"].split("~")), t["label"]) for t in topics]
    order = "DESC" if first_visit else "ASC"
    rows = db.execute(_ROWS + f" AND s.enabled=1 AND d.id>? AND d.id<=? ORDER BY d.id {order}", (uid, since, head))
    cards = {}
    through = head
    has_more = False
    for row in rows:
        classification = _labels(row)
        section, _, labels = classification
        ids = {t["id"] for group in labels.values() for t in group}
        matched = next((label for required, label in rules if required <= ids), "")
        if selected and section not in selected and not row["followed"] and not matched:
            continue
        key = row["item_id"]
        if first_visit and key in cards:
            continue
        if key not in cards and len(cards) >= (12 if first_visit else 25):
            if not first_visit:
                through = row["id"] - 1
                has_more = True
            break
        reason = ("You follow this story" if row["followed"] else
                  f"Matches your topic: {matched}" if matched else f"From your private source {row['name']}")
        cards[key] = _card(row, reason, classification)
    db.execute("""INSERT INTO personal_briefing_visits(user_id,offered) VALUES (?,?)
        ON CONFLICT(user_id) DO UPDATE SET offered=MAX(offered,excluded.offered)""", (uid, through))
    return list(cards.values()), through, has_more


def acknowledge(db, uid, through):
    row = db.execute("SELECT offered FROM personal_briefing_visits WHERE user_id=?", (uid,)).fetchone()
    if row is None or through > row["offered"]:
        raise HTTPException(422, "Open the briefing before marking it seen")
    db.execute("UPDATE personal_briefing_visits SET seen=MAX(seen,?) WHERE user_id=?", (through, uid))
