# Newsstream product specification

This is the shared product specification for NewsBot (the app is named Newsstream).
Read the relevant sections before changing behavior. AGENTS.md and
[collaboration.md](collaboration.md) govern the coding workflow for all agents.
An explicit new user requirement can update this spec; document the decision.
Otherwise, preserve specified behavior and investigate disagreements with the code.

The historical data-source costs, model names, and latency goals below are project
assumptions, not freshly verified provider documentation or measured guarantees.
Check current provider documentation before changing integrations or cost estimates.
See [project.md](project.md) for the implementation map and [contracts.md](contracts.md)
for current interfaces. Fixture wording is reconstructed; see
[fixture provenance](../tests/fixtures/README.md).

## 1. Purpose

Newsstream helps readers follow market-moving news across Energy, Tech,
Healthcare and Industrials. A reader can follow a sector, a publisher or a
community and trace a story back to the evidence behind it. Trading analysis
starts with the event and the instruments it could affect. For example, a
clinical trial result and a change in aircraft production have different
sources, affected companies and time horizons.

## 2. Launch scope

The shared demo should let readers browse genuine dated stories, publish
channels, follow other curators and discuss updates. RSS is the first automatic
summary source. Public X channels display official profile timelines and accept
shared post links. Community channels host authored posts with optional sources.

The feature branch already serves a public sector directory, shareable channel
pages and signed-in My Sources. Public publishing, subscriptions, threads,
ratings and the shared summary engine are planned increments. Generalized
trading signals and hypothetical performance have their own later scope.
See the [implementation roadmap](feature-overhaul.md) for acceptance criteria.

## 3. Architecture

The current public directory reads a saved edition and can refresh from RSS.
Personal collectors persist to owner-scoped SQLite tables. The existing market
monitor has a separate path from configured adapters through classification,
event clustering and notifications. The target public path is:

```text
RSS / community / authorized provider data
    → normalize and persist → deduplicate → summarize eligible revisions → channel feed
```

X embeds render on the channel page. Structured inputs for processing come
from an authorized provider or eligible text a user intentionally supplies.

- **Language:** Jac (ported from Python 3.12 on 2026-10-07). The
  `jac` binary manages the environment: `jac install`, `jac run`, `jac test`,
  `jac check`. Python libraries are imported from Jac directly.
- **Service:** FastAPI + uvicorn. One process, asyncio. Adapters run as tasks.
- **Storage:** SQLite via `aiosqlite`. Single file `./data/newsstream.db`.
- **Frontend:** one Jac client module (`web/main.jac` + `web/main.css`),
  compiled by `jac build web` into a single self-contained `index.html` that
  FastAPI serves. Server-Sent Events at `/stream`. The service rebuilds the
  page at startup when it is missing or stale.
- **LLM:** Anthropic Messages API via the official Python SDK. Configurable model slots (see §9). Do not hardcode model strings anywhere
  except `config.jac`.
- **Config:** `.env` for secrets, `config.yaml` for accounts/thresholds/categories.
  `jac.toml` declares the three apps (`server`, `web`, `replay`) and pins the
  Python and npm packages.

Directory layout:

```
newsstream/
  jac.toml            # workspace: apps (server, web, replay), pinned dependencies
  main.jac            # entry point for `jac run`; calls app.main()
  app.jac             # FastAPI app, SSE endpoint, serves the built UI
  config.jac          # loads .env + config.yaml, exposes typed Settings
  replay.jac          # fixture replay CLI (§11)
  adapters/
    base.jac          # SourceAdapter base + NormalizedPost
    telegram.jac
    x_api.jac         # official X API, pay-per-use, polling
    x_push.jac        # third-party push feed (WebSocket), if configured
  pipeline/
    llm.jac           # Anthropic wrapper: JSON retry, cassette, fail-open counter
    normalize.jac
    classify.jac      # rubric prompt, JSON parse, retry
    dedup.jac         # event clustering
    notify.jac        # notification cards; writes to SSE bus
    runner.jac        # orchestration: persist -> classify -> dedup -> notify
    prompts/
  db/
    schema.sql
    repo.jac
  web/
    main.jac          # the browser UI (§10)
    main.css
  tests/
    fixtures/         # real posts from Sept 2026 (see §11)
    helpers.jac       # shared test helpers (StubLLM, fixture loaders)
    adapters_tests.jac
    classify_tests.jac
    dedup_tests.jac
  config.yaml
  .env.example
```

## 4. Data sources

Public RSS collection uses the existing bounded fetcher and parser. Fetch a
distinct feed once for its subscribers and retain the last successful edition
through publisher outages. Community posts carry a title, body, author, sector
and optional source link. A public X channel can display an official timeline
without visitor credentials. Viewing an embed or sharing a URL does not enqueue
post text for processing.

Existing operators can configure Telegram, third-party X push and budgeted
official X polling for the separate event monitor. Preserve stable account
identity, checkpoints and daily limits when extending an authorized adapter.

### Adapter interface

```jac
obj NormalizedPost {
    has source: str,            # "telegram" | "x"
        source_post_id: str,
        account_id: str,        # STABLE numeric id, never the handle
        account_handle: str,    # display only; may change
        url: str,
        text: str,
        quoted_text: str | None,
        is_reply: bool,
        posted_at: datetime,    # UTC, from the platform
        received_at: datetime,  # UTC, when we got it
        media_urls: list[str] = [],
        tier: str = "osint";    # resolved from config by the pipeline
}

obj SourceAdapter {
    has status: AdapterStatus postinit;
    async def run(sink: Sink) -> None abst;                              # sink: async (NormalizedPost) -> None
    async def resolve_account(handle: str) -> tuple[str, str] abst;      # (id, canonical_handle)
}
```

Rules every adapter must obey:

- **Track by numeric account ID.** Resolve handle→ID once at setup, store both,
  refresh the handle from the ID on each poll. This solves renames and lets us
  detect deletions (ID stops resolving → mark account `inactive`, notify user in
  the UI, never crash).
- **Drop replies at the adapter.** `is_reply=True` never enters the pipeline.
- **Quote tweets are top-level posts** whose `quoted_text` is populated. The
  classifier sees both. The common case is an OSINT account adding "confirmed"
  or "denied" to someone else's report — that is high-value.
- **Record `received_at`.** `received_at - posted_at` is the latency metric.
  Log it per post; show p50/p95 in the UI footer.

## 5. Seed channels

Start with genuine, dated publisher stories and two editorial RSS picks in
each of the four sectors. The bundled catalog and source URLs live in
`db/directory_seed.json`. Multi-topic publishers can appear in several sectors.
General News holds articles without a clear sector fit. Label editorial picks
as such until users' recommendations support a ranking.

## 6. Pipeline

The existing event monitor processes each adapter `NormalizedPost` as follows. Public directory items and personal feeds currently follow separate paths.

1. **Persist raw** to `posts` immediately (before any LLM call). Never lose a post
   to a downstream failure.
2. **Skip** if `source_post_id` already seen (adapter re-delivery).
3. **Classify** (§7). Store the full JSON decision in `decisions`.
4. If `materiality_score < threshold` → stop. (Still stored; visible in the
   "suppressed" tab of the UI for auditing.)
5. **Dedup / cluster** (§8). Outcome is one of `NEW_EVENT`, `UPDATE`, `DUPLICATE`.
6. `DUPLICATE` → stop (stored, linked to the event).
7. `NEW_EVENT` / `UPDATE` → **notify**: write a `notifications` row, publish on
   the SSE bus. Frontend renders it.

Latency budget from `received_at` to SSE publish: **≤ 4 s p95**. Classifier and
dedup calls run concurrently where possible (dedup candidates can be fetched
while classification is in flight).

## 7. Classification

### Why not "confidence %"

An LLM's self-reported "95% confident" is a stylistic output, not a calibrated
probability. Thresholding on it produces unpredictable behavior. Instead the
model scores against a **rubric the user controls**, and the threshold is on the
rubric score. The user can still set the threshold in the monitor configuration.

### Sector relevance and evidence

Score market alerts for novelty, specificity, source proximity and plausible
impact on the affected market. A regulator's published decision may change a
company's outlook. A second report repeating that decision adds a reference,
while a subsequent correction to its scope can warrant a new alert.

The existing monitor stores a weighted `materiality_score` on a 0–100 scale,
one event category, a short description, entities and reasoning. Consult
`config.yaml` and `pipeline/prompts/` for the implemented weights, fields and
allowed labels. Sector assignment for public articles uses the separate
directory router. An item can appear in the public feed regardless of whether
it qualifies for a market alert.

### Model routing

- **Triage model** (fast, cheap) classifies every post.
- If `materiality_score` lands within ±8 of the threshold → re-run with the
  **review model** (stronger) and use its result. Log both.
- Both model IDs come from env vars (§9). Check
  https://docs.claude.com/en/docs/about-claude/models for current IDs before
  filling in `.env.example`; do not rely on memory.
- Use `max_tokens=400`, temperature 0, and parse strictly. On JSON parse failure
  retry once with "Return only JSON." appended; on second failure store
  `classification_error` and **surface the post anyway at threshold** — a
  broken classifier must fail open, not silent.

## 8. Deduplication and event clustering

Group reports about the same event. Two accounts reporting the same earnings release share an event. A corrected revenue figure is an update. A repost of the original release is a duplicate.

### Data model

- `events(id, category, title, first_seen_at, last_updated_at, summary,
  entities_json, status)` — `status` in `open | stale`.
- `event_posts(event_id, post_id, role)` — `role` in `origin | update | duplicate`.
- An event goes `stale` after 24h with no updates and is no longer a dedup
  candidate (a subsequent development can open a new event).

### Procedure

For a post that passed the threshold:

1. Fetch candidate events: `status = open`, same category OR overlapping
   `entities` (vessel name, location, actor), `last_updated_at` within 24h.
   Cap at 8 candidates, most recent first.
2. If no candidates → `NEW_EVENT`.
3. Otherwise one LLM call (review model) with the post and the candidates'
   `title + summary + entities`, returning:

```
{"decision": "NEW_EVENT" | "UPDATE" | "DUPLICATE",
 "event_id": "<candidate id or null>",
 "what_changed": "<≤ 25 words, only for UPDATE>",
 "reasoning": "<≤ 40 words>"}
```

Instruction to the model: an UPDATE is a post that changes the *picture* —
confirmation by an official source, a denial, a revised figure or a correction. A DUPLICATE restates what the event summary
already contains, in any wording. When in doubt between UPDATE and DUPLICATE,
choose DUPLICATE (the user has the link and can read the thread).

4. On `UPDATE`, rewrite `events.summary` (LLM, ≤ 60 words, merging the new fact)
   and bump `last_updated_at`. On `NEW_EVENT`, create the event from the
   classifier's `one_line` and `entities`.

Do not use embeddings in v1. Volume is low (tens of posts/day past threshold)
and the LLM comparison is more precise than cosine similarity on short text.
Revisit if candidate fetch exceeds ~20 per post.

## 9. Configuration

`.env` (secrets — never commit):

```
ANTHROPIC_API_KEY=
TRIAGE_MODEL=          # fill from docs.claude.com models page
REVIEW_MODEL=
TELEGRAM_API_ID=       # if using telethon
TELEGRAM_API_HASH=
TELEGRAM_BOT_TOKEN=    # if using Bot API
X_BEARER_TOKEN=        # official API, optional
X_PUSH_API_KEY=        # third-party feed, optional
```

The active market rubric, thresholds, accounts, platform read budgets, UI
settings and supported trading instruments are defined in `config.yaml`.
Additional sector prompts and sample market settings exist. Running alerts and
trade suggestions across all four sectors still requires implementation.

## 10. Frontend behavior

Home is the public sector directory. Category and channel links support direct entry. My Sources requires a session. Discover and Following are planned destinations. Part 1 covers the shared navigation, collapsible sidebar and bottom-of-page access on existing views.

The existing event-notification client defines the following behavior for consumers of the shared monitor:

- **Tray** at top-right stacks up to `ui.max_stacked` cards; older cards
  collapse into a "+N more" pill. Newest on top.
- Each **card**: category badge, `one_line`, account handle + tier chip,
  `posted_at` as relative time ("2m ago") *and* latency ("+38s"), link to the
  original post (opens new tab), and for UPDATEs a "what changed" line under
  the event title.
- **Click anywhere on a card** = acknowledged. It moves to the feed below and
  is removed from the tray. Keyboard: `Esc` acknowledges the top card.
- **Feed** below the tray: reverse-chronological list of all surfaced items,
  grouped by event (event title as a header, posts nested). Toggle to show
  suppressed posts with their scores — this is how the user tunes the threshold.
- **Footer**: adapter status (live / reconnecting / budget-paused), p50/p95
  latency last hour, posts seen / surfaced today, LLM spend today (estimate from
  token counts).
- **Sound**: optional single chime on `NEW_EVENT` only, off by default.
- **Screen notifications**: optional system notification on `NEW_EVENT` only,
  off by default and remembered per browser. Ticking it asks for browser
  permission; if denied or unsupported it stays off with a short hint. Shown
  only while the page is hidden or unfocused; clicking one focuses the page.
  In the desktop app the same checkbox shows native system notifications
  (Tauri notification plugin); there, clicking one may not focus the window.
- SSE reconnects automatically; on reconnect, fetch `/notifications?since=<id>`
  to backfill anything missed.

## 11. Testing

Use the historical event sequences in `tests/fixtures/` to verify first
reports, duplicates, confirmations, corrections and unrelated commentary.
The [fixture notes](../tests/fixtures/README.md) document their provenance.
Exercise new sector behavior with representative inputs from that sector.

Required tests:

- `classify_tests.jac`: each fixture post's `materiality_score` lands on the
  expected side of the threshold; category matches. Analysis/recaps score < 50.
- `dedup_tests.jac`: sequences replay in order and produce the expected
  `NEW_EVENT / UPDATE / DUPLICATE` labels. The wire repost must be `DUPLICATE`;
  the official confirmation and the denial must be `UPDATE`.
- `adapters_tests.jac`: replies are dropped; quote tweets carry `quoted_text`;
  handle change with same ID is handled; unresolvable ID marks account inactive.
- A `replay` CLI (`jac run replay -- tests/fixtures/`) that pushes fixtures
  through the live pipeline at 10× speed so the UI can be exercised without
  live credentials.

Record LLM responses for fixtures with a cassette (`pipeline/llm.jac`,
`tests/cassettes/llm.json`) so the test suite (`jac test`) runs offline and
deterministically after the first recording.

## 12. Operational rules

- Never block ingest on the LLM. Persist first, classify async.
- Every LLM call logs: model, input tokens, output tokens, latency, post id.
- If the Anthropic API errors 3× in a row, switch to **fail-open**: surface
  every top-level post from `official` and `tracker` tier accounts unclassified,
  with a visible "unfiltered" badge, until calls succeed again.
- Daily read budget hit on X polling → pause that adapter, banner in UI, keep
  Telegram running.
- Log at INFO one line per post: `received | classified score=.. cat=.. |
  dedup=.. | latency=..s`. Debug logs include prompts/responses.

## 13. Roadmap

The [feature overhaul](feature-overhaul.md) orders the work and gives each
increment a review point. Public RSS summaries and community discussion are
launch priorities. Authorized structured X ingestion is optional.

## 14. Design decisions

Use one channel and item model across sources. Preserve source references,
collection and publication timestamps, and the distinction between an
editorial excerpt, authored post and AI-generated summary. Keep model/provider
settings and credentials on the server. Existing event UPDATE notifications
can re-enter the tray as smaller cards.

## 15. Demo acceptance

Two users on separate devices can use one hosted backend to publish,
discover, follow and discuss a channel. A corrected story can update its
cited summary. Repeated delivery produces no duplicate summary charge.
After a publisher or model outage, readers can still open the latest saved
edition and its source links. The full offline check covers existing behavior.

## 16. News-based trading

Trading analysis should identify the event, the affected instrument, the
reason it matters, and the period over which the idea applies. An ordinary
news item can remain a story without a signal. Every explicit trading signal
should retain its source links and distinguish the reported facts from the
author's or model's interpretation.

The existing backend stores a shared portfolio, quotes and suggestions for a
limited instrument set. It schedules a suggestion after an eligible new event
and requires a saved portfolio. Duplicate, unfiltered and failed classifications
do not generate suggestions. See [contracts](contracts.md) for the current
endpoints and `pipeline/trade.jac` for sizing, trigger and hold rules.

Generalized signal support across sectors is future work. For channels that
actually publish signals, a later paper-performance view can report hypothetical
results using stated entry, exit, sizing, fees, slippage and missing-price
assumptions. Part 1 covers navigation and layout only.
