#!/usr/bin/env python3
"""Shared, dependency-free GitHub collaboration helper for Codex and Claude Code."""
import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

MARKER = re.compile(r"<!-- newsbot-task:(\{[^\n]*\}) -->")
RULESET = "NewsBot agent collaboration"


class TeamError(RuntimeError):
    pass


def run(*args, cwd=None, input=None):
    result = subprocess.run(list(args), cwd=cwd, input=input, text=True, encoding="utf-8", capture_output=True)
    if result.returncode:
        raise TeamError(f"{' '.join(args[:3])} failed:\n{result.stderr.strip() or result.stdout.strip()}")
    return result.stdout.strip()


def git(*args, cwd=None):
    return run("git", *args, cwd=cwd)


def gh(*args, input=None):
    return run("gh", *args, input=input)


def api(path, method="GET", payload=None):
    args = ["api", path, "--method", method]
    if payload is not None:
        args += ["--input", "-"]
    output = gh(*args, input=json.dumps(payload) if payload is not None else None)
    return json.loads(output) if output else None


def pages(path):
    # --slurp wraps paginated responses; never silently ignore tasks beyond page 1.
    return [item for page in json.loads(gh("api", path, "--paginate", "--slurp")) for item in page]


def repository():
    remote = git("remote", "get-url", "origin")
    match = re.fullmatch(r"(?:https://github\.com/|git@github\.com:)([^/]+/[^/]+?)(?:\.git)?/?", remote)
    if not match:
        raise TeamError("origin must be the shared github.com repository (HTTPS or SSH).")
    return match.group(1)


def metadata(body):
    match = MARKER.search(body or "")
    if not match:
        return None
    try:
        data = json.loads(match.group(1))
        if data.get("version") != 1 or not isinstance(data.get("files"), list):
            return None
        if not all(isinstance(p, str) for p in data["files"]):
            return None
        return data
    except (ValueError, AttributeError):
        return None


def task_body(data, description):
    return f"{description.rstrip()}\n\n<!-- newsbot-task:{json.dumps(data, sort_keys=True)} -->\n"


def scopes(values):
    result = []
    for value in values:
        value = value.replace("\\", "/").removeprefix("./").rstrip("/") or "."
        if value.startswith("/") or any(p == ".." for p in value.split("/")) or re.search(r"[*?\[\]:\n\r]", value):
            raise TeamError("Scopes must be repository-relative files or directories, without globs or '..'.")
        result.append(value)
    return sorted(set(result))


def overlaps(left, right):
    return left == "." or right == "." or left == right or left.startswith(right + "/") or right.startswith(left + "/")


def active_tasks(repo):
    return [(issue, data) for issue in pages(f"repos/{repo}/issues?state=open&per_page=100")
            if "pull_request" not in issue and (data := metadata(issue.get("body")))]


def conflicts(tasks, files, exclude=None):
    return [(issue, data) for issue, data in tasks if issue["number"] != exclude
            and any(overlaps(a, b) for a in files for b in data["files"])]


def print_tasks(tasks):
    for issue, data in tasks:
        print(f"#{issue['number']} [{data.get('status', 'active')}] {issue['title']} ({data.get('owner', '?')}/{data.get('agent', '?')})")
        print(f"  Files: {', '.join(data['files'])}\n  Branch: {data.get('branch', '(starting)')}\n  {issue['html_url']}")


def ensure_access(repo, admin=False):
    info = api(f"repos/{repo}")
    permission = "admin" if admin else "push"
    if not info.get("permissions", {}).get(permission):
        raise TeamError(f"Your gh account needs {'admin' if admin else 'write'} access to {repo}. Ask the repository owner to grant access.")
    return info


def current_task(repo):
    branch = git("branch", "--show-current")
    match = re.fullmatch(r"agent/(\d+)-[a-z0-9-]+", branch)
    if not match:
        raise TeamError("Run this in the task worktree created by `team.py start` or `resume`.")
    issue = api(f"repos/{repo}/issues/{match.group(1)}")
    data = metadata(issue.get("body"))
    if not data or data.get("branch") != branch:
        raise TeamError("The branch and shared task record disagree; inspect the issue before continuing.")
    login = api("user")["login"]
    if data.get("owner") != login:
        raise TeamError(f"Task belongs to {data.get('owner')}; coordinate a handoff instead of editing their branch.")
    return issue, data


def update_task(repo, issue, data):
    # Preserve prose and comments. Refresh body so a stale local copy isn't written back.
    fresh = api(f"repos/{repo}/issues/{issue['number']}")
    description = MARKER.sub("", fresh.get("body") or "").strip()
    visible_scope = "## Intended files\n" + "\n".join(f"- `{f}`" for f in data["files"]) + "\n\n"
    if "## Intended files\n" in description:
        description = re.sub(r"(?ms)^## Intended files\n.*?(?=^## |\Z)", lambda _: visible_scope, description)
    else:
        description += "\n\n" + visible_scope
    api(f"repos/{repo}/issues/{issue['number']}", "PATCH", {"body": task_body(data, description)})


def comment(repo, issue, body):
    api(f"repos/{repo}/issues/{issue['number']}/comments", "POST", {"body": body})


def clean():
    if git("status", "--porcelain"):
        raise TeamError("Commit or preserve the current changes first. This helper never stages, stashes, or discards your files.")


def doctor(args):
    for executable in ("git", "gh"):
        if not shutil.which(executable):
            raise TeamError(f"Install {executable} and reopen your terminal. See docs/getting-started.md.")
    gh("auth", "status")
    repo = repository()
    info = api(f"repos/{repo}")
    print(f"Repository: {repo}\nAccount: {api('user')['login']}\nPermissions: {json.dumps(info.get('permissions', {}))}")
    runtime = subprocess.run([sys.executable, str(Path(__file__).with_name("bootstrap.py")), "--check"], capture_output=True, text=True)
    print(runtime.stdout.strip() or runtime.stderr.strip())
    if not info.get("permissions", {}).get("push"):
        raise TeamError("Read-only access: ask the owner for collaborator access before starting a shared task.")
    print("GitHub collaboration is ready. Use bootstrap.py for app dependencies in each new worktree.")


def status(args):
    repo = repository()
    print_tasks(active_tasks(repo))
    print("\nOpen PRs (including work outside this helper):")
    for pr in pages(f"repos/{repo}/pulls?state=open&per_page=100"):
        print(f"#{pr['number']} {pr['title']} — {pr['html_url']} [{pr['head']['ref']}]")


def start(args):
    repo = repository()
    info = ensure_access(repo)
    login = api("user")["login"]
    files = scopes(args.files)
    active = active_tasks(repo)
    print_tasks(active)
    collisions = conflicts(active, files)
    if collisions and not args.coordination:
        raise TeamError("Overlapping tasks found. Read their issues/PRs and coordinate. Retry with --coordination describing the agreement, sequencing, or independent boundary.")
    git("fetch", "origin", info["default_branch"])
    base = git("rev-parse", "FETCH_HEAD")
    root = Path(git("rev-parse", "--show-toplevel"))
    data = {"version": 1, "owner": login, "agent": args.agent, "files": files, "status": "starting", "branch": None}
    description = f"## Goal\n{args.title}\n\n## Acceptance and approach\n{args.description}\n\n## Intended files\n" + "\n".join(f"- `{f}`" for f in files)
    if args.coordination:
        description += f"\n\n## Coordination\n{args.coordination}"
    issue = api(f"repos/{repo}/issues", "POST", {"title": args.title, "body": task_body(data, description), "assignees": [login]})
    slug = re.sub(r"[^a-z0-9]+", "-", args.title.lower()).strip("-")[:45] or "task"
    branch = f"agent/{issue['number']}-{slug}"
    destination = root.parent / f"{root.name}-task-{issue['number']}"
    data["branch"] = branch
    update_task(repo, issue, data)
    try:
        # A unique GitHub issue number gives every task a unique branch. No shared working directory.
        api(f"repos/{repo}/git/refs", "POST", {"ref": f"refs/heads/{branch}", "sha": base})
        git("fetch", "origin", f"refs/heads/{branch}:refs/remotes/origin/{branch}")
        git("worktree", "add", "--track", "-b", branch, str(destination), f"origin/{branch}")
        # Catch a concurrent start: the lower issue number gets priority. This is advisory,
        # not a distributed file lock. An agent must still recheck at integration time.
        earlier = [(i, d) for i, d in conflicts(active_tasks(repo), files, issue["number"]) if i["number"] < issue["number"]]
        data["status"] = "blocked" if earlier and not args.coordination else "active"
        update_task(repo, issue, data)
        print(f"Task: {issue['html_url']}\nWorktree: {destination}\nBranch: {branch}\nStatus: {data['status']}")
        if data["status"] == "blocked":
            print_tasks(earlier)
            raise TeamError("Another overlapping task started first. Coordinate before editing, then use `update --status active --note ...`.")
        print("Continue in that worktree. Run bootstrap.py there once before app checks. Do not copy live credentials by default.")
    except (TeamError, OSError):
        print(f"Task #{issue['number']} remains recorded. Use `resume {issue['number']}` after inspecting the failure; don't create a duplicate task.", file=sys.stderr)
        raise


def resume(args):
    repo = repository()
    ensure_access(repo)
    issue = api(f"repos/{repo}/issues/{args.issue}")
    data = metadata(issue.get("body"))
    if not data or data.get("owner") != api("user")["login"] or issue["state"] != "open":
        raise TeamError("Resume requires your own open managed task. For another owner, coordinate a new task/handoff first.")
    branch = data.get("branch")
    if not isinstance(branch, str) or not re.fullmatch(rf"agent/{args.issue}-[a-z0-9-]+", branch):
        raise TeamError("Incomplete or invalid task branch. Inspect the issue before resuming.")
    for block in git("worktree", "list", "--porcelain").split("\n\n"):
        if f"branch refs/heads/{branch}" in block.splitlines():
            print(block)
            return
    root = Path(git("rev-parse", "--show-toplevel"))
    destination = root.parent / f"{root.name}-task-{args.issue}"
    git("fetch", "origin")
    refs = git("for-each-ref", "--format=%(refname)", f"refs/heads/{branch}")
    if refs:
        git("worktree", "add", str(destination), branch)
    else:
        git("worktree", "add", "--track", "-b", branch, str(destination), f"origin/{branch}")
    print(f"Continue in {destination}; task status is {data.get('status')}. Read issue comments and run status before editing.")


def update(args):
    repo = repository()
    issue, data = current_task(repo)
    if args.files:
        data["files"] = scopes(args.files)
    if args.status:
        data["status"] = args.status
    collisions = conflicts(active_tasks(repo), data["files"], issue["number"])
    if collisions:
        print("Overlapping work; record the agreed boundary or dependency in the note:")
        print_tasks(collisions)
    update_task(repo, issue, data)
    comment(repo, issue, args.note)
    print(issue["html_url"])


def sync(args):
    repo = repository()
    current_task(repo)
    clean()
    base = api(f"repos/{repo}")["default_branch"]
    git("fetch", "origin", base)
    print(git("merge", "--no-edit", "FETCH_HEAD"))
    print("Resolve any semantic conflicts, then rerun checks. No force-push is needed.")


def finish(args):
    repo = repository()
    ensure_access(repo)
    issue, data = current_task(repo)
    if issue["state"] != "open":
        raise TeamError("Task is closed; start a new task for new work.")
    clean()
    info = api(f"repos/{repo}")
    base = info["default_branch"]
    git("fetch", "origin", base)
    base_sha = git("rev-parse", "FETCH_HEAD")
    if git("merge-base", "HEAD", base_sha) != base_sha:
        raise TeamError("The base branch advanced. Run `team.py sync`, resolve conflicts, commit, and retry finish.")
    changed = git("diff", "--name-only", f"{base_sha}...HEAD").splitlines()
    if not changed:
        raise TeamError("No committed changes relative to the default branch.")
    outside = [path for path in changed if not any(overlaps(path, scope) for scope in data["files"])]
    if outside:
        raise TeamError(f"Changes outside the advertised scope: {', '.join(outside)}. Publish the expanded scope with `update --files ... --note ...` first.")
    collisions = conflicts(active_tasks(repo), changed, issue["number"])
    if collisions:
        print_tasks(collisions)
        if not args.coordination:
            raise TeamError("Overlapping active tasks require --coordination describing integration order or the agreed boundary.")
    body = Path(args.body_file).read_text(encoding="utf-8")
    if not body.strip():
        raise TeamError("PR description must explain behavior, review, and verification.")
    if not re.search(rf"(?i)\b(?:closes|fixes|resolves)\s+#{issue['number']}\b", body):
        body += f"\n\nCloses #{issue['number']}\n"
    if args.coordination:
        body += f"\n\nCoordination: {args.coordination}\n"
    result = subprocess.run([sys.executable, "scripts/check.py"])
    if result.returncode:
        raise TeamError("Checks failed; fix the failure before publishing for merge.")
    clean()  # Checks must not silently alter cassettes, manifests, or source files.
    head = git("rev-parse", "HEAD")
    git("push", "--set-upstream", "origin", data["branch"])
    prs = api(f"repos/{repo}/pulls?state=open&head={repo.split('/')[0]}:{data['branch']}")
    if prs:
        pr = api(f"repos/{repo}/pulls/{prs[0]['number']}", "PATCH", {"body": body})
    else:
        pr = api(f"repos/{repo}/pulls", "POST", {"title": issue["title"], "body": body, "head": data["branch"], "base": base})
    data["status"] = "review"
    data["pr"] = pr["html_url"]
    update_task(repo, issue, data)
    print(pr["html_url"])
    # Require effective rules before ever asking GitHub to merge. Otherwise --auto
    # can merge immediately in an unprotected repository, before CI has run.
    rules = api(f"repos/{repo}/rules/branches/{base}")
    integration = api("apps/github-actions")["id"]
    if not merge_rules_ready(rules, integration):
        raise TeamError("PR is published, but auto-merge was NOT requested: effective rules must require a PR plus the strict `required` check from GitHub Actions. An admin must run `team.py admin --apply`.")
    if not info.get("allow_auto_merge"):
        raise TeamError("PR is published, but repository auto-merge is disabled. An admin must enable it.")
    print(gh("pr", "merge", str(pr["number"]), "--repo", repo, "--auto", "--squash", "--match-head-commit", head))
    print("Auto-merge requested, not necessarily merged. Use `watch` during this session; GitHub continues CI/auto-merge after it closes.")


def merge_rules_ready(rules, integration):
    return any(r.get("type") == "pull_request" for r in rules) and any(
        r.get("type") == "required_status_checks"
        and r.get("parameters", {}).get("strict_required_status_checks_policy")
        and any(c.get("context") == "required" and c.get("integration_id") == integration
                for c in r.get("parameters", {}).get("required_status_checks", [])) for r in rules)


def watch(args):
    repo = repository()
    issue, data = current_task(repo)
    if not data.get("pr"):
        raise TeamError("No PR recorded. Run finish first.")
    # One snapshot per invocation, so closed sessions don't pretend to be daemons.
    print(gh("pr", "view", data["pr"], "--json", "url,state,mergeStateStatus,autoMergeRequest,statusCheckRollup"))
    state = json.loads(gh("pr", "view", data["pr"], "--json", "state"))["state"]
    if state == "MERGED":
        data["status"] = "done"
        update_task(repo, issue, data)
        if issue["state"] != "closed":
            api(f"repos/{repo}/issues/{issue['number']}", "PATCH", {"state": "closed", "state_reason": "completed"})
        print("Merged. Task closed. Local worktree is preserved; remove it only after checking for needed local files.")
    else:
        print("If pending, check again while this session is active. If behind, sync and finish again; if CI failed, inspect logs and fix it.")


def admin(args):
    repo = repository()
    info = ensure_access(repo, admin=True)
    integration = api("apps/github-actions")["id"]
    settings = {"allow_auto_merge": True, "allow_squash_merge": True, "delete_branch_on_merge": True, "allow_update_branch": True}
    ruleset = {
        "name": RULESET, "target": "branch", "enforcement": "active", "bypass_actors": [],
        "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
        "rules": [
            {"type": "deletion"}, {"type": "non_fast_forward"},
            {"type": "pull_request", "parameters": {
                "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": False,
                "require_code_owner_review": False, "require_last_push_approval": False,
                "required_review_thread_resolution": True}},
            {"type": "required_status_checks", "parameters": {
                "strict_required_status_checks_policy": True,
                "required_status_checks": [{"context": "required", "integration_id": integration}]}}
        ]}
    print(json.dumps({"repository": repo, "settings": settings, "ruleset": ruleset}, indent=2))
    if not args.apply:
        print("Preview only. Run with --apply to configure this named ruleset and merge settings; other protections are preserved.")
        return
    # Install protection before enabling auto-merge, and only after the check exists.
    checks = api(f"repos/{repo}/commits/{info['default_branch']}/check-runs")
    if not any(c["name"] == "required" and c["conclusion"] == "success" and c.get("app", {}).get("id") == integration for c in checks["check_runs"]):
        raise TeamError("Merge the setup PR and obtain a successful `required` check on the default branch before applying these rules.")
    existing = [r for r in pages(f"repos/{repo}/rulesets?per_page=100") if r["name"] == RULESET]
    if existing:
        api(f"repos/{repo}/rulesets/{existing[0]['id']}", "PUT", ruleset)
    else:
        api(f"repos/{repo}/rulesets", "POST", ruleset)
    api(f"repos/{repo}", "PATCH", settings)
    print("Configured. Effective default-branch rules (other protections may still require reviewers):")
    print(json.dumps(api(f"repos/{repo}/rules/branches/{info['default_branch']}"), indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name, handler in (("doctor", doctor), ("status", status), ("sync", sync), ("watch", watch)):
        sub.add_parser(name).set_defaults(handler=handler)
    p = sub.add_parser("start", help="Record a new task and create an isolated worktree")
    p.add_argument("title")
    p.add_argument("--description", required=True, help="Acceptance criteria and intended approach")
    p.add_argument("--files", nargs="+", required=True, help="Relative files/directories; no globs")
    p.add_argument("--agent", choices=("codex", "claude", "other"), required=True)
    p.add_argument("--coordination", help="Explain how overlapping work is coordinated")
    p.set_defaults(handler=start)
    p = sub.add_parser("resume")
    p.add_argument("issue", type=int)
    p.set_defaults(handler=resume)
    p = sub.add_parser("update")
    p.add_argument("--note", required=True, help="Progress, agreement, dependency, or handoff")
    p.add_argument("--files", nargs="+")
    p.add_argument("--status", choices=("active", "blocked", "handoff"))
    p.set_defaults(handler=update)
    p = sub.add_parser("finish")
    p.add_argument("--body-file", required=True)
    p.add_argument("--coordination")
    p.set_defaults(handler=finish)
    p = sub.add_parser("admin")
    p.add_argument("--apply", action="store_true")
    p.set_defaults(handler=admin)
    args = parser.parse_args()
    try:
        args.handler(args)
    except (TeamError, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
