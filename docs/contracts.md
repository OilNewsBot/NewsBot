# NewsDrop service contracts

NewsDrop serves the web client and JSON APIs from the same origin. The public catalog, account-owned sources and shared market monitor have separate storage identities and notification cursors. A channel slug identifies a published channel. An item ID identifies one source record. A story ID identifies a timeline that may contain several public source records and revisions.

## Browser and account

The application serves Home at `/`, Discover at `/discover`, Following at `/following` and My Sources at `/sources`. Shareable pages use `/categories/{slug}`, `/channels/{slug}` and `/stories/{slug}`. These routes serve the built web client and return 503 when its build is missing.

| Endpoint | Behavior |
| --- | --- |
| `POST /register` | Create an account with `username`, `email` and a password of at least 12 characters. The browser then calls the login endpoint to start the new session. |
| `GET /login` | Shows the sign-in form. An optional local `next` destination returns the reader to the originating view after authentication. |
| `POST /login` | Authenticate with email and password. Issues a seven-day HTTP-only `session` cookie and revokes any session previously supplied by the same browser. |
| `GET /me`, `POST /logout` | Read the session's `user_id`, `username` and `email`, or revoke the session and clear its cookie. |

Account-scoped operations derive ownership from the session cookie. Missing or expired sessions receive 401. Catalog and personal-source mutations check the browser origin. A briefing or watch mutation may include the `user_id` displayed to the reader as an account-switch guard. A mismatch returns 409.

## Public catalog and discussions

| Endpoint | Behavior |
| --- | --- |
| `GET /api/channels` | Returns `channels` with tags, type, curator, publisher, click/subscriber/recommendation counts and recent headlines. A session adds the reader's ownership, subscription, recommendation and notification flags. Discover sorts this collection in the client. |
| `GET /api/channels/{slug}` | Returns `channel` and `comments`. The optional `item` query parameter includes a specific report belonging to the channel, including older reports beyond the recent list. Recent items retain their publisher or author, source links, publication and collection times, sector, optional topic, labels and summary status. |
| `GET /api/directory` | Returns the editorial edition grouped by category. Multi-topic publishers expose up to 24 recent stories and may appear in multiple categories with up to three matching headlines per category. Routed headlines carry `section` and `routed_by`. |
| `POST /api/channels` | Publish a channel. Required fields are `name`, `description`, `category` and `source_type`. Optional `tags` add sectors. RSS uses a public `source_url`. X and Telegram support `mode` values `embed` and `api`. Community channels need only channel metadata. Returns `channel` and HTTP 201. |
| `POST /api/channels/{slug}/click` | Record one opening and return `clicks`. Available to same-origin visitors, including signed-out readers. |
| `PUT /api/channels/{slug}/subscription`, `PUT /api/channels/{slug}/recommendation` | Set the signed-in reader's choice using a boolean `enabled`. Repeated writes are idempotent. Both return `channel`. |
| `POST /api/channels/{slug}/posts` | Submit `title` and at least one of `text` or `url` to a community channel or the reader's own social channel. Returns `item` and HTTP 201. |
| `POST /api/channels/{slug}/comments` | Submit `text` with optional `item_id` and `parent_id`. A reply belongs to the same channel and item as its parent. Returns `comment` and HTTP 201. |

Normalized public items have a stable source-local identity. Redelivery reuses the stored item. AI output exposes `ai_generated` and `generated_at` alongside its source reference. The worker stores the source first, caches summaries by revision, model and prompt version, reserves a daily call budget before dispatch and backs off failed attempts. RSS is the default automatic summary source. Backend summaries for X require eligible structured content from an authorized source. Editorial X channels include saved excerpts with direct status links. New top-level posts from the operator’s X adapters enter only the editorial source matching their stable account ID, including after a handle change. Private sources and manual replay ingestion have separate delivery paths. Redelivery preserves the public item ID. An embedded timeline or an ordinary shared link provides a display surface.

## Reader briefing and story watches

| Endpoint | Behavior |
| --- | --- |
| `GET /api/briefing` | Returns the signed-in reader's `user_id`, `first_visit`, previous visit time in `since`, `cards`, `through`, `private_through` when the personal store is installed, and `has_more`. A read offers a snapshot and leaves the acknowledged visit intact. When caught up, `previous_cards` contains the reader’s last nonempty edition with private sources checked against current ownership. |
| `POST /api/briefing/seen` | Mark an edition as read at the reader’s request using its `through`, `private_through` when present, and displayed `user_id`. Provided cursors advance together in one transaction. A stale tab cannot rewind the visit or mark a later development seen. After acknowledgement, fetch again if `has_more` was true. |
| `GET /api/watches` | Returns `user_id`, saved `topics` and `stories`, the sector `taxonomy` and the available event, entity and place `facets`. |
| `PUT /api/watches/topics/{topic_id}` | Set `enabled` for a label or a combination of two to four distinct label IDs joined by `~`. The server canonicalizes order. Every label in a combination must match the same report. |
| `PUT /api/watches/stories/{story_id}` | Set `enabled` for one story timeline. Public story IDs are numeric. Private story IDs use `private-<item_id>` and require the owner's session. |
| `GET /api/stories/{story_id}` | Returns `story` with dated developments and citations. Public timelines are readable without signing in. Private timelines and watch entries are scoped to their owner and become inaccessible when their source is removed. |

A public timeline retains its identity when an article changes. The journal distinguishes first reports, substantive publisher revisions and additional sources. The briefing presents a source excerpt or changed passage, dated references, matching labels and a reason for including the card. Its checkpoints belong to the reader's visit. Channel alerts have a separate cursor.

## Following and subscription alerts

| Endpoint | Behavior |
| --- | --- |
| `GET /api/following` | Returns all subscribed `channels`, the saved `categories` and up to 200 matching `items` from those subscriptions and enabled private sources. Grouped public items retain source references. Private items carry `private_source: true`. |
| `GET /api/me/feed-preferences`, `PUT /api/me/feed-preferences` | Read or replace the account's sector selection. Send `{"categories":["utilities","tech"]}` to include either sector. An empty list includes all sectors. |
| `PUT /api/channels/{slug}/notifications` | Set the followed channel's alert preference using a boolean `enabled`. Public alerts start off. Enabling alerts establishes a silent baseline. Muting preserves the subscription and its stories. |
| `GET /api/following/notifications/head` | Returns `user_id` and `head` for a silent initial notification cursor. |
| `GET /api/following/notifications?since=N` | Returns `user_id`, `notifications` in ascending ID order, and the returned `head` for the next poll. Saved sectors and subscription alert settings determine eligible updates. |

## Private sources and selective sharing

Private connections, items, alerts and credentials belong to one account. The browsing API returns connection metadata. The server retains the encrypted X credential and enforces the configured request budget. Setup and examples are in the [personal source guide](personal-sources.md).

| Endpoint | Behavior |
| --- | --- |
| `GET /api/me/connections`, `POST /api/me/connections` | List or create connections. Creation accepts a `provider` of `rss` or `x`, a `label` and an optional `daily_limit`. An X connection also requires an `api_key`. RSS uses the feed URL supplied when adding a source. |
| `PATCH /api/me/connections/{connection_id}`, `DELETE /api/me/connections/{connection_id}` | Replace an owned X credential or disconnect the service and stop its sources. |
| `GET /api/me/sources`, `POST /api/me/sources` | List or create sources. Supply an owned `connection_id` and a `locator`. Optional fields include sector `tags`, `alerts_enabled`, `include_keywords` and `exclude_keywords`. |
| `PATCH /api/me/sources/{source_id}`, `DELETE /api/me/sources/{source_id}` | Change `enabled`, alert settings, tags or keyword filters, or remove the source from collection and delivery. Sources without explicit tags use `general`. |
| `GET /api/me/feed?after=0` | Returns `items` ordered by publication time descending with item ID as a tie breaker. `after` filters on item ID. Personal items include their source, provider, publication and receipt times, sector and topic. |
| `GET /api/me/notifications/head`, `GET /api/me/notifications?since=N` | Read `notification_id` for a silent baseline, then eligible `notifications` in ascending order. Each alert carries its personal `notification_id` and kind `SOURCE_POST`. |
| `GET /api/me/stream?since=N` | Receive private notification events. `Last-Event-ID` takes precedence on reconnect. The stream emits `session_expired` when the session expires or is revoked. |
| `GET /api/me/telegram`, `POST /api/me/telegram/pair`, `DELETE /api/me/telegram` | Read the owner's bot inbox, issue an expiring pairing link, or disconnect the Telegram account. Pairing requires a configured bot. |
| `POST /api/telegram/updates` | Telegram bot webhook. Authenticates the incoming request with the configured `X-Telegram-Bot-Api-Secret-Token` header. |
| `POST /api/me/share-item` | Requires `confirmed: true`, a provider, an owned item ID and an owned matching API-channel slug. For Telegram, the reader supplies a title and selects an excerpt present in the original message. For X, the server retrieves the authorized record and validates its post URL. Returns the published `item`. |

## Installed app and notifications

The web manifest starts the installed NewsDrop app at `/sources`. The service worker provides an offline navigation page. The signed-in Web Push API under `/api/me/web-push` binds each subscription to its account session. Background alerts use the same private-source eligibility and sector filters as the in-page feed of alerts. Opening a notification rechecks the current session and preferences before navigating to its item. [Web Push controls and endpoints](pwa.md)

The forum keeps `/oil` and `/trading` bookmarks pointed at Home. Its navigation exposes channel alerts, and My Sources exposes private-source alerts. The market API and Expo market notifications remain available to their existing clients.

## Market monitor and trading

Adapters send `NormalizedPost` records to the asynchronous pipeline. The storage deduplication key is `(source, source_post_id)`. Each record includes the stable `account_id`, current `account_handle`, `tier`, `url`, `text`, optional `quoted_text`, `media_urls`, `is_reply`, and UTC-aware `posted_at` and `received_at`. The adapters filter replies during normal collection. The pipeline persists posts before classification, clusters accepted developments, stores the notification, then broadcasts its `notification_id` on the in-process event bus.

| Endpoint | Behavior |
| --- | --- |
| `GET /stream`, `GET /notifications?since=N` | Live market SSE cards use event type `notification` and the stored notification ID as the SSE ID, with heartbeat comments between events. Reconnect by fetching stored cards after the last notification ID in ascending order. |
| `GET /feed`, `GET /suppressed`, `GET /status` | Return shared market events, suppressed posts, or operational status including adapter state, counts, latency, estimated model spend, fail-open status, X usage and threshold settings. |
| `POST /ingest` | Admin only. Queues a normalized post with ISO timestamps and returns `{"queued":true}`. |
| `POST /refetch?hours=12` | A signed-in or admin caller can request X push catch-up. The window is clamped to 1–48 hours. An unconfigured adapter or active catch-up returns 409. |
| `GET /portfolio`, `PUT /portfolio` | Admin access to the shared manual portfolio. A write accepts `portfolio_value`, `available_cash`, `aggressiveness` and `max_hold_minutes`. Invalid sizing values return 422. |
| `GET /suggestions`, `GET /prices?ticker=<ticker>&start=<ISO>&end=<ISO>` | Return trade suggestions with their event titles, or minute closing prices for a supported instrument. Omitting the price window selects the latest trading day. A price-feed failure returns 502. |
| `PUT /mobile/subscription` | With mobile push enabled, an installation bearer secret controls its Expo push subscription. Enabling requires a valid Expo push token. |

Market card kinds are `NEW_EVENT`, `UPDATE` and `UNFILTERED`. The card fields are `notification_id`, `kind`, `post_id`, `category`, `one_line`, `score`, `handle`, `tier`, `url`, `posted_at`, `received_at`, `platform_latency_s`, `event_id`, `event_title`, `what_changed` and `badges`. Classification and event fields can be null. Consumers deduplicate market cards using the market `notification_id`.

For admin routes, a configured `NEWSBOT_ADMIN_TOKEN` must match the `X-Admin-Token` header. When the token is unset, only loopback clients qualify for admin access.
