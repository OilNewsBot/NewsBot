#!/usr/bin/env python3
"""Install the project's exact Jac binary, verify its checksum, and install packages."""
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.37.25"


def forward_to_wsl(script, args=()):
    """Keep GitHub/Git on Windows; run the unsupported native Jac runtime in WSL."""
    if os.name != "nt":
        return False
    if not shutil.which("wsl"):
        raise RuntimeError("Jac needs Ubuntu in WSL on Windows. See docs/getting-started.md.")
    distro = os.environ.get("NEWSBOT_WSL_DISTRO", "Ubuntu")
    prefix = ["wsl", "-d", distro]
    linux_root = subprocess.check_output([*prefix, "--exec", "wslpath", "-a", str(ROOT)], text=True).strip()
    print(f"Running {script} in WSL/{distro}...", flush=True)
    subprocess.run([*prefix, "--cd", linux_root, "--exec", "python3", f"scripts/{script}", *args], check=True)
    return True


def jac_binary():
    candidates = [shutil.which("jac"), str(Path.home() / ".local/bin/jac")]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            result = subprocess.run([candidate, "--version"], capture_output=True, text=True)
            if result.returncode == 0 and result.stdout.split()[:2] == ["jac", VERSION]:
                return candidate
    raise RuntimeError(f"Jac {VERSION} is missing. Run python3 scripts/bootstrap.py (Windows: inside WSL).")


def install_binary():
    system = {"Linux": "linux", "Darwin": "macos"}.get(platform.system())
    arch = {"x86_64": "x86_64", "amd64": "x86_64", "arm64": "aarch64", "aarch64": "aarch64"}.get(platform.machine().lower())
    if not system or not arch or (system == "macos" and arch == "x86_64"):
        raise RuntimeError("This pinned Jac release supports Linux x86_64/arm64 and Apple Silicon. On Windows use Ubuntu in WSL; on Intel Mac use a Linux environment. See docs/getting-started.md.")
    asset = f"jac-{VERSION}-{system}-{arch}"
    base = f"https://github.com/jaseci-labs/jac/releases/download/v{VERSION}/{asset}"
    destination = Path.home() / ".local/bin/jac"
    destination.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(base + ".sha256", timeout=60) as response:
        expected = response.read().decode().split()[0].lower()
    # Download beside the destination so replace is atomic on the same filesystem.
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as temporary:
        temp_path = Path(temporary.name)
        try:
            with urllib.request.urlopen(base, timeout=120) as response:
                shutil.copyfileobj(response, temporary)
        except BaseException:
            temporary.close()
            temp_path.unlink(missing_ok=True)
            raise
    try:
        if hashlib.sha256(temp_path.read_bytes()).hexdigest() != expected:
            raise RuntimeError("Jac download failed checksum verification.")
        temp_path.chmod(0o755)
        version = subprocess.check_output([str(temp_path), "--version"], text=True).strip()
        if version.split()[:2] != ["jac", VERSION]:
            raise RuntimeError(f"Unexpected binary version: {version}")
        os.replace(temp_path, destination)
    finally:
        temp_path.unlink(missing_ok=True)
    return str(destination)


def main():
    try:
        if forward_to_wsl("bootstrap.py"):
            return 0
        try:
            binary = jac_binary()
        except RuntimeError:
            print(f"Installing Jac {VERSION} with SHA-256 verification...", flush=True)
            binary = install_binary()
        subprocess.run([binary, "install"], cwd=ROOT, check=True)
        print(f"Ready. Jac: {binary}\nAdd its directory to PATH for `jac run`. No live credentials are needed for checks.")
        return 0
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
