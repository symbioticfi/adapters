# Plan 006: Decode executor steps once when benchmarks improve (O06)

> Execute only when implementation is requested. This is a benchmark-gated refactor. A correct change with no qualifying gas improvement is REJECTED, not DONE; preserve the previous production implementation.

## Status

- Priority: P2
- Effort: S
- Risk: LOW semantics / MED performance
- Depends on: plans 004 and 005 DONE, for frozen lending fixtures and final builder baseline
- Category: perf
- Planned at: commit 901c82ca0339d27748af414e537a6d47a0643ec3, 2026-10-12
- Repository: /Users/andreikorokhov/symbiotic/adapters
- State: TODO

## Why this matters

Executor steps routed to the shared interpreter extract their opcode and payload twice. Passing the first extraction into the interpreter may remove repeated work. via-IR stack pressure can offset the saving, so adoption requires gains across representative executor workloads with no regression in the measured capability/control matrix.

## Current state

src/contracts/merkle-adapter/automations/RecipeExecutor.sol:74 and :118:

```solidity
(uint8 operation, bytes calldata operationData) = _step(steps[state.index]);
// Manage/Approve/ClearApproval dispatch remains unchanged.
state.values[state.index] = _run(queries, steps, inputs, state);
```

src/contracts/merkle-adapter/Recipes.sol:42–46:

```solidity
function _run(bytes[] calldata queries, bytes[] calldata steps, uint256[] calldata inputs, State memory state)
    internal
    returns (uint256)
{
    (uint8 operation, bytes calldata operationData) = _step(steps[state.index]);
    // Existing interpreter dispatch.
}
```

RecipeCapability.execute at line 24 calls _run without an earlier extraction. _step at Recipes.sol:107–108 indexes byte zero then slices [1:]; an empty step must retain its current panic. Only these two production wrappers call this shared _run. _value validates source bits, earlier numerical producers and input bounds; _bind resolves bindings in order. They are not this optimization.

docs/RECIPE-EXECUTOR.md:152–181 specifies runtime entry consumption and conditional/cached-read behavior. Manage decodes committed gate/leaves/bindings before resolving its gate; skipped Manage still consumes a runtime slot. Capability calls are self-call-only in account context. Preserve all of this and exact failure order.

Production SHA-256 pins before this plan: Recipes.sol f6c8f8f3c7298213d1234dc021bf1233b3397d94f64abc584ef117a9ef8609a1; RecipeExecutor.sol c01adfc0a61f0a1aacd9cdc38290dceb1b87202cf80f3c963ec308aa07248806; RecipeCapability.sol eeca127e6c26ec3dbd8bf00bd9fc00666973a96750c5406e8ec9b2801c066803. Plans 004/005 do not change these sources; use their recorded DONE evidence for expected test/snapshot/doc differences.

```sh
git diff --stat 901c82ca0339d27748af414e537a6d47a0643ec3..HEAD -- src/contracts/merkle-adapter/Recipes.sol src/contracts/merkle-adapter/automations/RecipeExecutor.sol src/contracts/merkle-adapter/capabilities/RecipeCapability.sol
shasum -a 256 src/contracts/merkle-adapter/Recipes.sol src/contracts/merkle-adapter/automations/RecipeExecutor.sol src/contracts/merkle-adapter/capabilities/RecipeCapability.sol
rg -n '_run\(|is Recipes' src --glob '*.sol'
```

## Toolchain and repository conventions

Run from /Users/andreikorokhov/symbiotic/adapters, or an isolated checkout containing the **complete current working-tree baseline**. HEAD alone does not contain the completed claim/recovery changes. Never reset, clean, or overwrite existing edits.

```sh
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
"$RECIPE_FORGE" --version
```

Expected: Foundry 1.8.1. foundry.toml pins Solidity 0.8.37, via-IR, optimizer 200, Osaka and bytecode_hash=none. Do not install/upgrade dependencies or change compilation settings. If this executable is unavailable, stop and report the missing pinned toolchain.

Follow the supplied AGENTS.md: implementation pragmas ^0.8.28; retain library/test feature-minimum pragmas; store contracts as address and cast at calls; named struct initializers; alphabetic grouped imports; no new argument-bearing repository errors; no single-use production helper or local alias except required evaluation/tuple/assembly locals. Preserve public interfaces and NatSpec. Existing builder/library code uses returned packed operands rather than guessed indices. New gas tests use vm.snapshotGasLastCall immediately after executor/account execution, have the default.isolate annotation, and are not fuzzed.

Planning does not authorize implementation, commits, push, PR creation or publication. When implementation is requested, preserve the active baseline. Any separately requested new branch uses the codex/ prefix; authorized commits must be signed and conventional. Existing recipes and deployed executors do not adopt local changes automatically.

## Dirty baseline and drift

Before editing, compare the Current state excerpts and production SHA-256 pins below with live files, inspect git status, and run the committed-head drift check. Explain any mismatch before proceeding. Previously completed predecessor changes explicitly described in this plan are permitted; unrelated drift is a stop condition.

```sh
git status --short
python3 plans/recipe_plan_checks.py inventory
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract RecipeManifestBuildTest --match-test test_AllExamplesManifestMatchesCommittedInstructionsAndRuntimeSlots --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py snapshot 006 out/plan006/baseline
```

Expected: catalogue passes; the helper records hashes/modes/status of tracked and untracked nonignored files and copies scoped files plus all twelve generated outputs into ignored out/plan006/baseline. Resolve existing stale/missing examples as separate upstream work before starting. Never replace evidence. Add tests only after capturing this baseline; capture gas only after the complete benchmark fixture code is frozen and before editing production.

The helper's check compares against this dirty baseline, not HEAD. restore-generated may restore only formatting-only differences outside scope and refuses semantic drift. Treat concurrent changes as drift requiring investigation, not changes to delete. out/plan006/ is ignored evidence, not an allowed place to hide source changes.

## Scope

Allowed modifications only:

- src/contracts/merkle-adapter/Recipes.sol, automations/RecipeExecutor.sol and capabilities/RecipeCapability.sol.
- test/adapters/merkle-adapter/RecipeDecodeOptimization.t.sol (create).
- docs/RECIPE-EXECUTOR.md for measured interpreter behavior/limitations.

- snapshots/RecipeExecutor.json, RecipeCapability.json, RecipeTuple.json, RecipeLending.json, RecipeRecovery.json, RecipeClaims.json and LLExecuting.json.
- snapshots/gas.txt and snapshots/sizes.txt only for final required regeneration.

- This plan and plans/README.md status/evidence.

Existing benchmark test files are read-only. Do not change interfaces, selectors, external ABI, errors, opcode/schema/version constants, builder templates, saved examples/manifests, account authorization, Manage/approval logic, generic binding/operand decoders, dependencies, compiler settings, state layouts or sibling code. Do not optimize returndata copying here. Do not widen the scope helper.

## Steps

### 1. Verify predecessor completion and add a frozen reference

Confirm 004/005 are DONE with their recorded gates; if either is rejected or blocked, stop and revise this plan's fixture requirements rather than silently substituting another baseline.

Create RecipeDecodeOptimization.t.sol with RecipeDecodeOptimizationTest and a test-only harness inheriting Recipes. Before production edits, copy the current shared _run body into an explicitly named baseline function that retains its _step extraction. The harness exposes legacy and proposed-loop execution entries at the **same deployed address**, creating fresh State for each. For the proposed entry, mimic executor extraction and route into live _run; adapt only that test call when the production internal signature changes. Keep the baseline body frozen. It may use unchanged _step/_value/_bind helpers; record their hashes/body identity.

Compare low-level success flags and **complete return/revert bytes**, then state effects after restoring the same initial mock state. Do not compare different caller addresses or replace observed full-width values with uint216 literals. Keep the reference test-only; do not ship a legacy production path.

Test every shared opcode, full-width numerical inputs/results, checked add/sub/MUL_DIV panics, invalid source/input/result references, nonnumerical/forward references, empty/malformed steps, malformed/trailing payloads, binding failure order, active/skipped ReadIf and CallIf, query failures/offsets, full ReadCached/ReadWord identity and unknown opcodes. Existing RecipeExecutorReview, RecipePacking, RecipeTuple and RecipeCapability fixtures provide the encoding patterns. Existing real-account tests remain the authorization/action/rollback oracle.

```sh
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract RecipeDecodeOptimizationTest --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

Expected: all differential characterization cases pass against the unchanged implementation. Unlike a correctness fix, no semantic test is expected to fail before this refactor.

### Capture the unchanged production workload matrix

Plans 004/005 provide the stable lending fixtures and final builder bytes. The following existing tests provide fourteen required gas labels: lending O04Sync/O04Async; recovery recovery/O01TwoActiveSources/O01TwoActiveClaims; standalone claim claimRedemptionWithdrawalMintRewards; LL O03LLPositiveMinimum; capability executeChecksAndBindings/executeReadAndCheck/executeEmpty; tuple ordinaryTupleReads/cachedTupleReads; executor executeCall/executeRead. Read their assertions and preserve them.

```sh
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan006/before UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^(RecipeLendingTest|RecipeRecoveryTest|RecipeClaimsTest|LLExecutingTest|RecipeCapabilityTest|RecipeTupleTest|RecipeExecutorTest)$' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
"$RECIPE_FORGE" inspect RecipeExecutor abi --json > out/plan006/before/RecipeExecutor.abi.json
"$RECIPE_FORGE" inspect RecipeCapability abi --json > out/plan006/before/RecipeCapability.abi.json
```

Expected: all suites pass and all fourteen labels exist under before/. Capture deployed bytecode lengths from out/RecipeExecutor.sol/RecipeExecutor.json and out/RecipeCapability.sol/RecipeCapability.json into the plan's evidence before editing production; strip an optional 0x prefix and divide deployedBytecode.object's length by two. Also freeze a copy/hash of every benchmark test source under ignored evidence. Do not modify benchmark code between measurements.

### 2. Pass the extracted opcode and payload

Change the internal _run signature to accept uint8 operation and bytes calldata operationData in addition to its existing query/step/input/state arguments. Remove its local _step extraction. RecipeExecutor passes its existing pair; RecipeCapability extracts once in its loop and passes that pair. Keep extraction inside each loop at the same effective evaluation position; do not hoist payload resolution, add eager operand/query decoding, change dispatch order or specialize action behavior.

Adapt the proposed test harness entry's internal call only; its frozen reference and test inputs/assertions remain identical. No other production _run caller is expected; stop if discovery contradicts that fact.

```sh
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^(RecipeDecodeOptimizationTest|RecipeExecutor.*Test|RecipeCapabilityTest|RecipeTupleTest|RecipePackingTest|RecipeOptimizationTest)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
rg -n '_step\(' src/contracts/merkle-adapter/Recipes.sol src/contracts/merkle-adapter/automations/RecipeExecutor.sol src/contracts/merkle-adapter/capabilities/RecipeCapability.sol
```

Expected: all tests pass; exactly one extraction call appears in each wrapper, and Recipes contains only the _step declaration, no invocation from _run. References to producer opcode bytes in _value/ReadWord remain unchanged.

### Verify gas, ABI and commitments

Repeat the identical workload matrix with FOUNDRY_SNAPSHOTS=out/plan006/after. Test files and environment must match before; production code is the only difference. Then run:

```sh
python3 plans/recipe_plan_checks.py gas 006 out/plan006
"$RECIPE_FORGE" inspect RecipeExecutor abi --json > out/plan006/after/RecipeExecutor.abi.json
"$RECIPE_FORGE" inspect RecipeCapability abi --json > out/plan006/after/RecipeCapability.abi.json
python3 - <<'PY'
import json
from pathlib import Path
evidence = Path('out/plan006')
for name in ('RecipeExecutor', 'RecipeCapability'):
    assert json.loads((evidence / 'before' / (name + '.abi.json')).read_text()) == json.loads((evidence / 'after' / (name + '.abi.json')).read_text()), name
    artifact = json.loads(Path('out', name + '.sol', name + '.json').read_text())
    size = len(artifact['deployedBytecode']['object'].removeprefix('0x')) // 2
    assert size <= 24576, (name, size)
    print(name, 'deployed bytes:', size)
PY
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract RecipeManifestBuildTest --match-test test_AllExamplesManifestMatchesCommittedInstructionsAndRuntimeSlots --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py check-generated 006 out/plan006/baseline
```

Expected: all gas criteria pass, both public ABIs are identical, both implementations remain under 24,576 deployed bytes, and all twelve saved generated files retain exact baseline bytes. Record size differences and any added deployment cost separately from execution savings. Do not regenerate recipe manifests or change hash/schema/version constants for an internal runtime optimization.

Gas acceptance is explicit in recipe_plan_checks.py: all fourteen labels must be no worse; all seven executor template labels (two lending, three recovery, standalone claim, LL) must be strictly lower. This conservative gate prevents compiler/stack regressions from being hidden by an aggregate or toy arithmetic workload.

If the gate fails, do not widen scope or weaken it. Remove only this plan's production refactor using the captured dirty-baseline diff, confirm original behavior/bytes and mark REJECTED with measured results. Keep useful differential evidence/tests if desired; do not restore unrelated files or HEAD wholesale.

## Final local verification

After the focused semantic and gas gates pass, run:

```sh
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^(RecipeDecodeOptimizationTest|RecipeExecutor.*Test|RecipeCapabilityTest|RecipeTupleTest|RecipePackingTest|RecipeOptimizationTest|RecipeLendingTest|RecipeRecoveryTest|RecipeClaimsTest|LLExecutingTest|RecipeBuildTest|RecipeStagesTest|RecipeManifestBuildTest|RecipeManifestTest)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^(RecipeExecutorTest|RecipeCapabilityTest|RecipeTupleTest|RecipeLendingTest|RecipeRecoveryTest|RecipeClaimsTest|LLExecutingTest)$' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
"$RECIPE_FORGE" build --offline
"$RECIPE_FORGE" fmt --check
git diff --check
python3 plans/recipe_plan_checks.py check 006 out/plan006/baseline
```

Expected: all scoped tests, build, formatting and dirty-scope checks pass. Snapshot emission is restricted to the groups allowed by this plan; do not regenerate unrelated JSON snapshot files. Format only modified in-scope files if a check fails. Check modified Markdown/JSON with pnpm dlx prettier@3.9.6 --check, naming the individual modified files; do not format the repository.

For the final integrated gate, mirror the repository hook with the pinned compiler and serial tests. Each command below must exit zero before running the next; do not extract a report from a failed test log.

```sh
"$RECIPE_FORGE" build --offline --sizes > snapshots/sizes.txt
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --no-match-contract '.*(Mainnet|Benchmark|Invariant).*' --gas-report --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0 > out/plan006/full-local.log 2>&1
sed -n '/^╭/,/^╰/p' out/plan006/full-local.log > snapshots/gas.txt
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '.*Invariant.*' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
git diff --check
python3 plans/recipe_plan_checks.py check 006 out/plan006/baseline
```

Expected: all runnable local and invariant tests pass. Four optional config/live skips existed in the preceding validation; record actual skips and investigate new ones. Serial execution avoids the known testnet TESTNET_MANIFEST fixture race. Aggregate gas/size reports describe the entire dirty checkout, including pre-existing unrelated work. Every saved recipe/guarded fixture must remain byte-identical to the post-005 baseline.

Record commands, before/after gas, source/artifact changes and limitations in this plan and its index row. Local verification does not establish hosted CI, sibling Go/frontend compatibility, live wallet/chain behavior or deployment.

## Done criteria

- [ ] Frozen same-context reference agrees on values, effects and full revert bytes for the shared-opcode matrix.
- [ ] One extraction per wrapper; none inside shared _run; action and operand decoding order unchanged.
- [ ] All seven representative executor template measurements strictly improve; all fourteen measurements are nonregressing.
- [ ] Public ABIs, all saved recipe bytes/commitments/runtime maps and authorization remain unchanged.
- [ ] Code-size, scoped/full-local/invariant/format/snapshot/scope gates pass; this plan and index record DONE with evidence.

## STOP conditions and maintenance

Stop on predecessor failure, source drift, an additional production caller requiring out-of-scope edits, changed failure ordering/encoding/caller behavior, a need to change schema/actions/dependencies, two unsuccessful focused repairs or any gas gate failure. Performance failure requires REJECTED or a revised authorized plan, not relaxed assertions.

Compiler upgrades can change inlining and stack spilling. Retain representative benchmarks and repeat them when the IR/compiler configuration changes. O07 must use the terminal outcome and measured production baseline from this plan; do not combine both optimizations in one before/after claim.
