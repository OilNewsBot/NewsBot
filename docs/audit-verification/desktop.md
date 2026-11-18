# Windows desktop startup

The five cases below use the Windows Tauri release and an isolated WebView2 profile per launch. Each fixture serves HTTP over an actual loopback socket. The tests inspect the page rendered by the desktop window. A separate check opened a running NewsBot FastAPI server in both local reuse mode and configured remote mode and reached the real sign-in form.

| Finding | Verification |
| --- | --- |
| 1. An occupied port opens an unrelated app | Start an unrelated local calendar on the configured port and launch NewsBot. The native window stays on its setup screen, identifies the port mismatch and suggests checking the service or changing the port. The calendar never opens in the window. |
| 2. IPv6 loopback exits before opening | Start a NewsBot-shaped HTTP fixture on IPv6 only and set server.host to ::1. The window opens the feed at the bracketed IPv6 URL. |
| 3. A remote IPv4-only service appears unreachable at localhost | Start the fixture on 127.0.0.1 and pass its localhost URL. The window opens the feed using the configured hostname. |
| 4. Omitting a scheme silently selects local mode | Supply localhost with a port as NEWSBOT_URL and keep a separate calendar fixture running on the configured local port. The window reports an invalid server address and specifies the http:// and https:// schemes. |
| 5. A timeout requires a relaunch | Start the app while its target port is closed. After the timeout the window states that it will retry. Start the server on that same port. The same window automatically opens the feed. |

On Windows, build with `cargo build --release --locked --manifest-path desktop/src-tauri/Cargo.toml`. In a Python environment with Playwright installed, set `NEWSBOT_TEST_BINARY` to the release executable, then run `python desktop/tests/startup_windows.py -v`. WebView2 must be installed on the machine.
