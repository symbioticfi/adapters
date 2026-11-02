#!/usr/bin/env python3
"""Compile in bounded groups, then verify the complete Foundry build."""

from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[2]


def build_project() -> None:
    sources = sorted(
        str(path.relative_to(ROOT))
        for directory in ("src", "script", "test")
        for path in (ROOT / directory).rglob("*.sol")
    )
    for start in range(0, len(sources), 10):
        subprocess.run(["forge", "build", *sources[start:start + 10]], cwd=ROOT, check=True)
    subprocess.run(["forge", "build"], cwd=ROOT, check=True)


if __name__ == "__main__":
    build_project()
