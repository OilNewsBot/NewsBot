# NewsBot mobile

A one-toggle React Native / Expo app for iOS and Android. Notifications are off
initially. Expo SecureStore preserves the preference and a random installation
secret; the app handles permissions, token changes, and pending offline changes.

## Integration boundary

The only modification to existing team code is **two added lines in `app.jac`**:

```jac
import from mobile.push { install_mobile }
// immediately after FastAPI(...) is constructed:
install_mobile(app, repo);
```

Everything else is in `mobile/`. The hook does nothing unless
`NEWSBOT_MOBILE_PUSH=1`. When enabled, it adds one subscription route and wraps
startup/shutdown to run the mobile worker inside the original app lifecycle.
It does not change ingestion, classification, website/desktop code, `/stream`,
`/notifications`, existing table definitions, or their payloads.

`pipeline/notify.jac` already saves notification cards. The mobile worker reads
those same records and sends their existing `notification_id` through Expo to
APNs/FCM. Visible pushes appear through the OS while the app is backgrounded or
terminated; the phone does not keep an SSE connection or poll for news.

## Backend configuration

Use the normal NewsBot startup command, `jac run`, and set the variables documented
in `backend.env.example` in the backend environment or its existing untracked `.env`:

```dotenv
NEWSBOT_MOBILE_PUSH=1
EXPO_ACCESS_TOKEN=
```

The Expo access token is server-only and is required if you enable Expo enhanced
push security. Never put it in the phone app or an `EXPO_PUBLIC_*` variable.

Keep the backend running with persistent SQLite storage and outbound HTTPS access
to `exp.host`. Expose `PUT /mobile/subscription` over HTTPS to the phone through a
reverse proxy or private VPN. Phone `localhost` is not your computer. Do not expose
administrative endpoints such as `/ingest` merely to make registration reachable.
Apply request-size and registration rate limits at the proxy.

Registration accepts `{"enabled": true, "token": "ExpoPushToken[...]"}`; disabling
needs only `{"enabled": false}`. The app supplies `Authorization: Bearer <random
64-character hex secret>`. Only its hash is stored by the server. All installations
receive the existing shared feed: this secret protects an installation's settings,
not account-level news access. Restrict enrollment through your VPN/access gateway
if the feed is private. With mobile push disabled the route is absent (404).

## Phone configuration and builds

Use Node 22.13+ and an Expo account. From `mobile/`:

```sh
npm ci
cp .env.example .env
npx eas-cli@latest login
npx eas-cli@latest init
```

Set these values locally and in the EAS build environment:

| Variable | Value |
| --- | --- |
| `EXPO_PUBLIC_API_URL` | This backend's HTTPS base URL |
| `EXPO_PUBLIC_EAS_PROJECT_ID` | EAS project UUID from `eas init` |
| `NEWSBOT_IOS_BUNDLE_ID` | Your unique Apple bundle identifier |
| `NEWSBOT_ANDROID_PACKAGE` | Your unique Android application ID |
| `GOOGLE_SERVICES_JSON` | Path to Android's client `google-services.json` |

`app.config.ts` reads these variables. If `eas init` asks for manual configuration,
put its UUID in `EXPO_PUBLIC_EAS_PROJECT_ID`; the config already maps it to
`extra.eas.projectId`. Replace the `com.example.newsbot` defaults before creating
credentials. Public variables are bundled into the app; rebuild after changes.

- **Android:** Create a Firebase Android app matching your package ID. Download
  its client `google-services.json`. For EAS builds, provide it through an EAS file
  environment variable named `GOOGLE_SERVICES_JSON` (the local file is Git-ignored).
  Upload the separate **FCM v1 service account key** through
  `npx eas-cli@latest credentials --platform android`. That private key stays in
  EAS, never in the app. See [Expo FCM setup](https://docs.expo.dev/push-notifications/fcm-credentials/).
- **iOS:** Use an Apple Developer account, matching bundle ID, signing/provisioning,
  and APNs credentials configured through `npx eas-cli@latest credentials --platform ios`.
  Register devices for internal builds, or use TestFlight. See
  [Expo push setup](https://docs.expo.dev/push-notifications/push-notifications-setup/).

```sh
# Development build; run npm start for Metro afterward.
npx eas-cli@latest build --profile development --platform all
npm start
# Standalone internal builds for closed-app tests (no Metro required).
npx eas-cli@latest build --profile preview --platform all
# Store/TestFlight builds when ready.
npx eas-cli@latest build --profile production --platform all
```

Use installed builds, not Expo Go, for remote push testing. Account membership,
signing, distribution, and build costs depend on your accounts/plans.

## Delivery behavior

- New/re-enabled subscriptions start after the latest saved notification ID,
  avoiding historical alerts. Repeated registration and token rotation preserve
  pending work. NEW_EVENT, UPDATE, and UNFILTERED cards are supported.
- A unique `(installation, notification_id)` claim is saved before submission.
  The foreground handler also remembers the last 100 IDs and never creates a
  second local notification. No delivery-status history or dashboard is maintained.
- Explicit HTTP 429 refusals and connection-establishment failures retry with
  backoff. Ambiguous submission errors or a crash after claiming are not retried,
  to avoid duplicate alerts. An alert can therefore be missed, but its original
  card remains on the website. Expo/APNs/FCM do not guarantee exactly-once delivery.
- A small receipt check handles invalid tokens, including errors received after
  submission. Old-token errors cannot disable a replacement token. Receipt success
  is provider acceptance, not proof of phone display. See [Expo delivery semantics](https://docs.expo.dev/push-notifications/sending-notifications/).
- Offline toggle changes show **sync pending** and retry while the app is active
  or on resume. Until disable reaches the server, closed-app alerts may continue;
  phone Settings can block them immediately. Already submitted pushes cannot be
  recalled. Revoked permissions are reconciled when the app next runs.
- Connectivity, Focus, battery settings, and Android Force stop can prevent or
  delay delivery. Reopen after Force stop. The backend must remain running even
  when the phone app, website, or desktop window is closed.

## Verification

All new tests stay in `mobile/`; the team's CI, checker, and tests are unchanged.
From the repository root, run the existing suite plus the mobile backend tests:

```sh
NEWSBOT_MOBILE_PUSH= EXPO_ACCESS_TOKEN= python3 scripts/check.py
jac fmt --check mobile/push.jac mobile/tests/backend_tests.jac
NEWSBOT_MOBILE_PUSH= EXPO_ACCESS_TOKEN= jac test mobile/tests/backend_tests.jac
cd mobile
npm run check
npm run export
```

Backend tests use temporary databases and an offline Expo stub. They verify the
existing notify/SSE/backfill path, registration, restart deduplication, multiple
phones, disabling, safe retries, receipts, and original lifecycle preservation.
The mobile tests cover permissions, persistence, token rotation, offline changes,
and foreground deduplication. Export builds both platforms' JS bundles, not signed
native applications.

On each physical platform, configure credentials and install a standalone build.
Enable notifications and trigger an event on a test backend; check exactly one
alert in foreground, background, locked, and normally terminated states. Restart
the backend/app and check old IDs do not alert again. Disable and generate another
event; re-enable and check disabled-period events do not backfill. Also test denied
and revoked permissions, offline toggles, and two independently registered phones.
Actual device delivery cannot be established by offline tests alone.
