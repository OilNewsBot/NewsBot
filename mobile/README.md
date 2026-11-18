# NewsDrop mobile alerts

This iOS and Android companion delivers **shared market-event notifications** through Expo. The installed app is named **NewsDrop**. Its single switch controls push delivery to that installation. For account-specific channels, private sources, story watches and the personal briefing, open NewsDrop in a browser or the desktop app.

Notifications start off. The app stores the preference and a random installation secret in Expo SecureStore. Enable the switch and grant notification permission to register the phone with the backend. A pending change retries while the app is active or when it resumes. If a phone goes offline before disabling succeeds, system notification settings can silence delivery immediately.

## Backend setup

Run the NewsDrop backend with persistent SQLite storage and outbound HTTPS access to `exp.host`. Set these variables in the server environment or its ignored `.env`, then run `jac run` from the repository root.

```dotenv
NEWSBOT_MOBILE_PUSH=1
EXPO_ACCESS_TOKEN=
```

Set the server-only Expo access token when using enhanced push security. The backend exposes `PUT /mobile/subscription` when mobile push is enabled. Configure a reachable HTTPS address for the phone. If the feed is private, restrict enrollment through your access gateway or VPN. Registration grants access to shared alerts. NewsDrop account sign-in gates personal news separately.

The app sends `{"enabled":true,"token":"ExpoPushToken[...]"}` to enable delivery or `{"enabled":false}` to disable it. The bearer credential is a random installation secret. The server stores its hash. Re-registering the same installation handles a rotated Expo token.

## Configure and build the phone app

Use a supported Node release, such as Node 22.13+ in the 22.x line, and an Expo account. From `mobile/`, run

```sh
npm ci
cp .env.example .env
npx eas-cli@latest login
npx eas-cli@latest init
```

On Windows, `Copy-Item .env.example .env` creates the local config. Set the same values in the EAS build environment.

| Variable | Value |
| --- | --- |
| `EXPO_PUBLIC_API_URL` | HTTPS base URL of the running NewsDrop backend, reachable from the phone |
| `EXPO_PUBLIC_EAS_PROJECT_ID` | EAS project UUID |
| `NEWSBOT_IOS_BUNDLE_ID` | Your Apple bundle identifier |
| `NEWSBOT_ANDROID_PACKAGE` | Your Android application ID |
| `GOOGLE_SERVICES_JSON` | Path to Firebase's Android client configuration file |

`app.config.ts` maps the UUID into `extra.eas.projectId`. Choose your identifiers before creating credentials. The two `EXPO_PUBLIC_*` values are bundled into the app. Rebuild to change them.

- **Android.** Create the Firebase app with the same package ID and provide its client `google-services.json` to the build, for example with an EAS file variable. Upload the separate FCM v1 service-account credential through `npx eas-cli@latest credentials --platform android`. [Expo FCM setup](https://docs.expo.dev/push-notifications/fcm-credentials/)
- **iOS.** Configure signing, provisioning and APNs credentials with `npx eas-cli@latest credentials --platform ios`. Register devices for internal distribution, or distribute through TestFlight. [Expo push setup](https://docs.expo.dev/push-notifications/push-notifications-setup/)

Choose a profile from `eas.json`. A development build uses Metro, while a preview build is a standalone internal app.

```sh
npx eas-cli@latest build --profile development --platform all
npm start
```

```sh
npx eas-cli@latest build --profile preview --platform all
```

Use the `production` profile for a store build. Verify push on an installed app with the matching native credentials.

## Delivery and verification

Enabling or re-enabling starts after the latest saved notification ID. The worker reads new shared market-event cards and submits them to Expo for APNs or FCM. It records a delivery claim before sending and checks receipts for invalid tokens. It retries explicit rate limits and connection failures known to occur before submission. If an accepted request might have lost its response, the worker leaves the claim in place to limit duplicates. A phone can therefore miss an alert. The backend must stay running for ongoing delivery.

For offline checks, run the backend test from the repository root and the client checks from `mobile/`.

```sh
jac test mobile/tests/backend_tests.jac
cd mobile
npm run check
npm run export
```

To check native delivery, enable alerts on a physical phone and generate a new market event on a test backend. Check foreground and background delivery, then close the phone app and generate another event. Disable the switch, wait for it to sync, and confirm that a subsequent event stays silent. A successful Expo receipt records provider acceptance. [Expo delivery semantics](https://docs.expo.dev/push-notifications/sending-notifications/)
