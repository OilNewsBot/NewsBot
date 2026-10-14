# Open the repo and start building

After one-time setup, open NewsBot in Codex or Claude Code and describe a feature:

> Add category filtering to the feed. Follow the repository collaboration workflow
> and take the change through checks and merging.

The agent reads the shared instructions, records the work, creates an isolated
worktree, coordinates through GitHub, and handles the PR. You focus on desired
behavior and trying the result. You do not need to write issues or review routine
PRs. If you only want a local prototype, say so; that overrides automatic publishing.

## One-time account setup

1. Ask the repository owner to add your GitHub account as a collaborator with
   **write** access to `arysamaga/NewsBot`; accept the invitation.
2. Install [Git](https://git-scm.com/downloads), [GitHub CLI](https://cli.github.com/),
   Python **3.10+**, and either Codex or Claude Code. Use your existing agent
   account. The helper uses only Python's standard library.
3. Authenticate in the environment where the agent runs:

   ```sh
   gh auth login --hostname github.com --git-protocol https --web
   gh auth setup-git
   git clone https://github.com/arysamaga/NewsBot.git
   cd NewsBot
   python3 scripts/team.py doctor
   python3 scripts/bootstrap.py
   ```

4. Open this folder in the agent and start describing work. If the agent returns
   a new worktree path, its subsequent commands and edits must use that path.
   An app may require opening/attaching that directory for access; the agent
   should explain the exact action if it cannot switch its working directory.

GitHub CLI authentication is separate from a browser GitHub login or an app's
GitHub connector. Never paste a token into an issue or chat. If `doctor` says
read-only, signing in alone is not enough: the owner must grant access.

## Windows and supported Jac platforms

The pinned Jac 0.37.25 release has Linux x86_64/arm64 and Apple Silicon binaries.
It has no native Windows or Intel macOS binary. On Windows use **Ubuntu in WSL2**
for Jac installation and checks. Prefer cloning under the Linux home directory
for performance; use an agent that can run commands in that WSL environment.
If WSL is not installed, use Microsoft's WSL installation flow; it may require
an administrator action and restart. On Intel Mac use a Linux development
environment. Do not silently upgrade Jac to work around platform support.

The collaboration helper also works in native Windows PowerShell with `python`
in place of `python3`. On Windows, `bootstrap.py` and the full `check.py` command
automatically forward to Ubuntu in WSL; `team.py` keeps using your native Git and
GitHub CLI login, including when finish runs the app checks. No second GitHub
login inside WSL is needed for that workflow. Set `NEWSBOT_WSL_DISTRO` if your
Ubuntu distribution has another name. If you run the agent/helper entirely inside
WSL instead, authenticate GitHub CLI there; the two environments are separate.

`bootstrap.py` downloads the exact binary into `~/.local/bin`, verifies the release
SHA-256 checksum, and runs `jac install`. It is safe to rerun. It does not edit
shell profiles or create live credentials. Add `~/.local/bin` to PATH to use
`jac run` directly; helper checks find that binary without a PATH change.

## Run or test the app

```sh
python3 scripts/check.py             # full offline merge gate
jac run                              # http://localhost:8000
jac run replay -- tests/fixtures/    # second terminal, exercise the UI
```

The test suite replays recorded LLM responses. A normal server replay is not
automatically a cassette replay: without credentials it exercises fail-open
behavior; live classification needs the explicitly configured API key. See
[project.md](project.md) for details before turning on feeds.

Each new worktree needs `python3 scripts/bootstrap.py` once. Worktrees do not copy
ignored `.env`, session files, dependencies, or runtime databases. Keep this default:
copying live credentials to every parallel task can start duplicate paid feeds.
For concurrent servers choose distinct `server.port` values in each worktree's
local `config.yaml`, keep relative database paths, and exclude temporary settings
changes from commits. Alternatively run only one app instance at a time.

## What is automatic and what is not

Your active agent operates the helper and fixes problems. GitHub runs CI and
auto-merges when requirements pass. There is no background agent daemon: closing
the chat does not schedule repair work or wake another teammate's agent. If a PR
becomes behind or fails after you leave, tell an agent to resume the recorded task.
The owner must complete [repository administration](repository-admin.md) once
before automatic merging is enabled.
