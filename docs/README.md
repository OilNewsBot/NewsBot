# Newsstream documentation

## Using the app

| Guide | What it covers |
| --- | --- |
| [Product overview](spec.md) | Product goals, reader experience, source types and market-monitor capabilities |
| [Reader guide](feature-overhaul.md) | Discover, channel publishing, topic and story follows, briefings, alerts and discussions |
| [Source catalog](default-sources.md) | The default RSS editions and X accounts, their sector coverage and publisher links |
| [Personal sources](personal-sources.md) | Private feeds, credentials, collection settings, keyword alerts and selective sharing |

## Running Newsstream

| Guide | What it covers |
| --- | --- |
| [Setup and hosting](getting-started.md) | Local installation, Windows/WSL, offline operation, shared hosting, summary providers and Telegram pairing |
| [Desktop app](../desktop/README.md) | Starting and packaging the Tauri window, choosing the checkout and connecting to the local service |
| [Mobile alerts](../mobile/README.md) | Configuring the Expo client and delivering market-event push notifications |
| [Replay fixtures](../tests/fixtures/README.md) | Exercising the market-event pipeline with repeatable example sequences |

## Inside the service

| Reference | What it covers |
| --- | --- |
| [Architecture](project.md) | The web client, authentication, SQLite storage, collection, story updates and per-account visit tracking |
| [API contracts](contracts.md) | Public, account-owned and administrative endpoints, source data, event streams and cursors |
