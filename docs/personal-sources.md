# Personal sources, first release

Open **My Sources** (`/sources`) and sign in with a Newsstream account. Add an RSS
connection or a TwitterAPI.io connection, then add feeds or X handles/profile
URLs. Each account has its own connection list, sources, feed, filters and alerts.
The page works in the website and the existing desktop webview.

RSS supports public RSS 2.0, Atom and RDF feeds. X uses TwitterAPI.io REST polling
with the user's own API key. This is a TwitterAPI.io connection, not X OAuth.
The first release checks RSS no more often than every five minutes and X no more
often than every minute; polling, backoff and available request budget affect
actual latency. There is one in-process personal worker per backend instance.
Run one server worker against a database; distributed worker leases are not
implemented in this release.

## Using the page

1. Add a connection. RSS needs a name; X also needs a TwitterAPI.io key and a daily
   request limit. Connection creation saves credentials; the first source lookup
   or successful poll verifies that X can access the requested data.
2. Add a feed URL or X account through that connection. Sources use stable
   provider identity, so display-name changes do not create another source.
3. Choose optional include/exclude keywords. Include matches any listed keyword;
   exclude vetoes a match. Matching is case-insensitive text matching. These rules
   govern alerts; the feed retains collected posts for inspection.
4. Mute alerts to continue collecting silently, pause to stop collecting, or
   remove the source. Re-enabling collection seeds recent history silently.
5. Enable browser notifications if desired. The source page must remain open
   and the browser must allow notifications. In-page alerts work without OS
   notification permission. A fresh page session starts at the current alert
   head, so saved history does not flood the screen; temporary stream reconnects
   replay missed alerts by ID.

New sources load their initial history without notifications. Repeated provider
messages are deduplicated, and edits update the saved item without another alert.
Unmuting or resuming does not replay earlier alerts. Removing a source/connection
hides its items and cancels future eligible delivery; stored history is retained
in the private database tables. A future retention/deletion policy can purge it.

The legacy Oil feed and Trading page use their original shared dataset. Personal
source posts never enter their classifier, event summaries, SSE stream or Expo
mobile worker. Account-specific phone pairing/push and personal Telegram sessions
are subsequent releases. Personal alerts in this release are web/desktop alerts.

## Server setup

Use the pinned Jac runtime and install dependencies as usual:

```sh
python3 scripts/bootstrap.py
jac run
```

For personal X connections, generate a random encryption key once:

```sh
python3 -c "import base64,secrets; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())"
```

Save it as `NEWSBOT_CONNECTION_KEY` in the server's ignored `.env` or secret
environment. Keep it stable across restarts, and back it up separately from the
database. Losing/changing it requires users to reconnect their X credentials.
RSS works without this key. Never put it in frontend configuration or Git.

Use a separate TwitterAPI.io key from the server's legacy `X_PUSH_API_KEY`.
Duplicate personal keys are rejected to keep ownership and budgets unambiguous.
No personal connector creates, changes or deletes TwitterAPI.io filter rules or
opens a WebSocket. API keys are encrypted with AES-GCM and bound to the owning
user and connection; list responses and error messages exclude credentials.

The default cap is **200 X requests per connection per UTC day**, not a dollar
or tweet cap. A provider response may contain multiple billed posts. Source
resolution and each paginated polling request consume a request. Multiple sources
share their connection's cap, so continuous minute polling can exhaust the
default cap before the day ends. Configure a limit appropriate to the user's
provider plan; review provider pricing independently. A limit or credit failure
pauses the connection without stopping other users' sources.

The server must remain running to collect news. The desktop currently starts a
local backend that stops when it closes. Always-on hosting and remote desktop
configuration are separate deployment work. If hosting, use HTTPS, configure the
reverse proxy correctly, and do not publicly expose legacy administrative routes
(`/ingest`, `/refetch`) or assume the legacy shared portfolio is account-specific.
Session cookies are marked Secure on HTTPS requests. Personal mutations check
same-origin requests, and all personal reads require the session's owner.

## Implementation boundaries

- `personal/store.jac` and `personal/schema.sql`: additive, versioned `personal_*`
  tables; the legacy tables and their IDs are preserved. Sources belong to
  connections and users. Items are unique by `(source_id, external_id)`.
- `personal/secrets.jac`: encrypted provider credentials; no plaintext fallback.
- `personal/providers.jac`: bounded RSS fetch/parsing and fixed X endpoints.
  RSS requests reject local/private/reserved network addresses, pin the resolved
  public IP, validate each redirect and limit response size/time. XML parsing
  disables entity expansion. Browser content is text, not trusted feed HTML.
- `personal/worker.jac`: due-source scheduling, request budgets, provider retries
  and durable checkpoints. Source changes apply without restarting the backend.
- `personal/api.jac`: account-scoped CRUD, private feed/history and SSE replay.
- `web/sources.jac`: setup, source controls, private feed and browser alerts.

Items, matching notification intent and the provider checkpoint commit in one
transaction. Read queries use a separate read-only connection so live delivery
cannot observe uncommitted records. The personal stream rechecks the session and
source eligibility; logout/account switching clears client state. There is no
LLM call in this pipeline and no shared event-summary cache containing private
posts. Pauses, deletion, and permission checks also apply to in-flight collection.

## Verification

```sh
python3 scripts/check.py
```

Tests use temporary databases, sample credentials and mocked provider responses.
They cover cross-account reads/mutations, RSS network restrictions, XML parsing,
X identity/pagination/budget behavior, encrypted-key failures, baseline history,
duplicate/restart recovery, mute/pause/revoke behavior and authenticated SSE.
Provider connectivity and browser permission prompts additionally need a manual
smoke test with user-supplied credentials; offline tests do not establish live
provider availability.
