CREATE TABLE IF NOT EXISTS web_push_subscriptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    session_hash TEXT NOT NULL REFERENCES sessions(token_hash) ON DELETE CASCADE,
    endpoint TEXT NOT NULL UNIQUE,
    p256dh TEXT NOT NULL,
    auth TEXT NOT NULL,
    vapid_key TEXT NOT NULL,
    since_id INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS web_push_subscription_owner
    ON web_push_subscriptions(user_id, session_hash);
CREATE TABLE IF NOT EXISTS web_push_deliveries (
    subscription_id INTEGER NOT NULL REFERENCES web_push_subscriptions(id) ON DELETE CASCADE,
    notification_id INTEGER NOT NULL REFERENCES personal_notifications(id) ON DELETE CASCADE,
    ticket TEXT NOT NULL UNIQUE,
    retry_at INTEGER, -- NULL while in flight or after a terminal result
    PRIMARY KEY (subscription_id, notification_id)
);
