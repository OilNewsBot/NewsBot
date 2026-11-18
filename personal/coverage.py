"""Account-scoped views over private items, including sources saved before tagging."""
import json

from publicnews.topics import article_labels, channel_topic


def item_topic(title, body, raw_tags):
    tags = json.loads(raw_tags) if raw_tags else ["general"]
    return channel_topic(title, body, None, tags[0], tags, tags[0] == "general")


def item_section(title, body, raw_tags):
    return item_topic(title, body, raw_tags)[0]


def present(row):
    raw_tags = row.pop("tags_json")
    row["section"], row["topic"] = item_topic(row["title"], row["text"], raw_tags)
    row["tags"] = json.loads(raw_tags) if raw_tags else ["general"]
    row["category"] = row["tags"][0]
    row["labels"] = article_labels(row["title"], row["text"], row["section"])
    row["story_id"] = f"private-{row['id']}"
    return row


def for_following(row):
    item = present(row)
    return {**item, "id": f"private-{item['id']}", "private_source": True,
            "channel_name": item["source_name"], "channel_slug": "", "source_type": item["provider"],
            "published_at": item["posted_at"], "published": item["posted_at"], "body": item["text"],
            "summary": item["text"], "status": "original", "sources": [], "ai_generated": False}


_COLUMNS = "i.*, s.name AS source_name, c.provider, t.tags AS tags_json"
_JOINS = """
    FROM personal_items i
    JOIN personal_sources s ON i.source_id=s.id AND i.user_id=s.user_id
    JOIN personal_connections c ON c.id=s.connection_id AND c.user_id=s.user_id
    LEFT JOIN personal_source_tags t ON t.source_id=s.id
"""
_OWNER = "i.user_id=? AND s.deleted_at IS NULL AND c.deleted_at IS NULL"
_ORDER = "ORDER BY i.posted_at DESC, i.id DESC LIMIT ?"

PRIVATE_FEED = f"SELECT {_COLUMNS} {_JOINS} WHERE {_OWNER} AND i.id>? {_ORDER}"
FOLLOWING = f"""SELECT {_COLUMNS} {_JOINS} WHERE {_OWNER} AND s.enabled=1
    AND (?='[]' OR item_section(i.title,i.text,t.tags) IN (SELECT value FROM json_each(?)))
    {_ORDER}"""
ALERT_ELIGIBILITY = """n.id>s.alert_after_id AND s.deleted_at IS NULL AND c.deleted_at IS NULL
    AND s.enabled=1 AND s.alerts_enabled=1 AND c.status<>'disconnected'
    AND (NOT EXISTS (SELECT 1 FROM news_feed_categories f WHERE f.user_id=i.user_id)
      OR EXISTS (SELECT 1 FROM news_feed_categories f WHERE f.user_id=i.user_id
                 AND f.category=item_section(i.title,i.text,t.tags)))"""
NOTIFICATIONS = f"""SELECT {_COLUMNS}, n.id AS notification_id, 'SOURCE_POST' AS kind
    {_JOINS} JOIN personal_notifications n ON n.item_id=i.id AND n.user_id=i.user_id
    WHERE i.user_id=? AND n.id>? AND {ALERT_ELIGIBILITY}
    ORDER BY n.id LIMIT ?"""
