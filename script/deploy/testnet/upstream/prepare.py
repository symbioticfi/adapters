"""Build pinned upstream projects with their own compiler configurations."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

from artifact import DEFAULT_CACHE, PINS


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def attest_build(root, descriptor):
    if git(root, "rev-parse", "HEAD") != descriptor["commit"]:
        raise ValueError("source commit does not match pinned descriptor")
    if git(root, "status", "--porcelain", "--untracked-files=no", "--ignore-submodules=untracked"):
        raise ValueError("modified upstream source")
    submodules = {}
    for line in git(root, "submodule", "status", "--recursive").splitlines():
        if line[0] in "-+U":
            raise ValueError("dependency pins do not match upstream gitlinks")
        commit, path, *_ = line.split()
        submodules[path] = commit
    if submodules != descriptor["submodules"]:
        raise ValueError("dependency pins do not match pinned descriptor")
    artifacts = {}
    for path in sorted((root / "out").rglob("*.json")):
        value = json.loads(path.read_text())
        if isinstance(value.get("bytecode"), dict) and value["bytecode"].get("object", "0x") != "0x":
            artifacts[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    if not artifacts:
        raise ValueError("no creation artifacts produced")
    (root / ".merkle-artifacts.json").write_text(json.dumps({"descriptor": descriptor, "artifacts": artifacts}, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profiles", nargs="*")
    parser.add_argument("--cache", type=Path, default=Path(os.environ.get("UPSTREAM_CACHE_DIR", DEFAULT_CACHE)))
    args = parser.parse_args()
    pins = json.loads(PINS.read_text())
    for profile in args.profiles or pins:
        descriptor = pins[profile]
        root = args.cache / profile
        if not root.exists():
            root.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["git", "clone", "--no-checkout", descriptor["repository"], str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "checkout", "--detach", descriptor["commit"]], check=True)
        if git(root, "rev-parse", "HEAD") != descriptor["commit"]:
            raise ValueError(f"{profile}: source commit does not match; use a fresh cache")
        if git(root, "status", "--porcelain", "--untracked-files=no", "--ignore-submodules=untracked"):
            raise ValueError(f"{profile}: modified upstream source")
        subprocess.run(["git", "-C", str(root), "submodule", "update", "--init", "--recursive"], check=True)
        for command in descriptor["build"]:
            subprocess.run(command, cwd=root, check=True, env={k: v for k, v in os.environ.items() if not k.startswith("FOUNDRY_")})
        attest_build(root, descriptor)
        print(f"Prepared {profile} at {descriptor['commit']}", flush=True)


if __name__ == "__main__":
    main()
