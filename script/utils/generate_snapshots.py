#!/usr/bin/env python3
"""Generate stable size and gas reports, failing when Forge checks fail."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SNAPSHOTS_DIR = ROOT / "snapshots"


def run_forge(*args: str, profile: str | None = None) -> str:
    env = os.environ.copy()
    if profile is not None:
        env["FOUNDRY_PROFILE"] = profile
    result = subprocess.run(
        ["forge", *args], cwd=ROOT, env=env, capture_output=True, text=True
    )
    if result.returncode:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    for line in result.stdout.splitlines():
        if line.startswith("Ran ") and "test suites in " in line:
            print(line, flush=True)
    return result.stdout


def report_tables(output: str) -> str:
    tables: list[str] = []
    current: list[str] | None = None
    for line in output.splitlines():
        if line.startswith("╭"):
            current = []
        if current is not None:
            current.append(line)
            if line.startswith("╰"):
                tables.append("\n".join(current))
                current = None
    if not tables:
        raise ValueError("Forge output did not contain any report tables")
    return "\n\n".join(sorted(tables)) + "\n"


def main() -> None:
    run_forge("build")
    sizes = report_tables(run_forge("build", "--sizes"))
    gas = report_tables(run_forge(
        "test",
        "--isolate",
        "--no-match-contract",
        ".*(Mainnet|Benchmark|Invariant).*",
        "--gas-report",
        "--threads",
        "1",
        "--fuzz-seed",
        "0",
        profile="snapshots",
    ))
    run_forge(
        "test",
        "--isolate",
        "--match-contract",
        ".*Invariant.*",
        "--threads",
        "1",
        "--fuzz-seed",
        "0",
        profile="snapshots",
    )
    SNAPSHOTS_DIR.mkdir(parents=True, exist_ok=True)
    (SNAPSHOTS_DIR / "sizes.txt").write_text(sizes)
    (SNAPSHOTS_DIR / "gas.txt").write_text(gas)


if __name__ == "__main__":
    main()
