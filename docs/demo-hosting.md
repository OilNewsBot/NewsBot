# Hosting a demo from one Mac (Tailscale Funnel)

For a short live demo: one Mac runs the normal NewsBot server, Tailscale Funnel
gives it a public HTTPS address, and the audience uses that address in a browser
or in a desktop app built to open it. API keys stay on the host Mac.

Why one server: twitterapi.io allows one live connection per key, and its filter
rules are per key, so every attendee running their own server would fight over
the feed. Keys inside a downloadable app could also be extracted.

## One-time setup (host Mac)

1. Install Tailscale from the Mac App Store or https://tailscale.com/download
   and sign in. In the menu bar app, open **Settings** and install the
   **command-line** tool, so `tailscale` works in Terminal.
2. Run `tailscale funnel 8000` once. The first time, it prints a link to turn
   on HTTPS certificates and Funnel for your tailnet; approve it, then press
   Ctrl+C. Your public address is `https://<machine>.<tailnet>.ts.net`
   (`tailscale funnel status` shows it).
3. In the NewsBot `.env`:
   - `NEWSBOT_ADMIN_TOKEN`: required before going public; it locks `POST
     /ingest`. Generate with
     `python3 -c "import secrets; print(secrets.token_urlsafe(32))"`.
   - Demo-only `ANTHROPIC_API_KEY` and `X_PUSH_API_KEY`. No other server
     (yours or a teammate's) may use the same twitterapi.io key while the demo
     runs, or the two keep disconnecting each other.

Attendees who sign up get accounts in the host's database, and demo tweets
become events there. To keep that separate from your everyday data, host from
a second checkout (`git worktree add ../NewsBot-demo main`, copy `.env`, run
`python3 scripts/bootstrap.py` there); each checkout has its own `data/`.

## Demo day

```sh
cd ~/NewsBot                       # or the demo checkout
caffeinate -dims jac run           # the server; keeps the Mac awake while it runs
tailscale funnel --bg 8000         # in a second terminal: publish it
```

Quit the NewsBot desktop app first if it is running its own server. Check the
address from a phone on cellular data: the sign-in page should load.

To show significant events when real news is quiet:

```sh
jac run fake_tweets -- --remote https://<machine>.<tailnet>.ts.net
```

It reads the token from `.env` and sends five scripted tweets when you press
Enter.

Afterwards: `tailscale funnel --bg off`, stop the server, and revoke the demo
keys.

## The attendee desktop app

Build the app with the address baked in. It then opens that server and starts
nothing locally, so attendees need no NewsBot folder, Jac, or keys:

```sh
cd desktop
NEWSBOT_URL=https://<machine>.<tailnet>.ts.net npm run build
```

- The Mac build is `src-tauri/target/release/bundle/dmg/NewsBot_*.dmg`. It is
  for the CPU it was built on. For both Apple silicon and Intel Macs, run
  `rustup target add x86_64-apple-darwin aarch64-apple-darwin` once, then add
  `-- --target universal-apple-darwin` to the build command.
- Windows attendees need a build made on a Windows machine with the same
  `NEWSBOT_URL`.
- The app is unsigned. On Mac, attendees right-click it and choose **Open**
  the first time. On Windows, choose **More info → Run anyway**.
- Desktop notifications work as in the local app. Setting `NEWSBOT_URL` in the
  environment at run time overrides the built-in address.

A browser is the zero-install alternative: share the same address.
