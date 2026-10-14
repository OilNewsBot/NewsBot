#!/usr/bin/env python3
"""The same offline checks run locally and in GitHub Actions."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from bootstrap import ROOT, forward_to_wsl, jac_binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tools-only", action="store_true", help="Test collaboration tooling only; not sufficient to merge")
    args = parser.parse_args()
    if not args.tools_only and forward_to_wsl("check.py"):
        return
    commands = [[sys.executable, "-m", "unittest", "discover", "-s", "scripts/tests", "-v"]]
    env = os.environ.copy()
    # Empty values also prevent python-dotenv from loading credentials from .env.
    for name in ("ANTHROPIC_API_KEY", "TELEGRAM_API_ID", "TELEGRAM_API_HASH", "TELEGRAM_BOT_TOKEN", "X_BEARER_TOKEN", "X_PUSH_API_KEY", "TRIAGE_MODEL", "REVIEW_MODEL"):
        env[name] = ""
    env["JAC_TEST_JOBS"] = "0"
    env["NEWSSTREAM_CASSETTE_MODE"] = "replay"
    env["NEWSSTREAM_CASSETTE"] = str(ROOT / "tests/cassettes/llm.json")
    if not args.tools_only:
        cassette = ROOT / "tests/cassettes/llm.json"
        if not cassette.is_file() or not json.loads(cassette.read_text(encoding="utf-8")):
            raise RuntimeError("Recorded LLM fixtures must exist and be nonempty; do not silently skip behavior tests.")
        jac = jac_binary()
        # Explicit source paths avoid formatting installed packages under .jac/.
        sources = sorted(p.name for p in ROOT.glob("*.jac") if p.is_file()) + ["adapters", "db", "pipeline", "tests", "web"]
        commands += [[jac, "fmt", "--check", *sources], [jac, "check"], [jac, "test"], [jac, "build", "web"]]
    for command in commands:
        print("+ " + " ".join(command), flush=True)
        subprocess.run(command, cwd=ROOT, env=env, check=True)
    print("Tooling checks passed." if args.tools_only else "All required checks passed.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
