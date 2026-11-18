-- Public channel data lives alongside the account and personal-source tables.
CREATE TABLE IF NOT EXISTS news_sources (
    id INTEGER PRIMARY KEY,
    kind TEXT NOT NULL,
    locator TEXT NOT NULL,
    publisher TEXT NOT NULL,
    mixed INTEGER NOT NULL DEFAULT 0,
    checked_at TEXT,
    next_poll INTEGER NOT NULL DEFAULT 0,
    failures INTEGER NOT NULL DEFAULT 0,
    UNIQUE(kind, locator)
);
CREATE TABLE IF NOT EXISTS news_feed_validators (
    source_id INTEGER PRIMARY KEY REFERENCES news_sources(id),
    url TEXT NOT NULL, etag TEXT NOT NULL, modified TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS news_channels (
    slug TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT NOT NULL,
    category TEXT NOT NULL, owner_id INTEGER REFERENCES users(id), curator TEXT NOT NULL,
    source_id INTEGER NOT NULL REFERENCES news_sources(id), source_url TEXT NOT NULL,
    mode TEXT NOT NULL, created_at TEXT NOT NULL, clicks INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS news_channels_source ON news_channels(source_id);
CREATE TABLE IF NOT EXISTS news_items (
    id INTEGER PRIMARY KEY, source_id INTEGER NOT NULL REFERENCES news_sources(id),
    external_id TEXT NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL,
    author TEXT NOT NULL, published TEXT NOT NULL, collected_at TEXT NOT NULL,
    section TEXT NOT NULL, revision TEXT NOT NULL, story_key TEXT NOT NULL,
    eligible INTEGER NOT NULL DEFAULT 0,
    UNIQUE(source_id, external_id)
);
CREATE INDEX IF NOT EXISTS news_items_recent ON news_items(source_id, published DESC, id DESC);
CREATE INDEX IF NOT EXISTS news_items_url ON news_items(source_id, url);
CREATE INDEX IF NOT EXISTS news_items_revision ON news_items(revision);
CREATE INDEX IF NOT EXISTS news_items_story ON news_items(story_key);
CREATE TABLE IF NOT EXISTS news_summaries (
    revision TEXT NOT NULL, model TEXT NOT NULL, prompt_version TEXT NOT NULL,
    summary TEXT NOT NULL DEFAULT '', generated_at TEXT, attempts INTEGER NOT NULL DEFAULT 0,
    retry_at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(revision, model, prompt_version)
);
CREATE TABLE IF NOT EXISTS news_usage (
    day TEXT PRIMARY KEY, calls INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS news_subscriptions (
    user_id INTEGER NOT NULL REFERENCES users(id), slug TEXT NOT NULL REFERENCES news_channels(slug),
    PRIMARY KEY(user_id,slug)
);
CREATE TABLE IF NOT EXISTS news_votes (
    user_id INTEGER NOT NULL REFERENCES users(id), slug TEXT NOT NULL REFERENCES news_channels(slug),
    PRIMARY KEY(user_id,slug)
);
CREATE TABLE IF NOT EXISTS news_comments (
    id INTEGER PRIMARY KEY, slug TEXT NOT NULL REFERENCES news_channels(slug),
    item_id INTEGER REFERENCES news_items(id), parent_id INTEGER REFERENCES news_comments(id),
    user_id INTEGER NOT NULL REFERENCES users(id), author TEXT NOT NULL, text TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS news_comments_thread ON news_comments(slug,item_id,id);
