# NewsStream PWA and personal Web Push

## Run locally

From the repository root, use the pinned Jac runtime and a loopback origin.
Use the same hostname and port for each visit. `localhost` and `127.0.0.1`
are different browser origins.

```sh
python3 scripts/bootstrap.py
jac build web
jac run
```

On the verification Mac, the pinned Jac binary needed a writable cache
and the installed Homebrew Expat library. If you see a runtime cache error
or a missing `XML_SetAllocTrackerActivationThreshold` symbol on that Mac,
set these in each terminal before running Jac or its Python environment.

```sh
export JAC_CACHE_HOME=/private/tmp/newsbot-pwa-jac
export DYLD_LIBRARY_PATH=/opt/homebrew/opt/expat/lib
```

Open <http://localhost:8000/sources> and sign in. In a browser that exposes an
install prompt, select **Install NewsStream** in My Sources or use the browser
menu. The installed app starts at My Sources. The standard responsive web UI
serves as the app. A disconnected navigation shows a small offline page.

Generate the VAPID key once before starting the server. In macOS, Linux, or
WSL, the following appends a new private key to the ignored server `.env`.
If the server already has a key, keep that key.

```sh
umask 077
touch .env
.jac/venv/bin/python -m pwa.transport >> .env
```

Add `NEWSBOT_VAPID_SUBJECT=mailto:your-real-contact@example.org` to `.env` and
restart `jac run`. The application derives the public P-256 key from the private
key. It exposes the public key through the signed-in Web Push status request.
Keep the private key, SQLite database, and browser endpoints out of Git and
client configuration. Rotating the key requires users to enable Web Push again.

In **My Sources → Latest news**, select **Enable Web Push** and allow the
browser prompt. Enable it separately in each browser profile or installed app.
Use **Disable Web Push** to revoke and unsubscribe this installation. The
source’s **Notify me about new posts** setting controls that source on all
devices. The existing screen notifications checkbox still applies to the
open page when Web Push is inactive on that device.

The worker is served at `/newsstream-sw.js` with scope `/`. It uses ordinary
service-worker activation. Close the origin's open tabs and installed windows
to release an old worker during an update. DevTools → Application shows the
manifest, icons and worker. Cache Storage should have no NewsStream caches.

### Repeatable simulated event

For the automated check, the repository's Kharg news fixture enters the
existing personal collector using a fixture-backed provider. The suite
checks the normal alert rule and personal records, then captures delivery
attempts with a mock push transport. Separate tests check encryption against
the RFC vector and verify the Web Push request with an HTTP mock.

```sh
NEWSSTREAM_CASSETTE_MODE=replay jac test tests/web_push_tests.jac
.jac/venv/bin/python -m unittest discover -s tests -p pwa_transport_test.py -v
node --test tests/pwa_worker_test.cjs
python3 scripts/check.py
```

For a browser demonstration, use the isolated loopback demo server on port
8011. It uses `data/pwa-demo.db`, runs the existing account UI, and suppresses
live collection and Expo. Supplying VAPID configuration enables actual browser
push attempts. Without VAPID configuration, the personal feed and in-page
alerts still demonstrate filtering.

```sh
jac run pwa/demo.jac -- serve
```

1. Open <http://localhost:8011/sources> in three regular browser profiles
   (two for Alice and one for Bob). Register `alice@example.test` and
   `bob@example.test` using the existing form and sign in. Use a local demo
   password of at least 12 characters.
2. In a second terminal, add different fixture sources for the two accounts.
   The command initializes their polling baselines silently.

   ```sh
   jac run pwa/demo.jac -- seed --alice alice@example.test --bob bob@example.test
   ```

3. Reload My Sources and enable Web Push in all three profiles. Background
   or close their NewsStream windows while leaving the server running.

   ```sh
   jac run pwa/demo.jac -- emit --alice alice@example.test --bob bob@example.test 9002000001
   ```

4. The first Kharg report enters Alice's source and matches her include
   keyword. Only Alice's profiles are eligible for a notification. Bob
   follows another source. Tap an alert to go to the article in My Sources
   if it is still in the current feed.
5. Repeat the same command and restart the demo server. The notification
   head stays the same and the same alert is never submitted twice. To test
   muting, turn off Alice’s alerts for the fixture source and emit
   `9002000002` instead of `9002000001`. That post appears in her feed
   without advancing the personal notification head. Unmute, disable or sign
   out one Alice profile, then emit `9002000005`. Only the remaining active
   Alice profile is eligible. Each fixture post creates at most one personal
   notification per subscribed source. Use fresh demo accounts to run the
   sequence from the beginning again.

The same fixture collection uses the repository’s replay loader. The legacy
`jac run replay -- tests/fixtures/ --preserve-timestamps` command exercises
the shared classifier and feed through local `/ingest`. Personal RSS and X
already use a separate collector and keyword filter. Routing legacy classifier
cards into personal push would require new per-account matching rules, so the
PWA subscribes exclusively to the existing personal records.

## Future JacHammer sandbox configuration

JacHammer documents one sandbox deployment on its Free plan. Use that free
allocation only if the sandbox can run a pinned Jac CLI entry point with
secrets and a persistent process. Verify these capabilities and the sandbox
expiration before relying on it. [JacHammer plans](https://docs.jachammer.ai/introduction/plans-billing)

Expected build and start from the project root.

```sh
python3 scripts/bootstrap.py
jac build web
jac run
```

| Runtime setting | Value |
| --- | --- |
| Jac | `0.37.25`, the native binary with pinned dependencies |
| `NEWSBOT_PUBLIC_PWA` | `1` to bind the app publicly behind the HTTPS proxy and enable hosted route protections |
| `PORT` | Port forwarded by the platform, or `8000` |
| `FORWARDED_ALLOW_IPS` | The trusted proxy address or network supplied by the host |
| `NEWSBOT_VAPID_PRIVATE_KEY` | Private key from the generator, stored as a server secret |
| `NEWSBOT_VAPID_SUBJECT` | `mailto:` followed by a real contact address |
| Feed, LLM and Expo credentials | Leave unset for a no-cost demo |

Use a top-level HTTPS origin at the domain root. The frontend and API use
the same origin, with no client API URL or CORS configuration needed.
Preserve the external Host, forward `X-Forwarded-Proto: https` from the trusted
proxy, and keep the backend listener private to that proxy. This also lets
the existing login handler set a Secure, HttpOnly session cookie. Hosted
mode blocks `/ingest` and requires authentication for `/refetch` and the
legacy feed and trading APIs. Keep the sandbox’s demo database separate from
real accounts and data. Run one application instance and give it writable
storage for `data/newsstream.db` and the web build. An ephemeral filesystem,
sleeping worker, changed HTTPS origin or unavailable outbound push endpoints
will interrupt delivery or require re-registration. A sandbox that only
serves a static bundle or runs a generated Jac server cannot run this FastAPI
application without a custom start command.

Open the external top-level URL on the device. An embedded preview, mobile
device access to an HTTP LAN IP, or a browser with install/Push API disabled
cannot validate this flow. No JacHammer services are needed for local tests.

## Physical-device checks

- **Android**. Open the HTTPS URL in Chrome, install from the menu or the
  My Sources control, then open the app from the launcher. Sign in, enable
  Web Push, send a post from a followed source, and confirm the OS prompt
  and alert while the app is closed. Tap the banner and check the linked
  item. Turn Web Push off and confirm the next post produces no banner.
- **iOS or iPadOS 16.4+**. In Safari, use **Share → Add to Home Screen**.
  Launch the standalone app, sign in and use the **Enable Web Push** button.
  With the app closed, check the banner and its tap destination, then switch
  accounts and verify the old account's next eligible event is suppressed.
  Standards-based Web Push needs no Apple Developer membership. [WebKit's iOS and iPadOS guide](https://webkit.org/blog/13878/)
- Use a second signed-in device for Alice and one for Bob. Follow different
  feeds and use a controlled new qualifying post. Verify both Alice devices
  receive it, Bob's device stays quiet, and replaying the same post stays quiet.
  A public RSS source can be used without a paid news API. Wait for its
  first successful poll to seed the baseline before publishing the next post.

## Delivery and API behavior

- The server fans out a committed personal notification only after verifying
  the active session, owner, and source eligibility. It claims each
  subscription/notification pair durably before attempting delivery. Each
  request carries only an encrypted random receipt. The worker checks that
  receipt against the current account before display and again before
  navigation. The resulting banner contains generic text. A browser may
  display its own generic fallback when an already queued push arrives
  after revocation.
- The same browser must opt in again after logout, a session expiring (seven
  days), or an account switch. Other sessions on the account stay enabled.
  Invalid endpoints are removed on 404 or 410. The endpoint validator limits
  outbound requests to known browser push service domains and disables
  redirects. Changed browser subscriptions may need to be enabled again.
- New subscriptions skip existing history. Workers consider alerts created
  during the previous five minutes and request a five-minute provider TTL.
  An ambiguous response or crash after the claim can lose a banner. The
  original post remains in My Sources. An explicit rate-limit refusal schedules another attempt while the alert is fresh. Older alert links also load the addressed article outside the latest feed window. If it is unavailable, My Sources explains that the article is unavailable.
- The authenticated, same-origin, no-store API is under `/api/me/web-push`.
  `POST /status` accepts an optional endpoint and returns a public key, an
  opaque session binding and the device state. `PUT /subscription` accepts the
  browser subscription and binding. `DELETE /subscription` accepts endpoint
  and binding. `POST /destination` resolves an opaque receipt for its session.
  A subscription or receipt conveys no authority over another session.
