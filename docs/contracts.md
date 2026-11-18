# Shared interfaces

Read the implementation before changing a contract. Update this document and its
consumers/tests together. Coordinate through the relevant task when another agent
is changing a producer or consumer.

## Adapter → pipeline

`adapters/base.jac` defines `NormalizedPost` and `SourceAdapter`.

| Field | Meaning |
| --- | --- |
| `source`, `source_post_id` | Platform plus platform-local post identifier; together the persistence deduplication key |
| `account_id`, `account_handle` | Stable platform ID and current display handle |
| `url`, `text`, `quoted_text`, `media_urls` | Original content and optional quoted/media context |
| `is_reply` | Adapters filter replies before normal ingestion |
| `posted_at`, `received_at` | UTC-aware datetimes; platform delay is received minus posted |
| `tier` | Source metadata: official, tracker, or osint |

An adapter runs asynchronously and delivers normalized posts to the sink.
Account resolution returns a stable ID and canonical handle; adapter status is
exposed in `/status`. Adding a source should preserve this boundary.

## Pipeline → database → notification

`pipeline/classify.jac` owns classification results; `pipeline/dedup.jac` owns
clustering. Database table definitions live in `db/schema.sql`; callers use
`db/repo.jac`. JSON fields in storage are serialized by the repository layer.

`pipeline/notify.jac` builds a card, persists it, adds `notification_id`, then
publishes the same card to the in-process bus. Cards contain:

```text
notification_id, kind, post_id, category, one_line, score,
handle, tier, url, posted_at, received_at, platform_latency_s,
event_id, event_title, what_changed, badges
```

Kinds are `NEW_EVENT`, `UPDATE`, and `UNFILTERED`; category/score/event_id may be
null on the relevant paths. Do not assume every notification is classified.

## HTTP / SSE → browser

| Endpoint | Current response/behavior |
| --- | --- |
| `GET /`, `GET /discover`, `GET /following` | Web client with public sector cards, sortable channel directory and signed-in Following. Returns 503 when the client build is unavailable. |
| `GET /categories/{slug}`, `GET /channels/{slug}` | Shareable public views. Each channel row expands to show recent stories, summaries, dates and publisher links. |
| `GET /api/directory` | Compatibility view of the editorial catalog seeded from `db/directory_seed.json`. Successful RSS refreshes update the edition and `checked_at`. |
| Multi-topic publisher entries | `publishers` contains each publisher's full recent edition (up to 24 stories). Its canonical slug can also appear in several categories, each showing up to three headlines assigned to that category's slug. Each routed headline carries its `section` and `routed_by` value. |
| Retired workspace bookmarks | Redirect to the public home. |
| `GET /stream` | SSE `event: notification`, `id: <notification_id>`, `data: <card JSON>`; heartbeat comments |
| `GET /notifications?since=N` | Array of stored cards after the notification ID, in ascending order (repository limit applies) |
| `GET /feed` | Object containing `events` |
| `GET /suppressed` | Object containing `posts` |
| `GET /status` | Adapter states, latency/counts, estimated model spend, fail-open state, X budget/reads, UI threshold/settings, inactive accounts |
| `POST /ingest` | Admin only: the `X-Admin-Token` header must equal `NEWSBOT_ADMIN_TOKEN` when that is set, otherwise only loopback clients are accepted (403 otherwise). A normalized-post JSON representation; parses ISO timestamps and queues it, returning `{"queued": true}` |
| `POST /refetch?hours=12` | Signed-in session or admin client (401 otherwise). Starts source catch-up; clamps hours to 1–48; returns 409 when unconfigured or already running |
| `GET /portfolio` | Admin access. Returns the shared operator portfolio and configured sizing rules. |
| `PUT /portfolio` | Admin access. Accepts `portfolio_value`, `available_cash`, `aggressiveness` and `max_hold_minutes`. Returns 422 on invalid input. |
| `GET /suggestions` | Object containing `suggestions`, newest first, each a `trade_suggestions` row plus `event_title` |
| `GET /prices?ticker=<configured ticker>[&start=ISO&end=ISO]` | `ticker`, `symbol`, `last`, `bars` (`t` epoch seconds, `c` close), 1-minute; latest trading day or the given window; 502 when the feed fails |

The browser deduplicates on `notification_id` and requests backfill on reconnect.
SSE IDs are notification IDs, not post IDs or event IDs. When adding a field,
prefer an additive change and update the frontend type in `web/main.jac` with
the producer and tests. For breaking changes, sequence dependent PRs explicitly.

## Public catalog and social activity

| Endpoint | Behavior |
| --- | --- |
| `GET /api/channels` | Lists public channel metadata, counts, and story previews. An authenticated session adds viewer-specific ownership and follow/recommend flags. |
| `GET /api/channels/{slug}` | Channel details, source references, recent items and discussion. |
| `POST /api/channels` | Publish a channel for the authenticated user with a name, description, category, source type, and source URL or API mode where applicable. |
| `POST /api/channels/{slug}/click` | Record a channel opening. Returns the updated total. |
| `PUT /api/channels/{slug}/subscription`, `PUT /api/channels/{slug}/recommendation` | Set the session user's choice with `{"enabled":true}` or `false`. Repeating the request is idempotent. |
| `GET /api/following` | Signed-in user's subscribed channels and grouped news items. |
| `POST /api/channels/{slug}/posts` | Publish a titled post with text or an optional source URL in an eligible channel. |
| `POST /api/channels/{slug}/comments` | Post text on a channel, or attach to an item or parent comment in the same thread. |
| `GET /api/me/telegram`, `POST /api/me/telegram/pair`, `DELETE /api/me/telegram` | Read the account's private Telegram inbox, issue an expiring pairing link, or disconnect. |
| `POST /api/telegram/updates` | Dedicated bot webhook authenticated by Telegram's configured secret header. |
| `POST /api/me/share-item` | Publish an explicitly confirmed selection from the owner's private inbox or authorized X feed into an owned channel of the matching type. |

## Private connections and collection

Personal source records are isolated from the shared market-event feed. See
[Personal sources](personal-sources.md) for setup, delivery semantics and limits.
Every `/api/me/*` route derives ownership from the session cookie; no caller
`user_id` is accepted. Mutations reject cross-origin browser requests.

| Endpoint | Response |
| --- | --- |
| `GET /sources` | Same built UI, selecting the personal sources page |
| `GET /api/me/connections` | `{connections: [...]}`; no credentials |
| `POST /api/me/connections` | `{connection: ...}`; input provider (`rss` or `x`), label, optional api_key and daily_limit |
| `PATCH /api/me/connections/{id}` | `{connection: ...}`; replace an X api_key |
| `DELETE /api/me/connections/{id}` | Disconnect owned service and stop its sources |
| `GET /api/me/sources` | `{sources: [...]}` with status and preferences |
| `POST /api/me/sources` | `{source: ...}`; owned connection_id, locator and optional alert preferences |
| `PATCH /api/me/sources/{id}` | `{source: ...}`; enabled, alerts_enabled, include_keywords, exclude_keywords |
| `DELETE /api/me/sources/{id}` | Remove owned source from collection and delivery |
| `GET /api/me/feed?after=0` | `{items: [...]}`; publication time descending, item ID as tie breaker; optional after filters item IDs |
| `GET /api/me/notifications?since=0` | `{notifications: [...]}`; eligible alerts ascending |
| `GET /api/me/notifications/head` | `{notification_id: N}` for silent initial baseline |
| `GET /api/me/stream?since=N` | SSE notification events with stable personal notification IDs; supports Last-Event-ID replay |

Personal item fields: `id`, `source_id`, `source_name`, `provider`, `title`,
`text`, `url`, `posted_at`, `received_at`. Alerts add `notification_id` and
`kind: SOURCE_POST`. These IDs belong to the personal notification table, not
the legacy notification table. Empty/exhausted sessions receive 401; an already
open personal SSE session ends on expiry/revocation with `session_expired`.

## Shared configuration and runtime

`jac.toml`/`jac.lock`, `config.jac`, the database schema, shared test helpers,
and recorded cassettes are common coordination points. Publish intended changes
before editing them. Avoid unrelated dependency upgrades or mass formatting in
feature work. `config.yaml` server overrides are per-checkout during development;
do not commit a temporary port/database change as part of an unrelated feature.
