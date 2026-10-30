# NewsBot desktop app (Tauri)

This folder wraps NewsBot in a desktop window for Mac, Windows, and Linux. It
does not change NewsBot itself. When you open the app, it:

1. Starts the normal NewsBot server (`jac run`) from this repository.
2. Shows a "Starting NewsBot…" screen until the server answers.
3. Shows the same page you would see at http://127.0.0.1:8000, in its own window.
4. Stops the server when you quit the app (⌘Q on Mac, or close the window). If
   a server was already running before you opened the app, the app uses it and
   leaves it running.

On Windows, Jac only runs inside Ubuntu in WSL (see
[docs/getting-started.md](../docs/getting-started.md)), so the app starts the
server there and shows it in a normal Windows window.

Links to posts (x.com, t.me, …) open in your normal web browser.

The browser version still works the same way: run `jac run` in the NewsBot
folder and open http://127.0.0.1:8000.

## Files

| Path | What it is |
| --- | --- |
| `package.json` | Installs the Tauri command-line tool (`npm run dev`, `npm run build`) |
| `ui/index.html` | The "Starting NewsBot…" screen and its error message |
| `src-tauri/src/main.rs` | Starts/stops the server and opens the window |
| `src-tauri/tauri.conf.json` | App name, bundle ID, and icons |
| `src-tauri/Cargo.toml` | Rust dependencies (Tauri) |
| `src-tauri/icons/` | App icons, generated from `app-icon.svg` |

## One-time setup (Mac)

Open the **Terminal** app (press ⌘Space, type `Terminal`, then press Return)
and run these one at a time. Lines starting with `#` are explanations; you
don't need to type them.

```sh
# 1. Check the tools you need. Each command should print a version number.
node -v        # Node.js (for the Tauri command-line tool)
cargo -V       # Rust (Tauri is written in Rust)
xcode-select -p  # Apple's command-line tools

# Missing any of them? Install them:
#   Node:  brew install node        (needs Homebrew: https://brew.sh)
#   Rust:  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
#   Apple tools: xcode-select --install

# 2. Go to the NewsBot folder and install NewsBot's own dependencies.
cd ~/Documents/eecs449/NewsBot
python3 scripts/bootstrap.py

# 3. Install the desktop app's tools (only needed once).
cd desktop
npm install
```

## One-time setup (Windows)

NewsBot itself must already work through WSL: Ubuntu installed in WSL2 and
`python scripts/bootstrap.py` run once (see docs/getting-started.md). Then open
**PowerShell** (not the Ubuntu window) and run:

```powershell
# 1. Check the tools you need. Each command should print a version number.
node -v          # Node.js:  winget install OpenJS.NodeJS.LTS
cargo -V         # Rust:     winget install Rustlang.Rustup
wsl -l -v        # should list Ubuntu with VERSION 2

# Rust on Windows also needs the "Desktop development with C++" tools from
# Visual Studio Build Tools: https://visualstudio.microsoft.com/visual-cpp-build-tools/
# The WebView2 runtime is already part of Windows 10 (recent updates) and 11.

# 2. Install the desktop app's tools (only needed once).
cd path\to\NewsBot\desktop
npm install
```

Clone NewsBot on the Windows side (for example `C:\Users\you\NewsBot`) and run
these commands there. If your Ubuntu distribution has another name, set
`NEWSBOT_WSL_DISTRO` to that name, just as for `bootstrap.py`. If your copy of
NewsBot lives inside WSL instead, set `NEWSBOT_ROOT` to its Windows path, such
as `\\wsl.localhost\Ubuntu\home\you\NewsBot`.

## One-time setup (Linux)

Install Node.js, Rust, and Tauri's system libraries
(https://v2.tauri.app/start/prerequisites/#linux), run
`python3 scripts/bootstrap.py` in the NewsBot folder, then `npm install` in
`desktop/`.

## Run it while developing

```sh
cd ~/Documents/eecs449/NewsBot/desktop
npm run dev
```

The first run compiles Rust and takes about a minute (longer on Windows). After
that a NewsBot window opens. To stop, quit the window or press Ctrl+C in the
terminal. Either way, the NewsBot server stops too.

## Build a real app you can double-click

```sh
cd ~/Documents/eecs449/NewsBot/desktop
npm run build
```

The build makes an app for the computer you run it on. Each person builds the
app on their own computer. When it finishes, the files are in
`src-tauri/target/release/bundle/`:

- Mac: `macos/NewsBot.app` (the app itself) and `dmg/NewsBot_0.1.0_aarch64.dmg`
- Windows: `nsis/NewsBot_0.1.0_x64-setup.exe` and `msi/NewsBot_0.1.0_x64_en-US.msi`
- Linux: `deb/`, `rpm/`, and `appimage/` packages

On Mac:

To open the app folder in Finder:

```sh
open src-tauri/target/release/bundle/macos
```

You can drag `NewsBot.app` into `/Applications`. It still runs NewsBot from
`~/Documents/eecs449/NewsBot`, so keep that folder where it is. The app
remembers the folder it was built from. If you move the folder, either rebuild
or start the app with `NEWSBOT_ROOT=/new/path/to/NewsBot open -a NewsBot`.

The app is not signed with an Apple developer certificate. On another Mac,
right-click the app and choose **Open** the first time. That Mac also needs the
NewsBot folder, Jac, and the one-time setup above. This is a convenience
wrapper for team members, not an installer for people without the code.

## API keys and cost

The app runs exactly what `jac run` runs. With no `.env` file, the X/Telegram
adapters stay idle and nothing paid is used. If you add keys to
`~/Documents/eecs449/NewsBot/.env`, the desktop app uses them, and live feeds
or Claude calls can cost money, just like `jac run`.

## If something goes wrong

The window shows the error and the last lines of the server log. The full log is
at `data/desktop-server.log` in the NewsBot folder.

| Message | Fix |
| --- | --- |
| "Could not run jac" | Run `python3 scripts/bootstrap.py` in the NewsBot folder |
| "WSL could not open …" (Windows) | Install Ubuntu in WSL, or set `NEWSBOT_WSL_DISTRO` to your distribution's name |
| "jac: command not found" in the log (Windows) | Run `python scripts/bootstrap.py` from PowerShell, which installs jac in WSL |
| "NewsBot stopped while starting" | Read the log; try `jac run` in the NewsBot folder to see the same error |
| "NewsBot folder not found" | Rebuild the app, or set `NEWSBOT_ROOT` as shown above |
| Window shows some other website | Another program uses port 8000, and the app connected to it. Stop that program, or change `server.port` in `config.yaml` |

## GitHub: pull requests and issues from the Terminal

These use GitHub's `gh` tool. Check that you are logged in with `gh auth status`;
if not, run `gh auth login`. Run them from inside `~/Documents/eecs449/NewsBot`.

```sh
# Issues (the team's task list)
gh issue list                       # open issues
gh issue view 14                    # read issue #14 and its details
gh issue view 14 --comments         # ...including the comments
gh issue view 14 --web              # open it in your browser
gh issue create --title "Desktop app" --body "Tauri window for NewsBot"

# Pull requests (proposed code changes)
gh pr list                          # open pull requests
gh pr view 15                       # read PR #15
gh pr diff 15                       # see the code it changes
gh pr checks 15                     # did the automatic tests pass?
gh pr checkout 15                   # try PR #15's code on your machine
git switch desktop-app              # ...then come back to this branch

# Share this desktop branch later, when you are ready (not done for you):
git push -u origin desktop-app      # upload the branch to GitHub
gh pr create --draft --fill         # open a draft PR from it
```

The team's normal agent workflow (`python3 scripts/team.py ...`, see
`AGENTS.md` and `docs/collaboration.md`) creates the issue, PR, and merge for
you. Ask Claude or Codex to "finish this task" when you want to use it.
