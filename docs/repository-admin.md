# One-time repository setup for the owner

An owner/admin performs this once. Teammates only need write access and their own
GitHub/agent login. The repository can remain on a personal GitHub account; this
workflow does not require an organization, merge queue, or shared model API key.

NewsBot is currently owned by Ary's personal account. Personal repositories have
owner and collaborator roles, so **Ary must perform the settings step below**;
collaborators cannot be promoted to a separate repository-admin role. Ary can
simply ask his agent to pull main and run the command. Organization repositories
can delegate this step to an administrator if the team moves to one later.

## Activate the setup

1. Grant each teammate collaborator access and have them accept the invitation.
2. Review and merge the initial setup PR after its `required` CI job passes.
   This initial bootstrap merge happens before the new rules are installed.
3. Let the push-to-main CI run pass. Then, from an up-to-date checkout using an
   administrator's GitHub CLI login, run:

   ```sh
   python3 scripts/team.py admin
   python3 scripts/team.py admin --apply
   ```

The first command prints the exact settings/ruleset without modifying GitHub.
The second verifies a successful `required` check on current main, creates or
updates the **NewsBot agent collaboration** ruleset, and enables auto-merge.
It installs protection before enabling automatic merging. It requires admin
access; a regular collaborator cannot change these settings.

## Applied configuration

- Scope: the default branch, with no bypass actors in this ruleset.
- Require a PR, **zero approving reviews**, and resolution of review threads.
- Require the `required` check from the GitHub Actions integration and an
  up-to-date branch (strict checks).
- Block force pushes and deletion of the default branch.
- Enable squash merging, auto-merge, automatic merged-branch deletion, and branch
  updates. Other allowed merge methods are preserved.

The command preserves other rulesets and legacy branch protection. Existing
requirements can still require human approvals or block merges; inspect the
printed effective rules. If the owner wants the zero-review workflow, reconcile
those older requirements deliberately rather than deleting them blindly.

## Verify once

Have an agent start a small documentation task with the helper, commit the change,
and finish it. Check that the PR cannot merge before `required` passes and merges
without a teammate approval afterward. A failed check must block the merge. An
agent must sync and rerun finish if another PR moved main in the meantime.

`CI` runs on PRs, main pushes, and manual dispatch. It uses read-only repository
permissions, installs Jac 0.37.25 with checksum verification, and runs offline
checks without provider secrets. Do not add live app credentials to this workflow.

## Troubleshooting

- **403 / read-only:** check `gh auth status`, accepted collaborator invitations,
  and account permissions. Browser/connector sign-in does not log in `gh`.
- **No successful required check:** the setup must be on main and its main CI
  run must finish successfully before applying the rules.
- **PR waiting for review:** another rule/protection may still require it.
- **PR behind main:** a running agent uses `team.py sync`, resolves conflicts,
  commits, and reruns finish. GitHub auto-merge does not repair conflicts.
- **Agent stopped:** GitHub can finish passing CI/auto-merge, but repairing failed
  or stale work needs the agent to resume. There is no always-on worker.

References: [GitHub rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets),
[auto-merge](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/automatically-merging-a-pull-request),
[GitHub CLI](https://cli.github.com/manual/gh_pr_merge),
[Jac release](https://github.com/jaseci-labs/jac/releases/tag/v0.37.25).
