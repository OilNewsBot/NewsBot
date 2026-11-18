# NewsDrop desktop

The Tauri app opens NewsDrop in a native window. Discover, My Sources, Following, story timelines and the home briefing use the same web interface and backend as the browser.

## Start the app from a checkout

Run the bootstrap command from the repository or worktree you want to open. On Windows, use PowerShell for the desktop commands. The backend runs in Ubuntu under WSL 2.

| Platform | Desktop prerequisites | Backend bootstrap |
| --- | --- | --- |
| Windows | Node.js, Rust with Visual Studio's Desktop development with C++ tools, WebView2, and Ubuntu in WSL 2 | `python scripts/bootstrap.py` |
| macOS on Apple Silicon | Node.js, Rust and Xcode command-line tools | `python3 scripts/bootstrap.py` |
| Linux | Node.js, Rust and the Tauri system libraries for your distribution | `python3 scripts/bootstrap.py` |

For platform setup, see the [NewsDrop setup guide](../docs/getting-started.md) and [Tauri prerequisites](https://v2.tauri.app/start/prerequisites/).

From that checkout's root, run

```sh
cd desktop
npm ci
npm run dev
```

The launcher reads `server.host` and `server.port` from the checkout's `config.yaml`. The default is `http://127.0.0.1:8000`. If a service is already listening, the launcher checks its NewsDrop API before connecting. An unrelated service on that port shows a setup error. Otherwise the launcher starts `jac run` in that checkout, waits for the port to open and navigates to Home. Quitting stops the server the launcher started. A separately started service continues running. External article links open in the system browser.

When trying a second worktree, check the port before launching. Two copies configured for the same port can display the same running server. Use distinct ports to keep both available, or quit the first instance before opening the second.

## Build a desktop bundle

In `desktop/`, install the JavaScript dependencies and build a bundle for the host platform.

```sh
npm ci
npm run build
```

The host platform's installers or app bundles appear under `src-tauri/target/release/bundle/` unless a custom Cargo target directory is configured. The installed launcher needs access to the backend checkout and its Jac dependencies when it starts a service. By default it uses the checkout it was built from.

Set `NEWSBOT_ROOT` to an absolute checkout path to select a different one. On Windows, supply a Windows path and set `NEWSBOT_WSL_DISTRO` if the backend uses a distribution other than `Ubuntu`. From PowerShell in the desired checkout, for example

```powershell
$env:NEWSBOT_ROOT = (Get-Location).Path
cd desktop
npm run dev
```

## Connect to a shared server

Set `NEWSBOT_URL` to the shared server’s HTTP or HTTPS origin when building the desktop app, or set it at launch to override the compiled value. The window connects to that server and retries automatically after a connection timeout. Desktop notifications work for that origin. [Hosted demo setup](../docs/demo-hosting.md)

## Notifications

In **Following**, enable alerts on individual channels. Open **Channel alerts** in the navigation to read new alerts or turn on **Screen notifications on this device**. In **My Sources**, each private feed or account has its own **Alerts** switch. **Private source screen notifications** applies while My Sources is open in the background. The operating system must allow notifications from the app. On macOS a development run can appear under Terminal in notification settings.

## Troubleshooting

| Symptom | Where to look |
| --- | --- |
| Wrong edition or another site appears | Check which service owns the configured port and which checkout `NEWSBOT_ROOT` selects. |
| The launcher cannot find the backend | Point `NEWSBOT_ROOT` to the directory containing `jac.toml` and `config.yaml`. |
| Jac or Ubuntu cannot be found | Run the bootstrap command for your platform. On Windows, compare `wsl -l -v` with `NEWSBOT_WSL_DISTRO`. |
| The server exits during startup | Read `data/desktop-server.log` in the selected checkout. Running `jac run` from the same checkout shows backend errors directly. |

Public RSS works without a visitor API key. Optional summaries, authorized provider connections and shared hosting use the backend's configuration. [Setup and hosting](../docs/getting-started.md)
