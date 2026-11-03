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
| `GET /` | Built UI, or 503 when unavailable |
| `GET /stream` | SSE `event: notification`, `id: <notification_id>`, `data: <card JSON>`; heartbeat comments |
| `GET /notifications?since=N` | Array of stored cards after the notification ID, in ascending order (repository limit applies) |
| `GET /feed` | Object containing `events` |
| `GET /suppressed` | Object containing `posts` |
| `GET /status` | Adapter states, latency/counts, estimated model spend, fail-open state, X budget/reads, UI threshold/settings, inactive accounts |
| `POST /ingest` | A normalized-post JSON representation; parses ISO timestamps and queues it, returning `{"queued": true}` |
| `POST /refetch?hours=12` | Starts source catch-up; clamps hours to 1–48; returns 409 when unconfigured or already running |
| `GET /trading` | Same built UI as `/`; the page shows the trading view by path |
| `GET /portfolio` | `portfolio` (row or null), `enabled`, `max_share`, `max_hold_minutes`, `aggressiveness` levels, `contracts` per ticker |
| `PUT /portfolio` | JSON `portfolio_value`, `available_cash`, `aggressiveness`, `max_hold_minutes`; 422 when invalid; returns the saved row |
| `GET /suggestions` | Object containing `suggestions`, newest first, each a `trade_suggestions` row plus `event_title` |
| `GET /prices?ticker=WTI[&start=ISO&end=ISO]` | `ticker`, `symbol`, `last`, `bars` (`t` epoch seconds, `c` close), 1-minute; latest trading day or the given window; 502 when the feed fails |

The browser deduplicates on `notification_id` and requests backfill on reconnect.
SSE IDs are notification IDs, not post IDs or event IDs. When adding a field,
prefer an additive change and update the frontend type in `web/main.jac` with
the producer and tests. For breaking changes, sequence dependent PRs explicitly.

## Personal source API

Personal source records are isolated from the legacy shared oil feed. See
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
