# Plan 005: Omit only the initial recovery health clamp (O05)

> Execute only when implementation is requested. Follow each gate in order. Stop on the conditions below and update this plan and its index row with evidence.

## Status

- Priority: P2
- Effort: S
- Risk: LOW
- Depends on: none semantically; execute after 004 for a stable serial baseline
- Category: perf
- Planned at: commit 901c82ca0339d27748af414e537a6d47a0643ec3, 2026-10-12
- Repository: /Users/andreikorokhov/symbiotic/adapters
- State: DONE

## Why this matters

The initial recovery health is checked against the trigger before its target repayment is calculated. Configuration already requires the target to exceed that trigger, so the initial Min(health,target) adds an instruction without changing successful arithmetic. Removing just that clamp projects the saved recovery example from 97 to 96 instructions and saves 160 encoded bytes. Later health snapshots still need their clamp.

## Current state and boundaries

script/recipes/RecoveryRecipe.sol:116–119:

```solidity
Snapshot memory initial = _snapshot(builder, config);
builder.check(OP_LESS_OR_EQUAL, initial.health, builder.literal(config.triggerHealthFactor));
uint256 budget =
    builder.binary(OP_MIN, _need(builder, config, initial), builder.literal(config.maxRepayment));
```

_start at lines 340–343 rejects zero trigger, target <= trigger, zero maxRepayment and debtTolerance > 1. _need at lines 372–379 emits:

```solidity
return builder.binary(
    OP_SUB,
    state.debt,
    builder.mulDiv(
        state.debt,
        builder.binary(OP_MIN, state.health, builder.literal(config.targetHealthFactor)),
        builder.literal(config.targetHealthFactor)
    )
);
```

The retained trigger check proves initial.health <= trigger < target. For this snapshot only, min(initial.health,target) equals initial.health. Keep the checked debt * health / target, outer debt subtraction and budget cap. Do not cancel factors or infer the same bound for afterRepay, claim, or settled-cash repayment.

docs/HEALTH-RECOVERY-RECIPE.md:51–95 documents the fresh health/debt target formula, ordered cash sources, partial progress and the shared cap on newly funded recovery. Preserve F01's subtraction of all pending from full unmet need before capping new requests. Preserve O01's conditional cash carry and reads around approvals.

RecipeRecoveryTest uses real executor/account/capability authorization and RecoveryAaveMock.setPosition. Existing recovery, O01TwoActiveSources and O01OneActiveGroup gas fixtures measure affected paths; O03HealthClaim and repaySettledCash are unchanged controls. test_O01CashPrefixReadsAreMinimal pins the ordinary recovery hash and conditional recovery count/length: these **must deliberately change for O05**, while its claim hash/count and cash-read assertions must remain exact.

Production SHA-256: RecoveryRecipe.sol = 17abcd3200c9ec2699d90251c1ed347201fa71c46c8091a392aaeea75b909a2a.

```sh
git diff --stat 901c82ca0339d27748af414e537a6d47a0643ec3..HEAD -- script/recipes/RecoveryRecipe.sol test/adapters/merkle-adapter/RecipeRecovery.t.sol docs/HEALTH-RECOVERY-RECIPE.md
shasum -a 256 script/recipes/RecoveryRecipe.sol
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
python3 plans/recipe_plan_checks.py snapshot 005 out/plan005/baseline
```

Expected: catalogue passes; the helper records hashes/modes/status of tracked and untracked nonignored files and copies scoped files plus all twelve generated outputs into ignored out/plan005/baseline. Resolve existing stale/missing examples as separate upstream work before starting. Never replace evidence. Add tests only after capturing this baseline; capture gas only after the complete benchmark fixture code is frozen and before editing production.

The helper's check compares against this dirty baseline, not HEAD. restore-generated may restore only formatting-only differences outside scope and refuses semantic drift. Treat concurrent changes as drift requiring investigation, not changes to delete. out/plan005/ is ignored evidence, not an allowed place to hide source changes.

## Scope

Allowed modifications only:

- script/recipes/RecoveryRecipe.sol.
- test/adapters/merkle-adapter/RecipeRecovery.t.sol, including test-only query fixtures.
- docs/HEALTH-RECOVERY-RECIPE.md for the initial-bound specialization and measurement.
- script/recipes/examples/manifests/health-recovery.json.
- snapshots/RecipeRecovery.json; snapshots/gas.txt and snapshots/sizes.txt for final regeneration.
- This plan and plans/README.md status/evidence.

Do not change _need's behavior for later snapshots, claim/repay semantics, F01/O01–O03 effects, debt tolerance, example inputs, generic range inference, other templates, runtime consumers, permissions or sibling code. Do not widen the planning helper's scope.

## Steps

### 1. Freeze observations and add the reduction test

Save current recovery/claim/repay recipe hashes, query bytes, runtime maps and named results in ignored evidence. Add test_O05InitialHealthClampReducesInstructions, building ordinary and conditional recovery and inspecting the initial trigger/need sequence. Require the initial health operand to go directly into the checked MUL_DIV and one fewer step / 160 bytes versus the recorded baseline. Later need calculations must still use their own Min. Claim/repay bytes must remain unchanged.

Capture gas using unchanged existing benchmark methods; add all characterization tests before this capture so benchmark setup, mocks and measured methods stay unchanged afterward. The unrelated O01 recovery commitment/count/length assertions listed in step 2 are the only permitted later test-source changes; record that diff, and do not alter benchmark bodies or setup. Keep the intended reduction test out of this passing benchmark selection.

Add test_O05Semantic*/testFuzz_O05Semantic* semantic cases for health zero, below/equal/above trigger; valid target just above trigger; invalid target <= trigger; zero debt; partial capacity, requests-only progress, repayment budget and prior pending coverage. Use real-account effects/rollback for representable Aave positions. For exact raw-health/debt and full-width products, add a test-only query lens in the same file; do not overflow the fixture's collateral*1e18 formula before reaching the recipe arithmetic. Assert Panic(0x11) on overflowing debt*health and unchanged CheckFailed when the trigger rejects first.

Verify a fresh later health above target remains clamped. Preserve zero-debt claim behavior with maximum health, claim-at-target surplus, settled-cash reserve and all three F01 regression tests. Before production edits, these semantic tests must pass; only the structural target should fail.

```sh
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract RecipeRecoveryTest --match-test '^test(Fuzz)?_O05Semantic' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

Expected: all characterization tests pass before production edits. Finish adding tests and freeze setup/mocks/benchmark methods before capturing gas below.

```sh
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan005/before UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract RecipeRecoveryTest --match-test '^(test_RecoveryWithdrawsMorphoThenAaveRepaysThenRequestsInOrder|test_GasO01TwoActiveSources|test_GasO01OneActiveGroup|test_GasO03HealthClaim|test_RepayUsesPreviouslySettledCashAndPreservesReserve)\(\)$' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
"$RECIPE_FORGE" test --offline --match-contract RecipeRecoveryTest --match-test test_O05InitialHealthClampReducesInstructions --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

Expected: five benchmark tests pass, with five baseline labels; the structural test fails because initial Min is still present.

### 2. Specialize the initial expression only

Inline the existing checked debt-minus-MUL_DIV calculation at the initial budget site, passing initial.health directly. Preserve its evaluation position after the trigger and before source actions. Leave the reusable _need implementation and all later callers unchanged. Do not add a generic optimization option or a single-use helper.

Update test_O01CashPrefixReadsAreMinimal only for the intentional recovery changes: conditional recovery 98→97 and 21,696→21,536 encoded bytes; refresh the ordinary recovery hash from the generated recipe after verifying the sole reduction. Its claim hash 1907dc1d8784938d4049e6c5184873f2292a6caa66973d47cb31d2c8142aaff7, claim count 57 and claim length 12,064 remain unchanged. Preserve prefix counts and approval/cleanup barriers.

```sh
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract RecipeRecoveryTest --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan005/after UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract RecipeRecoveryTest --match-test '^(test_RecoveryWithdrawsMorphoThenAaveRepaysThenRequestsInOrder|test_GasO01TwoActiveSources|test_GasO01OneActiveGroup|test_GasO03HealthClaim|test_RepayUsesPreviouslySettledCashAndPreservesReserve)\(\)$' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py gas 005 out/plan005
```

Expected: all tests pass; three recovery labels strictly improve; claim and settled-cash labels stay exactly equal. If the controls change, investigate rather than changing their expectations.

### 3. Refresh only health-recovery

```sh
UPDATE_RECIPE_MANIFESTS=true "$RECIPE_FORGE" test --offline --match-contract RecipeManifestBuildTest --match-test test_AllExamplesManifestMatchesCommittedInstructionsAndRuntimeSlots --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py restore-generated 005 out/plan005/baseline
```

Expected: saved health-recovery has 96 instructions, removes initial index 4 Min, uses the initial health read directly at the shifted MUL_DIV, and preserves queries/action order/runtime slots. All later clamps remain. Other generated files retain exact baseline bytes, including health-claim and health-repay.

## Final local verification

After the focused semantic and gas gates pass, run:

```sh
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^(RecipeRecoveryTest|RecipeClaimsTest|RecipeBuildTest|RecipeStagesTest|RecipeManifestBuildTest|RecipeManifestTest|RecipeOptimizationTest)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^RecipeRecoveryTest$' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
"$RECIPE_FORGE" build --offline
"$RECIPE_FORGE" fmt --check
git diff --check
python3 plans/recipe_plan_checks.py check 005 out/plan005/baseline
```

Expected: all scoped tests, build, formatting and dirty-scope checks pass. Snapshot emission is restricted to the groups allowed by this plan; do not regenerate unrelated JSON snapshot files. Format only modified in-scope files if a check fails. Check modified Markdown/JSON with pnpm dlx prettier@3.9.6 --check, naming the individual modified files; do not format the repository.

For the final integrated gate, mirror the repository hook with the pinned compiler and serial tests. Each command below must exit zero before running the next; do not extract a report from a failed test log.

```sh
"$RECIPE_FORGE" build --offline --sizes > snapshots/sizes.txt
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --no-match-contract '.*(Mainnet|Benchmark|Invariant).*' --gas-report --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0 > out/plan005/full-local.log 2>&1
sed -n '/^╭/,/^╰/p' out/plan005/full-local.log > snapshots/gas.txt
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '.*Invariant.*' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
git diff --check
python3 plans/recipe_plan_checks.py check 005 out/plan005/baseline
```

Expected: all runnable local and invariant tests pass. Four optional config/live skips existed in the preceding validation; record actual skips and investigate new ones. Serial execution avoids the known testnet TESTNET_MANIFEST fixture race. Aggregate gas/size reports describe the entire dirty checkout, including pre-existing unrelated work. Only the health-recovery manifest commitment changes.

Record commands, before/after gas, source/artifact changes and limitations in this plan and its index row. Local verification does not establish hosted CI, sibling Go/frontend compatibility, live wallet/chain behavior or deployment.

## Done criteria

- [x] Initial-clamp structural target fails before the edit and passes after it.
- [x] Ordinary example 97→96; conditional fixture 98→97 / 21,696→21,536 bytes; action layouts/queries unchanged.
- [x] Claim/repay bytes and controls stay unchanged, later clamps remain, boundary/overflow/rollback and F01/O01 tests pass.
- [x] Three unchanged recovery benchmarks strictly improve; two controls are equal through the comparator.
- [x] Scoped artifacts and all final local/scope gates pass.
- [x] This plan and its row record evidence and DONE.

## STOP conditions and maintenance

Stop on an unexplained dirty-source mismatch, stale baseline, missing target>trigger validation, changed trigger/error ordering, any later clamp removal, altered pending/cash/debt behavior, an out-of-scope requirement, two unsuccessful focused repairs or a failed gas/control gate. Do not weaken old-cash or progress assertions to make this reduction fit.

Only the saved initial health has the established upper bound. Future actions, queries and new entry points require their own proof. O01's historical hashes/counts describe its earlier baseline; refresh only the recovery values this plan intentionally changes, never the unchanged claim pins.

## Execution evidence

Implemented as a separate unsigned local commit, as authorized. The structural target failed with the initial clamp's result operand and passed with the initial health operand. All eight baseline characterizations, 84 recovery tests and 184 scoped tests pass. The ordinary recovery fixture and saved example are 97→96 steps; the conditional fixture is 98→97 / 21,696→21,536 bytes. All runtime instruction indices shift by exactly one, with unchanged queries. Captured claim and settled-cash recipes remain byte identical. The O01 claim hash/count/length and cash-read barriers are unchanged; only its three intended recovery pins changed.

Frozen gas measurements: recovery 1,109,260→1,105,658; two active sources 1,128,070→1,124,516; one active group 760,067→756,521. Claim stays 607,533 and settled repayment stays 339,241. The executable comparator passes. Only health-recovery was regenerated. Pinned build, formatting, whitespace, selected Prettier and dirty-scope gates pass. Full serial local verification: 2,156 passed, zero failures, four existing optional skips. Separate invariant suites: 18 passed, zero failures/skips.

The planned exact name-only benchmark end anchor matched no tests under Foundry 1.8.1; the commands now include name() parentheses. The empty-selection log is preserved, and all five real labels were captured before production changes. Evidence is under ignored out/plan005/: characterization.log, red.log, before-tests.log, after-tests.log, observations.json under before/after, observation-check.txt, gas-acceptance.txt, focused.log, scoped.log, full-local.log, invariants.log and scope.txt. Local validation does not establish hosted CI or deployment.
