# Newsstream

Newsstream is a shared news and discussion service for people following Energy, Tech, Healthcare and Industrials. Open Home to browse the sectors or Discover to see the channel directory. Each channel has a shareable address, source information, recent updates and a discussion. Sign in to publish channels, follow them and recommend sources.

## Run locally

Newsstream uses the native Jac 0.37.25 binary, FastAPI and SQLite. Install the pinned runtime and dependencies with the repository helper. On native Windows run the helper with `python`. Run the Jac commands in Ubuntu/WSL.

```sh
python3 scripts/bootstrap.py
jac run
```

Open [Newsstream on localhost](http://127.0.0.1:8000). The initial edition includes genuine, dated publisher stories. A background worker refreshes the public feeds automatically. Public RSS and browsing work without a provider key. A shared demo uses one running backend, one database on persistent storage and a single HTTPS URL for all devices.

## Sources

| Source | How readers use it |
| --- | --- |
| RSS | Publish a public feed URL. Newsstream collects items, preserves publisher links and can generate attributed summaries. |
| X | Publish an official profile timeline embed or select a post from an authorized personal provider connection. A reader can open the profile directly. |
| Telegram | Embed a public post or pair a Telegram account through the demo bot. The account holder chooses a permitted message and explicitly publishes it. |
| Community | Publish original posts with an optional source link. Readers can discuss individual posts or the channel itself. |

Private connections and provider credentials belong to the signed-in account. Source collections, provider limits and AI settings are managed on the server.

## Development

```sh
python3 scripts/check.py
```

The check runs helper tests, formatting, type checking, offline application tests and the web build. It masks live credentials and disables feed refresh. `jac build web` builds the browser client. `jac run replay -- tests/fixtures/` exercises the separate market-event monitor on a running service.

See the [channel and demo guide](docs/feature-overhaul.md), [project map](docs/project.md), [API contracts](docs/contracts.md) and [documentation index](docs/README.md). The [desktop guide](desktop/README.md) covers the Tauri wrapper. The [mobile guide](mobile/README.md) covers the existing market-event push client.
