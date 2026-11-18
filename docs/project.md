# Newsstream implementation map

Newsstream serves a public news directory for Energy, Tech, Healthcare, Industrials, Consumer Discretionary, Materials, Utilities and Real Estate. The same backend handles channel publishing, private source management, discussion and subscriptions for every browser connected to it. The [channel and demo guide](feature-overhaul.md) describes setup and usage.

| Area | Entry points and responsibilities |
| --- | --- |
| Service | `main.jac` starts `app.jac`, which assembles FastAPI, cookie sessions, the web client and asynchronous workers. |
| Public channel catalog | `publicnews/` stores channels, story revisions, comments, click counts, subscriptions and recommendations in SQLite. It serves public reads and account-scoped writes. |
| Initial edition | `db/directory_seed.json` provides the dated publisher edition and source URLs. `db/directory.jac` loads prior saved editions and supports the editorial directory contract. |
| RSS and summaries | The public collector reuses the bounded fetcher and parser in `personal/providers.jac`. Public processing persists articles before summary generation. The separate `pipeline/forum_routing.jac` assigns sectors to multi-topic articles. |
| Private sources | `personal/` manages account-owned connections and delivery. `personal/publishing.jac` bridges explicitly selected material to a public channel. |
| Interface | `web/main.jac` selects the page. `web/directory.jac`, `web/navigation.jac` and `web/sources.jac` provide browsing and publishing. `jac build web` emits the assets served by FastAPI. |
| Market events and trading | `adapters/` and `pipeline/` implement market classification, clustering, notifications, quotes and suggestions. `db/repo.jac` stores these records and users/sessions. |
| Desktop and mobile | `desktop/` runs the web app in Tauri with a local backend. `mobile/` consumes market-event notifications through Expo. |
| Verification | `python3 scripts/check.py` runs the offline gate. Jac tests live in `tests/` and helper tests in `scripts/tests/`. |

## Operation

The supported topology is one FastAPI worker and persistent local SQLite storage. An HTTPS reverse proxy can give multiple devices a common address. Start the service with its working directory, model settings and secrets under the operator's control. Existing deployments can retain their database when adding public channel and private publishing tables.

Use a separate checkout or a temporary database for tests. Do not put real credentials, Telegram session files or runtime databases into Git. The [API contracts](contracts.md) describe the distinction between public, account-owned and administrative operations.
