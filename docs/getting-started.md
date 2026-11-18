# Run NewsDrop

NewsDrop runs one FastAPI service with a browser interface, a SQLite database and background workers. The seeded directory, accounts, subscriptions, discussions, story timelines and topic watches work without provider credentials. Normal operation refreshes public RSS over the internet.

## Start the service

From the repository root on Linux (x86-64 or ARM64) or Apple Silicon, run the following commands. The first installation needs internet access. The bootstrap helper checks the native Jac 0.37.25 release checksum and installs project dependencies. The server builds the browser interface on first use.

```sh
python3 scripts/bootstrap.py
export PATH="$HOME/.local/bin:$PATH"
jac run
```

On Windows, install Ubuntu in WSL2 and run these commands from PowerShell in the checkout. The helper installs Jac inside Ubuntu. If your distribution has a different name, set `NEWSBOT_WSL_DISTRO` for bootstrap and replace `Ubuntu` in the launch command.

```powershell
python scripts/bootstrap.py
wsl -d Ubuntu sh -c 'PATH="$HOME/.local/bin:$PATH" jac run'
```

Open [NewsDrop on localhost](http://127.0.0.1:8000). Open **Discover** to browse immediately, or use the sign-in link in the navigation to register or sign in. Keep the server terminal open. The Tauri desktop window uses the same web interface and can attach to an existing local service. [Desktop setup](../desktop/README.md)

## Try the bundled edition offline

After bootstrap and the first browser build, use a separate demo database and leave provider credentials unset in the environment and the checkout’s `.env`. Run the following in Linux, macOS or Ubuntu/WSL.

```sh
NEWSSTREAM_DB_PATH=data/newsstream-offline.db \
NEWSSTREAM_PUBLIC_RSS=0 NEWSSTREAM_SUMMARY_PROVIDER=disabled \
jac run
```

The bundled articles and their dates are available locally. You can publish a community channel, comment, follow topics and return to Home to read the briefing. Use the same database path to keep those accounts and channels across restarts. Leave private network sources disconnected for an offline session. Opening an external story or loading a social embed requires a connection.

## Operate a shared demo

Run one server process for the demo period. Give all devices the same HTTPS address and use the same persistent database on restart. Browser profiles can sign in as different people. The default database is `data/newsstream.db`, relative to the repository root.

| Setting | Use |
| --- | --- |
| `NEWSSTREAM_DB_PATH` | Set an absolute path on a persistent volume for the shared SQLite database. |
| `NEWSSTREAM_HOST`, `NEWSSTREAM_PORT` | Override the default listener at `127.0.0.1:8000`. A reverse proxy on the same host can use the loopback default. |
| `NEWSBOT_ADMIN_TOKEN` | Set a random server secret before exposing the service. This protects operator endpoints, including manual ingestion. |
| `NEWSSTREAM_PUBLIC_RSS` | Defaults to enabled. Set to `0` to pause all public RSS network refreshes and keep serving the saved articles. |
| `NEWSSTREAM_DEMO_RSS` | Set to `0` to skip feeds used only by bundled channels while continuing to refresh feeds used by reader-published channels. |

Terminate HTTPS at the reverse proxy and preserve the original host and scheme. Authenticated writes validate the origin, and HTTPS sessions get secure cookies. Keep environment secrets, SQLite files and provider sessions out of version control. The server reads settings from its environment and the root `.env`. [Configuration template](../.env.example)

A successful public RSS fetch schedules the next poll about fifteen minutes later. The worker shares each feed across its public channels, uses publisher cache validators and retains the last successful edition through a failure. A newly created RSS channel can be empty until its first fetch.

## Optional services

### Public AI summaries

For Anthropic, set `ANTHROPIC_API_KEY` on the server. The summary worker uses the configured small model slot unless you set `NEWSSTREAM_SUMMARY_MODEL`. For a Chat Completions-compatible service, use `NEWSSTREAM_SUMMARY_PROVIDER=openai-compatible`, set `NEWSSTREAM_SUMMARY_BASE_URL` to the API base and `NEWSSTREAM_SUMMARY_MODEL` to a model served there. Supply `NEWSSTREAM_SUMMARY_API_KEY` if the endpoint requires authentication. The backend sends the title, publisher and a bounded public excerpt.

`NEWSSTREAM_SUMMARY_DAILY_LIMIT` defaults to 40 reserved calls per UTC day, including possible retries. Results are cached per article revision, model and prompt version. By default, only RSS is eligible. `NEWSSTREAM_SUMMARY_SOURCES=rss,x,community` also permits deliberately published provider-supplied X content and authored community posts. To run on source text alone, set `NEWSSTREAM_SUMMARY_PROVIDER=disabled`.

### Private X connections

Public profile embeds work without credentials. To support personal TwitterAPI.io connections, set a stable `NEWSBOT_CONNECTION_KEY` on the server. It must encode 32 random bytes in URL-safe base64. Store it in a secret manager and keep it available across restarts. Each account supplies its own authorized provider credential in My Sources. The server encrypts that credential and applies the account’s provider budget.

### Private Telegram inbox

Use a dedicated Telegram bot. Set `NEWSSTREAM_TELEGRAM_BOT_USERNAME` and `NEWSSTREAM_TELEGRAM_WEBHOOK_SECRET` on the server. Use a random secret of 32–256 URL-safe letters, digits, underscores or hyphens. Using the bot token, register the HTTPS webhook with Telegram’s `setWebhook` method. Set `url` to `https://YOUR_HOST/api/telegram/updates`, `secret_token` to the same secret and `allowed_updates` to `["message"]`. Keep the bot token with the operator. A separate bot or client polling the same token can interfere with delivery. [Telegram Bot API](https://core.telegram.org/bots/api#setwebhook)

Once configured, readers pair their own Telegram account in My Sources, forward permitted text to their private bot chat and choose what to publish. The bot receives only the messages sent to it. Public Telegram links can be used independently. [Reader guide](feature-overhaul.md)

## Verify the installation

Run the full project checks from the repository root. Use `python` in native Windows PowerShell or `python3` in Linux, macOS and WSL. The helper disables public RSS refresh, masks live provider credentials, uses recorded model responses for application tests and builds the web client.

```sh
python3 scripts/check.py
```

For a shared-backend smoke test, use two browser profiles on the same server. Publish a community channel in the first profile. In the second, find it under **Discover → New channels**, follow it and turn on alerts. Publish a post from the first profile, then check Following and the channel discussion in the second. Restart against the same database and confirm both the post and the subscription are still present.
