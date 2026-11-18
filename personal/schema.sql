-- Personal source content is scoped to its owner.
-- This additive schema preserves existing data and its global deduplication key.
CREATE TABLE IF NOT EXISTS personal_schema_versions (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS personal_connections (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider TEXT NOT NULL CHECK (provider IN ('rss', 'x')),
    revision INTEGER NOT NULL DEFAULT 0,
    label TEXT NOT NULL,
    secret TEXT NOT NULL DEFAULT '',
    fingerprint TEXT UNIQUE,
    status TEXT NOT NULL DEFAULT 'connected',
    last_error TEXT NOT NULL DEFAULT '',
    retry_at TEXT NOT NULL DEFAULT '',
    daily_limit INTEGER NOT NULL DEFAULT 200,
    request_day TEXT NOT NULL DEFAULT '',
    requests_today INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    deleted_at TEXT
);
CREATE INDEX IF NOT EXISTS personal_connections_owner ON personal_connections(user_id, id);
CREATE TABLE IF NOT EXISTS personal_sources (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    connection_id INTEGER NOT NULL REFERENCES personal_connections(id),
    revision INTEGER NOT NULL DEFAULT 0,
    remote_id TEXT NOT NULL,
    name TEXT NOT NULL,
    url TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    alerts_enabled INTEGER NOT NULL DEFAULT 1,
    alert_after_id INTEGER NOT NULL DEFAULT 0,
    include_keywords TEXT NOT NULL DEFAULT '[]',
    exclude_keywords TEXT NOT NULL DEFAULT '[]',
    status TEXT NOT NULL DEFAULT 'pending',
    last_error TEXT NOT NULL DEFAULT '',
    last_success TEXT,
    next_poll_at TEXT NOT NULL DEFAULT '',
    initialized INTEGER NOT NULL DEFAULT 0,
    cursor TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    deleted_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS personal_source_identity
    ON personal_sources(connection_id, remote_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS personal_sources_owner ON personal_sources(user_id, id);
CREATE TABLE IF NOT EXISTS personal_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    source_id INTEGER NOT NULL REFERENCES personal_sources(id),
    external_id TEXT NOT NULL,
    title TEXT NOT NULL,
    text TEXT NOT NULL,
    url TEXT NOT NULL,
    posted_at TEXT NOT NULL,
    received_at TEXT NOT NULL,
    UNIQUE(source_id, external_id)
);
CREATE INDEX IF NOT EXISTS personal_items_owner ON personal_items(user_id, id);
CREATE TABLE IF NOT EXISTS personal_notifications (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    item_id INTEGER NOT NULL UNIQUE REFERENCES personal_items(id),
    source_id INTEGER NOT NULL REFERENCES personal_sources(id),
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS personal_notifications_owner ON personal_notifications(user_id, id);
INSERT OR IGNORE INTO personal_schema_versions(version) VALUES (1);

-- Direct messages sent to the publishing bot stay in an owner-only inbox.
CREATE TABLE IF NOT EXISTS personal_telegram_pairing (
    user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    challenge_hash TEXT NOT NULL UNIQUE,
    expires_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS personal_telegram_accounts (
    user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    telegram_id INTEGER NOT NULL UNIQUE,
    linked_at INTEGER NOT NULL,
    linked_message_id INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS personal_telegram_inbox (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES personal_telegram_accounts(user_id) ON DELETE CASCADE,
    message_id INTEGER NOT NULL,
    body TEXT NOT NULL,
    published_at TEXT NOT NULL,
    UNIQUE(user_id, message_id)
);
CREATE INDEX IF NOT EXISTS personal_telegram_inbox_user ON personal_telegram_inbox(user_id, id);
INSERT OR IGNORE INTO personal_schema_versions(version) VALUES (2);

-- A missing row gives sources created before this migration General coverage.
CREATE TABLE IF NOT EXISTS personal_source_tags (
    source_id INTEGER PRIMARY KEY REFERENCES personal_sources(id) ON DELETE CASCADE,
    tags TEXT NOT NULL
);
-- Also opened by the public catalog when installed on its own.
CREATE TABLE IF NOT EXISTS news_feed_categories (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    category TEXT NOT NULL, PRIMARY KEY(user_id,category)
);
INSERT OR IGNORE INTO personal_schema_versions(version) VALUES (3);

-- Record owner-only developments in the same transaction as each source item.
CREATE TABLE IF NOT EXISTS personal_developments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    item_id INTEGER NOT NULL REFERENCES personal_items(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK(kind IN ('new','updated')),
    observed_at TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, url TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS personal_developments_reader ON personal_developments(user_id,id);
CREATE INDEX IF NOT EXISTS personal_developments_story ON personal_developments(item_id,id);
CREATE UNIQUE INDEX IF NOT EXISTS personal_story_first ON personal_developments(item_id) WHERE kind='new';
CREATE TABLE IF NOT EXISTS personal_story_watches (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    item_id INTEGER NOT NULL REFERENCES personal_items(id) ON DELETE CASCADE,
    PRIMARY KEY(user_id,item_id)
);
CREATE TABLE IF NOT EXISTS personal_briefing_visits (
    user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    seen INTEGER NOT NULL DEFAULT 0, offered INTEGER NOT NULL DEFAULT 0
);
INSERT OR IGNORE INTO personal_developments(user_id,item_id,kind,observed_at,title,body,url)
    SELECT user_id,id,'new',received_at,title,text,url FROM personal_items
    WHERE NOT EXISTS (SELECT 1 FROM personal_schema_versions WHERE version=4) ORDER BY id;
CREATE TRIGGER IF NOT EXISTS personal_story_insert AFTER INSERT ON personal_items BEGIN
    INSERT INTO personal_developments(user_id,item_id,kind,observed_at,title,body,url)
    VALUES(NEW.user_id,NEW.id,'new',NEW.received_at,NEW.title,NEW.text,NEW.url);
END;
INSERT OR IGNORE INTO personal_schema_versions(version) VALUES (4);
