-- Additive tables: safe on existing NewsBot databases. No feed schema changes.
CREATE TABLE IF NOT EXISTS mobile_subscriptions (
    device_id TEXT PRIMARY KEY, -- SHA-256 of the installation's random bearer secret
    token TEXT UNIQUE,
    enabled INTEGER NOT NULL DEFAULT 0,
    since_id INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS mobile_deliveries (
    device_id TEXT NOT NULL,
    notification_id INTEGER NOT NULL,
    token TEXT NOT NULL, -- snapshot, so an old receipt cannot disable a rotated token
    ticket_id TEXT,
    created_at REAL NOT NULL,
    PRIMARY KEY (device_id, notification_id)
);
CREATE INDEX IF NOT EXISTS mobile_receipts ON mobile_deliveries (created_at) WHERE ticket_id IS NOT NULL;
