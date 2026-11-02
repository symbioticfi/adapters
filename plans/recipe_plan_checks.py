#!/usr/bin/env python3
"""Preserve the dirty baseline and verify recipe plan scopes and measurements.

Run from the repository root. Snapshot/restore are for authorized implementation
only; inventory just lists the generator's complete output set.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess


PLANS = {
    "001": {
        "script/recipes/ClaimRecipe.sol",
        "test/adapters/merkle-adapter/RecipeClaims.t.sol",
        "docs/RECIPE-CLAIMS.md",
        "script/recipes/examples/manifests/claim.json",
        "script/recipes/examples/manifests/claim-bounded.json",
        "snapshots/RecipeClaims.json",
        "plans/001-claim-progress-maxima.md",
    },
    "002": {
        "script/recipes/ClaimRecipe.sol",
        "script/recipes/RecoveryRecipe.sol",
        "script/recipes/LLExecuting.sol",
        "test/adapters/merkle-adapter/RecipeClaims.t.sol",
        "test/adapters/merkle-adapter/RecipeRecovery.t.sol",
        "test/adapters/merkle-adapter/LLExecuting.t.sol",
        "docs/RECIPE-CLAIMS.md",
        "docs/HEALTH-RECOVERY-RECIPE.md",
        "docs/RECIPE-EXECUTOR.md",
        "script/recipes/examples/manifests/claim.json",
        "script/recipes/examples/manifests/claim-bounded.json",
        "script/recipes/examples/manifests/health-claim.json",
        "script/recipes/examples/manifests/health-claim-ready.json",
        "script/recipes/examples/manifests/ll-executing.json",
        "script/recipes/examples/manifests/ll-cooldown.json",
        "snapshots/RecipeClaims.json",
        "snapshots/RecipeRecovery.json",
        "snapshots/LLExecuting.json",
        "plans/002-implied-positivity-guards.md",
    },
    "003": {
        "script/recipes/RecoveryRecipe.sol",
        "test/adapters/merkle-adapter/RecipeRecovery.t.sol",
        "docs/HEALTH-RECOVERY-RECIPE.md",
        "docs/RECIPE-EXECUTOR.md",
        "snapshots/RecipeRecovery.json",
        "plans/003-recovery-cash-snapshots.md",
    },
    "004": {
        "script/recipes/LendingRecipe.sol",
        "test/adapters/merkle-adapter/RecipeLending.t.sol",
        "docs/RECIPE-EXECUTOR.md",
        "script/recipes/examples/manifests/lending.json",
        "script/recipes/examples/manifests/lending-async.json",
        "snapshots/RecipeLending.json",
        "plans/004-lending-implied-positivity.md",
    },
    "005": {
        "script/recipes/RecoveryRecipe.sol",
        "test/adapters/merkle-adapter/RecipeRecovery.t.sol",
        "docs/HEALTH-RECOVERY-RECIPE.md",
        "script/recipes/examples/manifests/health-recovery.json",
        "snapshots/RecipeRecovery.json",
        "plans/005-initial-recovery-health-clamp.md",
    },
    "006": {
        "src/contracts/merkle-adapter/Recipes.sol",
        "src/contracts/merkle-adapter/automations/RecipeExecutor.sol",
        "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol",
        "test/adapters/merkle-adapter/RecipeDecodeOptimization.t.sol",
        "docs/RECIPE-EXECUTOR.md",
        "plans/006-decode-executor-steps-once.md",
    },
    "007": {
        "src/contracts/merkle-adapter/Recipes.sol",
        "test/adapters/merkle-adapter/RecipeReturnDataOptimization.t.sol",
        "snapshots/RecipeReturnData.json",
        "docs/RECIPE-EXECUTOR.md",
        "plans/007-selective-return-data-copies.md",
    },
}
COMMON = {"snapshots/gas.txt", "snapshots/sizes.txt", "plans/README.md"}
RUNTIME_SNAPSHOTS = {
    f"snapshots/{group}.json"
    for group in (
        "RecipeExecutor", "RecipeCapability", "RecipeTuple", "RecipeLending",
        "RecipeRecovery", "RecipeClaims", "LLExecuting",
    )
}
for runtime_plan in ("006", "007"):
    PLANS[runtime_plan] |= RUNTIME_SNAPSHOTS

RUNTIME_WORKLOADS = [
    ("RecipeLending", "O04Sync"),
    ("RecipeLending", "O04Async"),
    ("RecipeRecovery", "recovery"),
    ("RecipeRecovery", "O01TwoActiveSources"),
    ("RecipeRecovery", "O01TwoActiveClaims"),
    ("RecipeClaims", "claimRedemptionWithdrawalMintRewards"),
    ("LLExecuting", "O03LLPositiveMinimum"),
    ("RecipeCapability", "executeChecksAndBindings"),
    ("RecipeCapability", "executeReadAndCheck"),
    ("RecipeCapability", "executeEmpty"),
    ("RecipeTuple", "ordinaryTupleReads"),
    ("RecipeTuple", "cachedTupleReads"),
    ("RecipeExecutor", "executeCall"),
    ("RecipeExecutor", "executeRead"),
]
GAS_GATES = {
    "004": {
        "labels": [("RecipeLending", "O04Sync"), ("RecipeLending", "O04Async")],
        "strict": [("RecipeLending", "O04Sync"), ("RecipeLending", "O04Async")],
    },
    "005": {
        "labels": [
            ("RecipeRecovery", label) for label in (
                "recovery", "O01TwoActiveSources", "O01OneActiveGroup",
                "O03HealthClaim", "repaySettledCash",
            )
        ],
        "strict": [
            ("RecipeRecovery", label)
            for label in ("recovery", "O01TwoActiveSources", "O01OneActiveGroup")
        ],
        "equal": [("RecipeRecovery", "O03HealthClaim"), ("RecipeRecovery", "repaySettledCash")],
    },
    "006": {"labels": RUNTIME_WORKLOADS, "strict": RUNTIME_WORKLOADS[:7]},
    "007": {
        "labels": RUNTIME_WORKLOADS + [
            ("RecipeReturnData", label) for label in (
                "scalar32", "tuple128", "ignoredCallEmpty", "ignoredCall32",
                "readIfSkipped", "callIfSkipped", "cached128",
            )
        ],
        "any_lower": RUNTIME_WORKLOADS[:9] + [("RecipeTuple", "ordinaryTupleReads")],
    },
}


def git(*args):
    return subprocess.check_output(["git", *args])


def generated_outputs():
    outputs = set()
    for source in Path("script/recipes/examples").glob("*.json"):
        outputs.add(f"script/recipes/examples/manifests/{source.name}")
        config = json.loads(source.read_text())
        if config.get("template") == "3f-executing" and config.get("policy", {}).get("guardedMint", True):
            outputs.add(f"script/recipes/examples/fixtures/{source.name}")
    return sorted(outputs)


def inventory():
    paths = set(os.fsdecode(p) for p in git("ls-files", "-z", "--cached", "--others", "--exclude-standard").split(b"\0") if p)
    result = {}
    for name in sorted(paths):
        path = Path(name)
        if path.is_symlink():
            data = os.fsencode(os.readlink(path))
            result[name] = {"kind": "symlink", "sha256": hashlib.sha256(data).hexdigest()}
        elif path.is_file():
            result[name] = {
                "kind": "file",
                "mode": stat.S_IMODE(path.stat().st_mode),
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
    return result


def snapshot(plan, baseline):
    if baseline.exists():
        raise SystemExit(f"Baseline already exists: {baseline}; do not replace evidence.")
    if not baseline.resolve().is_relative_to(Path("out").resolve()):
        raise SystemExit("Baseline must be inside this repository's ignored out/ directory.")
    if subprocess.run(["git", "check-ignore", "-q", str(baseline)]).returncode != 0:
        raise SystemExit("Baseline is not ignored; stop before copying files.")
    outputs = generated_outputs()
    missing = [name for name in outputs if not Path(name).is_file() or Path(name).is_symlink()]
    if missing:
        raise SystemExit("Baseline catalogue is incomplete; resolve upstream before starting: " + ", ".join(missing))
    baseline.mkdir(parents=True)
    state = {"plan": plan, "files": inventory(), "generated": outputs}
    (baseline / "state.json").write_text(json.dumps(state, indent=2) + "\n")
    (baseline / "status.txt").write_bytes(git("status", "--porcelain=v1", "--untracked-files=all"))
    for name in sorted(set(outputs) | PLANS[plan] | COMMON):
        source = Path(name)
        if source.is_file() and not source.is_symlink():
            target = baseline / "copies" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    print(f"Saved baseline for Plan{plan}: {baseline}; {len(outputs)} generated outputs.")


def read_state(plan, baseline):
    state = json.loads((baseline / "state.json").read_text())
    if state["plan"] != plan:
        raise SystemExit("Wrong plan's baseline directory.")
    if state["generated"] != generated_outputs():
        raise SystemExit("Example catalogue changed during execution; stop and explain the drift.")
    return state


def restore_generated(plan, baseline):
    state = read_state(plan, baseline)
    restores = []
    for name in state["generated"]:
        if name in PLANS[plan]:
            continue
        current = Path(name)
        saved = baseline / "copies" / name
        if not current.is_file() or current.is_symlink():
            raise SystemExit(f"Generated output missing or replaced: {name}; do not restore blindly.")
        original = state["files"][name]
        if original["kind"] != "file" or stat.S_IMODE(current.stat().st_mode) != original["mode"]:
            raise SystemExit(f"Unexpected generated file kind/mode change: {name}; nothing restored.")
        if current.read_bytes() == saved.read_bytes():
            continue
        current_json = json.dumps(json.loads(current.read_text()), sort_keys=True, separators=(",", ":"))
        saved_json = json.dumps(json.loads(saved.read_text()), sort_keys=True, separators=(",", ":"))
        if current_json != saved_json:
            raise SystemExit(f"Unexpected generated semantic change: {name}; nothing restored.")
        restores.append((current, saved))
    for current, saved in restores:
        shutil.copy2(saved, current)
        print(f"Restored formatting-only change: {current}")
    print("All generated outputs outside scope retain baseline semantics and bytes.")


def check(plan, baseline):
    state = read_state(plan, baseline)
    current = inventory()
    changed = sorted(name for name in state["files"].keys() | current.keys() if state["files"].get(name) != current.get(name))
    outside = [name for name in changed if name not in PLANS[plan] | COMMON]
    if outside:
        raise SystemExit("Changes outside plan scope, including prior edits or concurrent work; stop and investigate:\n" + "\n".join(outside))
    print(f"Scope passes for Plan{plan}; {len(changed)} paths changed relative to dirty baseline.")
    for name in changed:
        print(name)


def check_generated(plan, baseline):
    state = read_state(plan, baseline)
    mismatches = [
        name for name in state["generated"]
        if not Path(name).is_file() or Path(name).is_symlink()
        or Path(name).read_bytes() != (baseline / "copies" / name).read_bytes()
    ]
    if mismatches:
        raise SystemExit("Generated bytes changed:\n" + "\n".join(mismatches))
    print(f"All {len(state['generated'])} generated outputs match the dirty baseline byte for byte.")


def gas(plan, evidence):
    if plan not in GAS_GATES:
        raise SystemExit("Gas comparison is defined only for Plans 004-007.")
    gate = GAS_GATES[plan]
    comparisons = {}
    for group, label in gate["labels"]:
        values = []
        for phase in ("before", "after"):
            data = json.loads((evidence / phase / f"{group}.json").read_text())
            value = int(data[label])
            if value <= 0:
                raise SystemExit(f"Missing/invalid positive measurement: {phase}/{group}/{label}")
            values.append(value)
        before, after = values
        comparisons[(group, label)] = (before, after)
        print(f"{group}/{label}: {before} -> {after}")
        if after > before:
            raise SystemExit(f"Gas regression: {group}/{label}")
    for key in gate.get("strict", []):
        before, after = comparisons[key]
        if after >= before:
            raise SystemExit(f"Required improvement absent: {'/'.join(key)}")
    for key in gate.get("equal", []):
        before, after = comparisons[key]
        if after != before:
            raise SystemExit(f"Control workload changed: {'/'.join(key)}")
    if "any_lower" in gate and not any(
        comparisons[key][1] < comparisons[key][0] for key in gate["any_lower"]
    ):
        raise SystemExit("No representative recipe workload improved; synthetic savings alone do not qualify.")
    print(f"Gas acceptance passes for Plan{plan}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command", choices=["inventory", "snapshot", "restore-generated", "check", "check-generated", "gas"]
    )
    parser.add_argument("plan", choices=sorted(PLANS), nargs="?")
    parser.add_argument("baseline", type=Path, nargs="?")
    args = parser.parse_args()
    root = Path(os.fsdecode(git("rev-parse", "--show-toplevel")).strip())
    if root.resolve() != Path.cwd().resolve():
        raise SystemExit("Run from the repository root.")
    if args.command == "inventory":
        print("\n".join(generated_outputs()))
        return
    if args.plan is None or args.baseline is None:
        parser.error("This command requires PLAN and BASELINE arguments.")
    {
        "snapshot": snapshot, "restore-generated": restore_generated, "check": check,
        "check-generated": check_generated, "gas": gas,
    }[args.command](args.plan, args.baseline)


if __name__ == "__main__":
    main()
