# NewsBot desktop app (Tauri)

This folder wraps NewsBot in a Mac desktop window. It does not change NewsBot
itself. When you open the app, it:

1. Starts the normal NewsBot server (`jac run`) from this repository.
2. Shows a "Starting NewsBot…" screen until the server answers.
3. Shows the same page you would see at http://127.0.0.1:8000, in its own window.
4. Stops the server when you quit the app (⌘Q). If a server was already
   running before you opened the app, the app uses it and leaves it running.

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

## Run it while developing

```sh
cd ~/Documents/eecs449/NewsBot/desktop
npm run dev
```

The first run compiles Rust and takes about a minute. After that a NewsBot
window opens. To stop, quit the window (⌘Q) or press Ctrl+C in the Terminal.
Either way, the NewsBot server stops too.

## Build a real app you can double-click

```sh
cd ~/Documents/eecs449/NewsBot/desktop
npm run build
```

When it finishes you get:

- `src-tauri/target/release/bundle/macos/NewsBot.app`, the app itself
- `src-tauri/target/release/bundle/dmg/NewsBot_0.1.0_aarch64.dmg`, an installer image

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
at `~/Documents/eecs449/NewsBot/data/desktop-server.log`.

| Message | Fix |
| --- | --- |
| "Could not run jac" | Run `python3 scripts/bootstrap.py` in the NewsBot folder |
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
