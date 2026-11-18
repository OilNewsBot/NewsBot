# November feature audit verification

The [original audit](../2026-11-18-feature-audit.html) records 60 reproductions against `fce045f`. The audit rated 8 findings high, 33 medium and 19 low. Each area links to its regression evidence. The trading form continues to use a shared simulation portfolio, and identifies it before users enter balances.

| Audited area | Findings | Verification |
| --- | ---: | --- |
| News feed and alerts | 15 | [Browser, reconnect, and classifier-outage cases](news.md) |
| Accounts and My Sources | 9 | [Two-tab, registration, RSS, and X cases](accounts.md) |
| Trading | 14 | [Portfolio, provenance, keyboard, and chart cases](trading.md) |
| Ingestion and replay | 9 | [Durable ingestion and atomic recovery](pipeline.md) and [eight X, Telegram, and replay cases](adapters.md) |
| Installed web app and Web Push | 3 | [Deep links, offline navigation, and rate limiting](pwa.md) |
| Native mobile alerts | 5 | [Subscription and foreground delivery cases](mobile.md) |
| Windows desktop | 5 | [Native startup, connection, and recovery cases](desktop.md) |

## High-priority reproductions

| Original user impact | Result after the fix |
| --- | --- |
| Acknowledged outage alerts disappeared | All three unfiltered alerts remained in the feed after acknowledgment and reload. [News 1](news.md) |
| Reconnecting skipped alerts | The client retrieved all 205 stored alerts plus one concurrent live alert exactly once. [News 2](news.md) |
| A demo trade looked like a model recommendation | The seeded short shows its manual demo origin. [Trading 1](trading.md) |
| The entry form concealed the shared portfolio | The form explains who can see and change the balance before the first input. [Trading 2](trading.md) |
| Restarting dropped accepted posts | Three posts received while classification was blocked survived a worker restart. [Ingestion 1](pipeline.md) |
| Official X polling exceeded its daily allowance | The adapter reserves available reads before each request and pauses when it cannot fit a provider page. [Ingestion 2](adapters.md) |
| X bursts lost posts beyond the first page | After exhausting its allowance and restarting, the adapter delivered the entire 30-post burst in order. [Ingestion 3](adapters.md) |
| Telegram Bot ingested unselected channels | Only the selected channel reached the sink, including after its username changed. [Ingestion 4](adapters.md) |

The repository gate is `python3 scripts/check.py`. The linked records identify additional browser, native, and provider-fixture checks. Quota, provider error, delayed-response and permission tests use controlled responses so the cases are repeatable without live accounts.
