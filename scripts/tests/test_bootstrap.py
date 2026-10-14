import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bootstrap


class BootstrapTest(unittest.TestCase):
    def test_version_banner_may_include_platform_but_not_a_different_version(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "jac"
            binary.touch()
            with patch.object(bootstrap.shutil, "which", return_value=str(binary)), patch.object(bootstrap.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "jac 0.37.25  (Linux x86_64)\n", "")):
                self.assertEqual(bootstrap.jac_binary(), str(binary))
            with patch.object(bootstrap.shutil, "which", return_value=str(binary)), patch.object(bootstrap.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "jac 0.37.250\n", "")):
                with self.assertRaises(RuntimeError):
                    bootstrap.jac_binary()

    def test_windows_forwarding_preserves_worktree_and_avoids_shell_interpolation(self):
        with patch.object(bootstrap.os, "name", "nt"), patch.object(bootstrap.shutil, "which", return_value="wsl"), patch.dict(bootstrap.os.environ, {"NEWSBOT_WSL_DISTRO": "Ubuntu"}), patch.object(bootstrap.subprocess, "check_output", return_value="/mnt/c/My Project\n") as convert, patch.object(bootstrap.subprocess, "run") as run, contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(bootstrap.forward_to_wsl("check.py"))
        self.assertEqual(convert.call_args.args[0][-1], str(bootstrap.ROOT))
        self.assertIn("--exec", convert.call_args.args[0])
        self.assertEqual(run.call_args.args[0], ["wsl", "-d", "Ubuntu", "--cd", "/mnt/c/My Project", "--exec", "python3", "scripts/check.py"])
        self.assertTrue(run.call_args.kwargs["check"])


if __name__ == "__main__":
    unittest.main()
