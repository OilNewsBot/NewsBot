"""The merge gate must mask live credentials and fail on invalid offline fixtures."""
import contextlib
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check


class CheckTest(unittest.TestCase):
    def setUp(self):
        self.wsl = patch.object(check, "forward_to_wsl", return_value=False)
        self.wsl.start()
        self.addCleanup(self.wsl.stop)

    def test_full_gate_masks_credentials_and_keeps_serial_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".jac").mkdir()
            (root / "main.jac").write_text("# test source\n")
            (root / "tests/cassettes").mkdir(parents=True)
            (root / "tests/cassettes/llm.json").write_text('{"sample": {"text": "recorded"}}')
            with patch.object(check, "ROOT", root), patch.object(check, "jac_binary", return_value="jac"), patch.object(sys, "argv", ["check.py"]), patch.dict(os.environ, {"ANTHROPIC_API_KEY": "do-not-use", "TRIAGE_MODEL": "custom-model"}), patch.object(check.subprocess, "run") as run, contextlib.redirect_stdout(io.StringIO()):
                check.main()
            commands = [c.args[0] for c in run.call_args_list]
            self.assertEqual(commands[1:], [["jac", "fmt", "--check", "main.jac", "adapters", "db", "pipeline", "tests", "web"], ["jac", "check"], ["jac", "test"], ["jac", "build", "web"]])
            for call in run.call_args_list:
                env = call.kwargs["env"]
                self.assertEqual(env["ANTHROPIC_API_KEY"], "")
                self.assertEqual(env["TRIAGE_MODEL"], "")
                self.assertEqual(env["JAC_TEST_JOBS"], "0")
                self.assertEqual(env["NEWSSTREAM_CASSETTE_MODE"], "replay")

    def test_missing_or_empty_cassettes_stop_before_running_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tests/cassettes").mkdir(parents=True)
            for content in (None, "{}"):
                if content is not None:
                    (root / "tests/cassettes/llm.json").write_text(content)
                with patch.object(check, "ROOT", root), patch.object(sys, "argv", ["check.py"]), patch.object(check.subprocess, "run") as run:
                    with self.assertRaisesRegex(RuntimeError, "must exist and be nonempty"):
                        check.main()
                    run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
