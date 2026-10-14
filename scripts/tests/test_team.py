"""Exercise local Git/worktree operations with a simulated GitHub API, never a live repo."""
import argparse
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import team


def protected_rules():
    return [{"type": "pull_request"}, {"type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": True,
        "required_status_checks": [{"context": "required", "integration_id": 42}]}}]


class BoundariesTest(unittest.TestCase):
    def test_scopes_are_directory_aware_and_cross_platform(self):
        self.assertEqual(team.scopes(["./web/", "web\\main.jac", "web"]), ["web", "web/main.jac"])
        self.assertTrue(team.overlaps("web", "web/main.jac"))
        self.assertFalse(team.overlaps("web", "webhook"))
        self.assertTrue(team.overlaps(".", "pipeline/dedup.jac"))
        for bad in ("../secret", "/tmp", "C:\\secret", "web/*", "web/../db"):
            with self.subTest(bad=bad), self.assertRaises(team.TeamError):
                team.scopes([bad])

    def test_malformed_issue_metadata_does_not_crash_listing(self):
        for body in (None, "ordinary issue", '<!-- newsbot-task:{bad} -->', '<!-- newsbot-task:{"version":1,"files":[7]} -->'):
            self.assertIsNone(team.metadata(body))
        data = {"version": 1, "files": ["web"], "owner": "student"}
        self.assertEqual(team.metadata(team.task_body(data, "Goal")), data)

    def test_merge_requires_the_actual_ci_gate_and_strictness(self):
        self.assertTrue(team.merge_rules_ready(protected_rules(), 42))
        self.assertFalse(team.merge_rules_ready([], 42))
        self.assertFalse(team.merge_rules_ready(protected_rules()[1:], 42))
        self.assertFalse(team.merge_rules_ready(protected_rules(), 99))
        rules = protected_rules()
        rules[1]["parameters"]["strict_required_status_checks_policy"] = False
        self.assertFalse(team.merge_rules_ready(rules, 42))
        rules = protected_rules()
        rules[1]["parameters"]["required_status_checks"][0]["context"] = "unrelated-check"
        self.assertFalse(team.merge_rules_ready(rules, 42))

    def test_pagination_is_flattened(self):
        with patch.object(team, "gh", return_value='[[{"number":1}],[{"number":101}]]') as gh:
            self.assertEqual([x["number"] for x in team.pages("repos/a/b/issues")], [1, 101])
            self.assertIn("--paginate", gh.call_args.args)


class WorkflowTest(unittest.TestCase):
    def setUp(self):
        self.old_cwd = Path.cwd()
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.remote = self.root / "remote.git"
        self.checkout = self.root / "project"
        self.checkout.mkdir()
        self.git("init", "--bare", str(self.remote), cwd=self.root)
        self.git("init", "-b", "main", cwd=self.checkout)
        self.git("config", "user.name", "Test student", cwd=self.checkout)
        self.git("config", "user.email", "student@example.test", cwd=self.checkout)
        self.git("config", "core.autocrlf", "false", cwd=self.checkout)
        (self.checkout / "web").mkdir()
        (self.checkout / "web/main.txt").write_text("initial\n", encoding="utf-8")
        (self.checkout / "scripts").mkdir()
        (self.checkout / "scripts/check.py").write_text("print('simulated project checks passed')\n", encoding="utf-8")
        self.git("add", ".", cwd=self.checkout)
        self.git("commit", "-m", "initial", cwd=self.checkout)
        self.git("remote", "add", "origin", str(self.remote), cwd=self.checkout)
        self.git("push", "-u", "origin", "main", cwd=self.checkout)
        os.chdir(self.checkout)
        self.repo = "example/NewsBot"
        self.info = {"default_branch": "main", "permissions": {"push": True, "admin": True}, "allow_auto_merge": True}
        self.issues = {}
        self.prs = []
        self.comments = []
        self.merges = []
        self.rules = protected_rules()
        self.patchers = [patch.object(team, "repository", return_value=self.repo),
                         patch.object(team, "api", side_effect=self.api),
                         patch.object(team, "pages", side_effect=self.pages),
                         patch.object(team, "gh", side_effect=self.gh)]
        for p in self.patchers:
            p.start()
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()

    def tearDown(self):
        self.output.__exit__(None, None, None)
        for p in reversed(self.patchers):
            p.stop()
        os.chdir(self.old_cwd)
        # Windows Git objects can be read-only; TemporaryDirectory owns all paths here.
        self.temp.cleanup()

    @staticmethod
    def git(*args, cwd=None):
        return subprocess.check_output(["git", *args], cwd=cwd, stderr=subprocess.STDOUT, text=True).strip()

    def api(self, path, method="GET", payload=None):
        prefix = f"repos/{self.repo}"
        if path == "user":
            return {"login": "student"}
        if path == "apps/github-actions":
            return {"id": 42}
        if path == prefix:
            return copy.deepcopy(self.info)
        if path == prefix + "/issues" and method == "POST":
            number = len(self.issues) + 1
            issue = {**payload, "number": number, "html_url": f"https://github.com/{self.repo}/issues/{number}", "state": "open"}
            self.issues[number] = issue
            return copy.deepcopy(issue)
        if path.startswith(prefix + "/issues/"):
            parts = path[len(prefix + "/issues/"):].split("/")
            issue = self.issues[int(parts[0])]
            if len(parts) > 1:
                self.comments.append(payload["body"])
                return {}
            if method == "PATCH":
                issue.update(payload)
            return copy.deepcopy(issue)
        if path == prefix + "/git/refs":
            self.git("--git-dir", str(self.remote), "update-ref", payload["ref"], payload["sha"])
            return {}
        if path.startswith(prefix + "/pulls?"):
            return copy.deepcopy(self.prs)
        if path == prefix + "/pulls" and method == "POST":
            pr = {**payload, "number": 10, "html_url": f"https://github.com/{self.repo}/pull/10"}
            self.prs.append(pr)
            return copy.deepcopy(pr)
        if path == prefix + "/pulls/10" and method == "PATCH":
            self.prs[0].update(payload)
            return copy.deepcopy(self.prs[0])
        if path == prefix + "/rules/branches/main":
            return copy.deepcopy(self.rules)
        raise AssertionError(f"Unexpected API operation: {method} {path}")

    def pages(self, path):
        if "/issues?" in path:
            return copy.deepcopy([i for i in self.issues.values() if i["state"] == "open"])
        if "/pulls?" in path:
            return copy.deepcopy(self.prs)
        raise AssertionError(path)

    def gh(self, *args, **kwargs):
        if args[:2] == ("pr", "merge"):
            self.merges.append(args)
            return "Auto-merge requested"
        raise AssertionError(args)

    def start(self, files=None, coordination=None):
        team.start(argparse.Namespace(title="Filter categories", description="A category selector works", agent="codex", files=files or ["web"], coordination=coordination))
        os.chdir(self.root / f"project-task-{len(self.issues)}")

    def commit_feature(self):
        Path("web/main.txt").write_text("filter\n", encoding="utf-8")
        self.git("add", "web/main.txt")
        self.git("commit", "-m", "add filter")

    def finish(self):
        body = self.root / "pr.md"
        body.write_text("Adds category filtering. Reviewed contracts and tested behavior.\n", encoding="utf-8")
        team.finish(argparse.Namespace(body_file=str(body), coordination=None))

    def test_start_isolates_dirty_checkout_and_finish_publishes_checked_commit(self):
        (self.checkout / "local-note.txt").write_text("keep this", encoding="utf-8")
        self.start()
        self.assertFalse(Path("local-note.txt").exists())
        self.assertEqual((self.checkout / "local-note.txt").read_text(), "keep this")
        self.commit_feature()
        head = self.git("rev-parse", "HEAD")
        self.finish()
        self.assertIn("Closes #1", self.prs[0]["body"])
        self.assertEqual(len(self.merges), 1)
        self.assertEqual(self.merges[0][-2:], ("--match-head-commit", head))
        self.assertEqual(team.metadata(self.issues[1]["body"])["status"], "review")

    def test_overlap_requires_explicit_coordination_before_creating_another_issue(self):
        self.start()
        os.chdir(self.checkout)
        with self.assertRaisesRegex(team.TeamError, "Overlapping"):
            self.start()
        self.assertEqual(len(self.issues), 1)
        self.start(coordination="Task 1 owns the backend data; task 2 only writes separate CSS.")
        self.assertEqual(len(self.issues), 2)

    def test_unprotected_repository_gets_pr_but_no_merge_request(self):
        self.start()
        self.commit_feature()
        self.rules = []
        with self.assertRaisesRegex(team.TeamError, "auto-merge was NOT requested"):
            self.finish()
        self.assertEqual(len(self.prs), 1)
        self.assertEqual(self.merges, [])

    def test_dirty_work_is_never_stashed_or_published(self):
        self.start()
        Path("web/main.txt").write_text("unfinished", encoding="utf-8")
        with self.assertRaisesRegex(team.TeamError, "Commit or preserve"):
            self.finish()
        self.assertEqual(Path("web/main.txt").read_text(), "unfinished")
        self.assertEqual(self.prs, [])

    def test_out_of_scope_change_requires_shared_record_update(self):
        self.start()
        Path("unexpected.txt").write_text("scope expansion", encoding="utf-8")
        self.git("add", "unexpected.txt")
        self.git("commit", "-m", "outside scope")
        with self.assertRaisesRegex(team.TeamError, "outside the advertised scope"):
            self.finish()
        self.assertEqual(self.prs, [])

    def test_stale_branch_requires_sync_and_then_merges_without_force(self):
        self.start()
        task = Path.cwd()
        self.commit_feature()
        os.chdir(self.checkout)
        Path("new-main-file.txt").write_text("new main", encoding="utf-8")
        self.git("add", "new-main-file.txt")
        self.git("commit", "-m", "main advances")
        self.git("push", "origin", "main")
        os.chdir(task)
        with self.assertRaisesRegex(team.TeamError, "base branch advanced"):
            self.finish()
        team.sync(argparse.Namespace())
        self.finish()
        self.assertEqual(len(self.merges), 1)

    def test_failed_checks_do_not_publish(self):
        self.start(files=["web", "scripts"])
        Path("scripts/check.py").write_text("raise SystemExit(1)\n", encoding="utf-8")
        self.git("add", "scripts/check.py")
        self.git("commit", "-m", "simulate failing project")
        with self.assertRaisesRegex(team.TeamError, "Checks failed"):
            self.finish()
        self.assertEqual(self.prs, [])
        self.assertEqual(self.merges, [])

    def test_resume_reuses_existing_worktree_and_preserves_progress(self):
        self.start()
        task = Path.cwd()
        Path("uncommitted.txt").write_text("keep", encoding="utf-8")
        os.chdir(self.checkout)
        team.resume(argparse.Namespace(issue=1))
        self.assertEqual((task / "uncommitted.txt").read_text(), "keep")
        self.assertEqual(len(self.issues), 1)

    def test_scope_update_keeps_visible_issue_and_machine_record_consistent(self):
        self.start()
        team.update(argparse.Namespace(files=["web", "tests"], status="active", note="Added regression test scope."))
        body = self.issues[1]["body"]
        self.assertIn("- `tests`", body)
        self.assertIn("tests", team.metadata(body)["files"])
        self.assertEqual(self.comments, ["Added regression test scope."])

    def test_conflicting_sync_preserves_both_sides_for_agent_resolution(self):
        self.start()
        task = Path.cwd()
        self.commit_feature()
        os.chdir(self.checkout)
        Path("web/main.txt").write_text("another feature\n", encoding="utf-8")
        self.git("add", "web/main.txt")
        self.git("commit", "-m", "conflicting main change")
        self.git("push", "origin", "main")
        os.chdir(task)
        with self.assertRaises(team.TeamError):
            team.sync(argparse.Namespace())
        content = Path("web/main.txt").read_text()
        self.assertIn("filter", content)
        self.assertIn("another feature", content)
        self.assertIn("<<<<<<<", content)
        self.assertTrue(self.git("ls-files", "--unmerged"))


class AdministrationTest(unittest.TestCase):
    def test_no_rules_are_changed_until_main_ci_has_succeeded(self):
        calls = []

        def api(path, method="GET", payload=None):
            calls.append((path, method, payload))
            if path == "apps/github-actions":
                return {"id": 42}
            if "/check-runs" in path:
                return {"check_runs": [{"name": "required", "conclusion": "failure", "app": {"id": 42}}]}
            raise AssertionError(path)

        with patch.object(team, "repository", return_value="a/b"), patch.object(team, "ensure_access", return_value={"default_branch": "main"}), patch.object(team, "api", side_effect=api), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(team.TeamError, "successful `required` check"):
                team.admin(argparse.Namespace(apply=True))
        self.assertTrue(all(method == "GET" for _, method, _ in calls))

    def test_admin_protects_before_enabling_auto_merge_and_preserves_other_rules(self):
        calls = []

        def api(path, method="GET", payload=None):
            calls.append((path, method, payload))
            if path == "apps/github-actions":
                return {"id": 42}
            if "/check-runs" in path:
                return {"check_runs": [{"name": "required", "conclusion": "success", "app": {"id": 42}}]}
            if "/rules/branches/" in path:
                return protected_rules()
            return {}

        with patch.object(team, "repository", return_value="a/b"), patch.object(team, "ensure_access", return_value={"default_branch": "main"}), patch.object(team, "api", side_effect=api), patch.object(team, "pages", return_value=[{"name": "Other policy", "id": 9}, {"name": team.RULESET, "id": 10}]), contextlib.redirect_stdout(io.StringIO()):
            team.admin(argparse.Namespace(apply=True))
        writes = [(path, method, payload) for path, method, payload in calls if method != "GET"]
        self.assertEqual([(path, method) for path, method, _ in writes], [("repos/a/b/rulesets/10", "PUT"), ("repos/a/b", "PATCH")])
        self.assertEqual(writes[0][2]["rules"][2]["parameters"]["required_approving_review_count"], 0)
        self.assertTrue(writes[1][2]["allow_auto_merge"])


if __name__ == "__main__":
    unittest.main()
