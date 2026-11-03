-- Personal sources are deliberately separate from the legacy oil pipeline.
-- This additive schema preserves existing data and its global deduplication key.
CREATE TABLE IF NOT EXISTS personal_schema_versions (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS personal_connections (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider TEXT NOT NULL CHECK (provider IN ('rss', 'x')),
    label TEXT NOT NULL,
    secret TEXT NOT NULL DEFAULT '',
    fingerprint TEXT UNIQUE,
    status TEXT NOT NULL DEFAULT 'connected',
    last_error TEXT NOT NULL DEFAULT '',
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
    remote_id TEXT NOT NULL,
    name TEXT NOT NULL,
    url TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    alerts_enabled INTEGER NOT NULL DEFAULT 1,
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
