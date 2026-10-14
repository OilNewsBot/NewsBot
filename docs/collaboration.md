# Agent-operated collaboration

## Shared state and responsibilities

GitHub issues are the task board and message history; branches/PRs contain code.
Codex and Claude use the same `scripts/team.py` and [AGENTS.md](../AGENTS.md).
The human supplies product intent. The active agent maintains coordination,
implements, reviews, verifies, publishes, and follows integration.

Team policy authorizes routine issue/PR updates and checked in-scope merges. It
does not supersede a user's narrower request or the agent host's permissions.
No setup disables agent approval controls or requires shared account credentials.

Each issue has a readable goal/acceptance description plus a small HTML-comment
JSON record: version, owner, agent, intended files, branch, status, and PR URL.
Do not remove that record. Progress and agreements live in issue comments. No
shared `tasks.json` file is committed, avoiding a central merge-conflict hotspot.

## Normal task lifecycle

The following commands are for the **agent**, not a checklist the human must run.
Examples use `python3`; native Windows can use `python` for the GitHub helper.

```sh
python3 scripts/team.py doctor
python3 scripts/team.py status
python3 scripts/team.py start "Filter feed by category" \
  --agent codex --files web docs/contracts.md \
  --description "Users can choose a category or All; default remains All. Reuse existing category data; no backend schema change."
```

Use `--agent claude` for Claude Code. Start reads all open managed tasks (with
pagination), checks path overlap, creates and assigns an issue, creates a remote
`agent/<issue>-<slug>` branch from current main, and creates a sibling worktree.
It leaves the current checkout alone, including any uncommitted work.

Continue in the returned directory; bootstrap dependencies there once. Before
editing shared interfaces, read related issue comments and PRs. Record changes:

```sh
python3 scripts/team.py update --note "Using existing category field; no backend change."
python3 scripts/team.py update --files web docs/contracts.md tests \
  --note "Expanded scope to add a regression test; checked other tasks first."
```

Implement and review the diff, run checks, then commit explicitly selected files.
The helper never stages all files, creates commits, stashes, discards work, or
performs automatic conflict resolution. Those choices belong to the agent after
it inspects the diff.

```sh
python3 scripts/team.py sync
python3 scripts/team.py finish --body-file /tmp/newsbot-pr.md
python3 scripts/team.py watch
```

`sync` requires a clean task checkout and merges latest main into it. If Git finds
conflicts it leaves them for the agent to resolve; it does not abort or discard
edits. Finish requires a clean commit, an up-to-date base, a nonempty diff, and
actual changed files within the published scope. It reruns the full offline
checks, pushes without force, creates/updates the PR, and requests squash
auto-merge against the exact pushed commit. The PR description closes the issue.

Finish refuses to request a merge if effective branch rules do not require a PR
and strict status checks, or repository auto-merge is disabled. It still leaves
a reviewable PR. Once configured, GitHub enforces CI independently of the agent.
There are zero required human approvals. An agent's review pass is not a fake
approval from a second identity.

`watch` takes one status snapshot. A running agent should inspect failed Actions
logs (`gh run view RUN_ID --log-failed`), repair, commit, and retry finish. If main
advanced, sync and rerun finish. After observing a merge, watch marks the record
done and closes the issue if GitHub did not already close it. It preserves the
local worktree and its ignored files.

## Overlap and dependencies

Scopes are repository-relative file or directory paths, not globs. `web` overlaps
`web/main.jac`; `web` does not overlap `webhook`. `.` means the whole repository.
The helper also shows open PRs that were not created through it; agents must read
those because they have no managed scope record.

When scopes overlap, start/finish require `--coordination "explanation"`. First
inspect the other task and choose an independent boundary, agree on a contract,
or wait for the dependency's PR. Put the rationale and links in the issue. This
flag is an explicit agent decision, not a new human permission gate.

Claims are **advisory**: scope checks do not lock files or prevent someone editing
outside their record. Concurrent starts recheck and give the lower issue number
priority when overlap was not explicitly coordinated. Always recheck before
shared edits and integration. Do not infer a task is abandoned from its age.

Prefer small independent changes from main. For tightly dependent work, merge a
small shared contract first and use fixtures while waiting. Stacked PRs are an
advanced manual Git/gh workflow: this helper's finish command targets the default
branch and does not manage a stack. Keep any stacked work clearly documented and
restore a main-based branch before using finish.

## Resume, handoff, and recovery

- Same owner, another session/machine: `team.py resume ISSUE` finds the existing
  worktree or creates one from the published task branch. Read the issue comments
  before editing. Stop the old writing session before resuming the same task.
- Another teammate taking over: the outgoing agent pushes its commits, records
  the branch/commit, verification, and next step, and sets `update --status handoff
  --note ...`. The new owner starts a new linked task and deliberately incorporates
  the published changes. The helper will not silently adopt another owner's branch.
- A partial start can leave an issue/branch. Inspect it and use resume, not a
  duplicate start. If branch creation failed, create the recorded branch from the
  agreed base with Git/gh, then resume. If the task is abandoned, explain and close
  its issue, and only delete branches/worktrees after preserving useful work.
- An overlap blocks progress: use `update --status blocked --note ...`, work on an
  independent part if possible, and check the dependency while the session runs.
- GitHub is unavailable or access is missing: do useful local research or a scoped
  prototype, report that shared coordination is unavailable, and publish/coordinate
  before integrating. Never claim that local work is merged.

No command polls indefinitely or wakes a closed agent. CI/auto-merge continues on
GitHub, but automatic conflict repair requires a running agent. A background
orchestrator can be added later if the team actually needs that service.

## Keep the human focused

Choose routine implementation details, write tests, repair failures, and resolve
ordinary merge conflicts autonomously. Escalate only missing account access,
credentials actually needed for the requested feature, incompatible product
requirements, or actions outside the task's standing authorization. Routine
building does not require live feed credentials or a human reviewer.
