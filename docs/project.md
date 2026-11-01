# Current NewsBot / Newsstream project

Newsstream monitors configured Telegram and X sources, classifies relevance to
crude-oil markets, groups related posts into events, and displays new events and
material updates in a local browser UI. The project uses **Jac 0.37.25**. The
existing [specification](spec.md) describes intended behavior and the roadmap;
this page maps the implementation as inspected for the collaboration setup.

## Code map

| Area | Implementation |
| --- | --- |
| Entry and service | `main.jac` calls `app.jac`: FastAPI, uvicorn, asynchronous adapter/pipeline tasks |
| Configuration | `config.jac` loads `.env` and `config.yaml` into Settings; model defaults and spend estimates live here |
| Ingestion | `adapters/base.jac` defines normalized posts; Telegram, TwitterAPI.io push, and official X polling have separate adapters |
| Processing | `pipeline/runner.jac` persists, classifies, deduplicates/clusters, and notifies; the other pipeline modules implement those steps |
| Model boundary | `pipeline/llm.jac` wraps Anthropic, JSON parsing/retry, failure tracking, logging, and cassette record/replay |
| Trading | `pipeline/trade.jac` suggests a WTI/RBOB trade after each `NEW_EVENT` (background task); `pipeline/prices.jac` reads Yahoo Finance 1-minute prices; `web/trading.jac` is the `/trading` page (spec §16) |
| Persistence | `db/schema.sql` and `db/repo.jac`, SQLite through aiosqlite |
| Browser | `web/main.jac` and `web/main.css`, built by `jac build web` into `.jac/client/web/dist/index.html` |
| Desktop | `desktop/` is a Tauri window that starts `jac run`, shows `/`, and stops the service on quit; see its README |
| Replay | `replay.jac` sends fixture posts to a running service's `/ingest` endpoint |
| Verification | Jac tests under `tests/`; Python collaboration tests under `scripts/tests/`; one combined CI entry point |

```text
Telegram / X → normalized post → persist → classify → cluster → notification
                                   ↓          ↓          ↓          ↓
                                 SQLite   decisions    events    SSE → UI
```

Each worktree gets its own relative runtime database and build output. The
default database is `data/newsstream.db`; the default server is `127.0.0.1:8000`.

## Behavior to preserve

- Persist raw input before model work; duplicate `(source, source_post_id)` inputs
  do not produce duplicate processing.
- Rubric scoring determines materiality. Near-threshold posts use the review
  model; accepted posts proceed to event clustering.
- Clustering produces `NEW_EVENT`, `UPDATE`, or `DUPLICATE`. Duplicates remain
  auditable but do not create another notification.
- Failure paths surface visible error/unfiltered information according to the
  spec rather than silently losing input.
- Stable account IDs identify sources; handles are display/configuration data.
- Official X polling respects its configured daily budget; third-party push
  and Telegram have their own adapter lifecycle/status.
- The browser receives notifications over SSE and backfills on reconnect.

## Configuration and local state

`config.yaml` contains accounts/channels, thresholds, rubric weights, adapter
options, UI settings, and server settings (`host`, `port`, `db_path`). `.env`
contains credentials and optional `TRIAGE_MODEL`/`REVIEW_MODEL` overrides. Secrets
are ignored by Git. The source integration defaults to Telegram plus third-party
X push, with official X polling disabled unless configured.

Live operation can consume provider credits or create vendor-side subscriptions
and rules. For routine development leave keys absent. Coding-agent subscriptions
are separate from the application's Anthropic API credentials. Existing README
prices/model IDs are historical project assumptions; verify provider documentation
when making changes rather than presenting them as current pricing.

## Tests and replay

`tests/adapters_tests.jac`, `classify_tests.jac`, and `dedup_tests.jac` include
scripted StubLLM logic tests and cassette-backed model behavior cases.
`tests/helpers.jac` uses a temporary database and pins the threshold for fixtures.
Fixtures contain reconstructed wording; [their README](../tests/fixtures/README.md)
explains provenance. They are not verbatim archived platform posts.

`python3 scripts/check.py` runs Python tooling tests, `jac fmt --check` with explicit source paths, `jac check`,
`jac test`, and `jac build web`. It masks live credentials and model overrides,
uses serial cassette replay, and rejects missing/empty cassette data. Plain
`jac test` can record missing model responses when a key is present; use the
wrapper for normal checks. Cassette regeneration is a separate intentional,
serial operation with reviewed fixture/prompt changes.

`jac run replay -- tests/fixtures/` exercises a running server, not the test
harness. By default it rewrites timestamps to the present, which changes model
prompt keys. Do not assume that turning on cassette mode makes every arbitrary
UI replay hit recorded responses. Without credentials, expect failure/unfiltered
paths instead of claiming a live classification demonstration.

## Current boundaries and follow-up areas

This is a local single-process service. In-process SSE queues are not a distributed
message bus. `schema.sql` uses create-if-absent statements; existing databases do
not gain altered columns automatically, so schema evolution needs a migration
plan. The app builds a missing/stale UI on startup and returns 503 if the page
cannot be built. Preserve the pinned runtime's documented import workarounds.

The current test files focus on adapters/classification/clustering. Full browser
interaction and live integration behavior need additional checks when those
areas change. Product latency figures in the spec are targets, not measurements
verified by this setup. Multiple markets, discovery, and other future features
remain roadmap items unless explicitly requested.
