# Plan 004: Omit lending positivity implied by the output floor (O04)

> Execute only when implementation is requested. Follow each gate in order. Stop on the specific conditions below and update this plan and its row in plans/README.md with evidence.

## Status

- Priority: P2
- Effort: S
- Risk: LOW
- Depends on: none; the current completed O01–O03 baseline must be preserved
- Category: perf
- Planned at: commit 901c82ca0339d27748af414e537a6d47a0643ec3, 2026-10-12
- Repository: /Users/andreikorokhov/symbiotic/adapters
- State: DONE

## Why this matters

Lending checks both positive purchase output and a configured output floor. For qualifying raw-unit rates, the floor already proves positivity. Both current lending examples have 49 instructions and qualify; removing just the implied comparison projects 48 instructions and 160 fewer ABI-encoded bytes each. Gas improvement has not been measured and must be demonstrated before completion.

## Current state and proof

script/recipes/LendingRecipe.sol:91 checks borrowAmount >= 1; line 122 equates measured borrowed cash to borrowAmount. Lines 127–128 and 152–153 are:

```solidity
layout.minimumRwa =
    builder.mulDiv(layout.borrowedUsdc, builder.literal(limits.minRwaPerUsdcWad), builder.literal(1e6));
// Purchase, exact cash spend and checked output delta remain in between.
builder.check(OP_LESS_OR_EQUAL, builder.literal(1), layout.rwaReceived);
builder.check(OP_LESS_OR_EQUAL, layout.minimumRwa, layout.rwaReceived);
```

Successful checked arithmetic implies minimumRwa >= borrowedUsdc >= 1 exactly when minRwaPerUsdcWad >= 1e6. The threshold is **1e6, not 1e18**. This template assumes six-decimal USDC and eighteen-decimal RWA/normalized purchase receipts. Both script/recipes/examples/lending.json and lending-async.json use 0.99e18 and qualify. At rates below 1e6, a positive amount can floor to zero; retain positivity.

docs/RECIPE-EXECUTOR.md:471–480 documents measured borrowed cash, minimum received output and the alternate normalized asynchronous receipt query. Preserve those semantics and all approval/cleanup, collateral/debt rounding, balance and final cash checks. Keep the checked MUL_DIV even for equal factors.

RecipeLendingTest.setUp builds the real executor/account/capability fixture. Its synchronous test checks debt, cash, RWA and cleared allowances; test_AsyncPurchaseRequestsThenClaimsAfterSeparateSettlement checks pending shares and later delivery. RecipeIssuerMock.setOutputRate controls actual output, independent from builder limits. Model tests after these existing fixtures.

Production SHA-256: LendingRecipe.sol = 916f2d5d80b2bd9df4cb1777fea23d91da1f445447091f5eeda4ab2af165d6a5.

```sh
git diff --stat 901c82ca0339d27748af414e537a6d47a0643ec3..HEAD -- script/recipes/LendingRecipe.sol test/adapters/merkle-adapter/RecipeLending.t.sol docs/RECIPE-EXECUTOR.md
shasum -a 256 script/recipes/LendingRecipe.sol
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
python3 plans/recipe_plan_checks.py snapshot 004 out/plan004/baseline
```

Expected: catalogue passes; the helper records hashes/modes/status of tracked and untracked nonignored files and copies scoped files plus all twelve generated outputs into ignored out/plan004/baseline. Resolve existing stale/missing examples as separate upstream work before starting. Never replace evidence. Add tests only after capturing this baseline; capture gas only after the complete benchmark fixture code is frozen and before editing production.

The helper's check compares against this dirty baseline, not HEAD. restore-generated may restore only formatting-only differences outside scope and refuses semantic drift. Treat concurrent changes as drift requiring investigation, not changes to delete. out/plan004/ is ignored evidence, not an allowed place to hide source changes.

## Scope

Allowed modifications only:

- script/recipes/LendingRecipe.sol.
- test/adapters/merkle-adapter/RecipeLending.t.sol, including test-only mocks in that file.
- docs/RECIPE-EXECUTOR.md for the threshold and measured result.
- script/recipes/examples/manifests/lending.json and lending-async.json.
- snapshots/RecipeLending.json; snapshots/gas.txt and snapshots/sizes.txt for required regeneration.
- This plan and plans/README.md status/evidence.

Do not change example rates/configs, public layout fields, action order/runtime slots, generic builder optimization, interpreter/executor/capability, recovery/claim/LL/3F or sibling code. plans/recipe_plan_checks.py already permits this scope; do not widen it during execution.

## Steps

### 1. Freeze gas fixtures and characterize boundaries

After capturing the baseline, add test_GasO04Sync and test_GasO04Async in RecipeLendingTest, snapshotting RecipeLending/O04Sync and O04Async. Use the existing successful synchronous and asynchronous fixtures with 1e8 supplied and 20_000e6 borrowed, their 0.99e18 minimum and identical permissions. Assert old cash preservation, debt/receipt changes, cleared allowances and the correct direct RWA or pending output. Annotate both for isolation and freeze them before source edits.

Add test_O04QualifyingGuardReducesInstructions. Build direct and async recipes at rates 0, 999999, 1e6 and 1e6+1. Find the comparison with literal one and the received operand, and assert it exists only below 1e6. Decode using actual returned operands; never depend only on index 43. Qualifying recipes must lose exactly one binary step / 160 encoded bytes, with identical queries, action definitions and runtime slot count/order. Record the current example's 49 count.

Add test_O04Semantic*/testFuzz_O04Semantic* characterization for one-unit borrowing, input zero, zero-output rollback at each threshold, qualifying exact floor and short payout, both purchase modes, old RWA/cash preservation and cleanup flags. Configure actual issuer output separately from the floor. Existing asynchronous pending accounting must remain unchanged. For full-width arithmetic, use a raw executor subprogram with input operands and compare guarded versus floor-only versions: successful products agree; overflowing products retain Panic(0x11). Do not force unrealistic huge balances through the Aave fixture or cap queried inputs at uint216 to avoid overflow. For qualifying rates, also assert the production minimum remains checked OP_MUL_DIV with denominator 1e6. A zero rate may fold its minimum to zero under the existing builder; do not require equal total counts across different configurations. Measure the one-step deletion against the same qualifying configuration, not against the zero-rate recipe.

Verify characterization separately before production changes; all semantic cases must pass on the baseline. Only the structural target is expected to fail.

```sh
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract RecipeLendingTest --match-test '^test(Fuzz)?_O04Semantic' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

Expected: all characterization tests pass before production edits. Finish adding tests and freeze setup/mocks/benchmark methods before capturing gas below.

```sh
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan004/before UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract RecipeLendingTest --match-test '^test_GasO04' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
"$RECIPE_FORGE" test --offline --match-contract RecipeLendingTest --match-test test_O04QualifyingGuardReducesInstructions --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

Expected: both benchmarks pass and write two baseline labels; the structural test then fails on the still-present qualifying guard, not compilation.

### 2. Make the narrow builder change

At the existing positive-output comparison, emit it only when limits.minRwaPerUsdcWad < 1e6. Keep the stronger minimum check at its existing relative location. Add no option, helper, algebraic cancellation or input cap.

```sh
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract RecipeLendingTest --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan004/after UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract RecipeLendingTest --match-test '^test_GasO04' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py gas 004 out/plan004
```

Expected: all semantic/structural tests pass and **both** unchanged execution fixtures use strictly less gas. The comparator rejects missing labels and regressions.

### 3. Refresh only the two affected manifests

```sh
UPDATE_RECIPE_MANIFESTS=true "$RECIPE_FORGE" test --offline --match-contract RecipeManifestBuildTest --match-test test_AllExamplesManifestMatchesCommittedInstructionsAndRuntimeSlots --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py restore-generated 004 out/plan004/baseline
```

Expected: both lending examples contain 48 instructions, with changed commitments and correctly shifted result indices; runtime action slots/order and queries are unchanged. All other generated files remain exact baseline bytes. Add/assert these properties in the lending structural/JSON tests, using the current BuildRecipe fixture pattern. Never edit saved recipe bytes manually.

## Final local verification

After the focused semantic and gas gates pass, run:

```sh
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^(RecipeLendingTest|RecipeBuildTest|RecipeStagesTest|RecipeManifestBuildTest|RecipeManifestTest|RecipeOptimizationTest)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^RecipeLendingTest$' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
"$RECIPE_FORGE" build --offline
"$RECIPE_FORGE" fmt --check
git diff --check
python3 plans/recipe_plan_checks.py check 004 out/plan004/baseline
```

Expected: all scoped tests, build, formatting and dirty-scope checks pass. Snapshot emission is restricted to the groups allowed by this plan; do not regenerate unrelated JSON snapshot files. Format only modified in-scope files if a check fails. Check modified Markdown/JSON with pnpm dlx prettier@3.9.6 --check, naming the individual modified files; do not format the repository.

For the final integrated gate, mirror the repository hook with the pinned compiler and serial tests. Each command below must exit zero before running the next; do not extract a report from a failed test log.

```sh
"$RECIPE_FORGE" build --offline --sizes > snapshots/sizes.txt
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --no-match-contract '.*(Mainnet|Benchmark|Invariant).*' --gas-report --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0 > out/plan004/full-local.log 2>&1
sed -n '/^╭/,/^╰/p' out/plan004/full-local.log > snapshots/gas.txt
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '.*Invariant.*' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
git diff --check
python3 plans/recipe_plan_checks.py check 004 out/plan004/baseline
```

Expected: all runnable local and invariant tests pass. Four optional config/live skips existed in the preceding validation; record actual skips and investigate new ones. Serial execution avoids the known testnet TESTNET_MANIFEST fixture race. Aggregate gas/size reports describe the entire dirty checkout, including pre-existing unrelated work. The two lending manifest commitments change; publication is separate.

Record commands, before/after gas, source/artifact changes and limitations in this plan and its index row. Local verification does not establish hosted CI, sibling Go/frontend compatibility, live wallet/chain behavior or deployment.

## Done criteria

- [x] Original qualifying-guard assertion fails before the change and passes after it.
- [x] Direct/async example instructions are 49→48 and encoded length decreases by 160; queries and runtime action layouts are unchanged.
- [x] Rates below 1e6 keep positivity; zero/one, short output, overflow and real-account rollback tests pass.
- [x] Both frozen gas fixtures strictly improve through the executable comparator.
- [x] Only allowed manifests/snapshots change; all final gates and dirty-scope checks pass.
- [x] This plan and its index row record evidence and DONE.

## STOP conditions and maintenance

Stop on an unexplained dirty-source change, stale baseline, changed units/receipt normalization, a need to modify permissions/schema/another template, altered checked overflow, loss of a fractional positivity guard, two unsuccessful focused repair attempts or either benchmark failing to improve. Do not weaken rounding/cash/output checks to pass.

The raw rate threshold depends on this template's denominator. Future decimal changes require a new proof. Named results shift when instructions are removed; always obtain the rebuilt layout. No deployment or recipe publication is part of this plan.

## Execution evidence

User authorized implementation with separate unsigned local commits. The prerequisite recipe baseline was recorded on the current branch as 908f922.

The qualifying-guard assertion failed before the edit (1 != 0) and passed afterward. All 33 lending tests and 104 scoped tests pass. Both examples are 49→48 instructions and 160 bytes smaller, with unchanged queries and runtime action order/count. Only the two lending manifests were regenerated.

Frozen isolated execution gas: synchronous 785,197→781,661; asynchronous 791,927→788,391. Both save 3,536 gas. The executable gas and dirty-scope comparators pass. Pinned Foundry 1.8.1 / Solidity 0.8.37 via-IR build, formatting, whitespace and selected Prettier checks pass. Full serial local verification: 2,147 passed, zero failures, four existing optional configuration skips; separate invariant selection: 18 passed, zero failures or skips.

Commands and raw logs are in ignored out/plan004/: red.log, focused.log, scoped.log, before-tests.log, after-tests.log, full-local.log, invariants.log, gas-acceptance.txt and scope.txt. The redundant cold build was interrupted; the final gate completed successfully after importing verified baseline cache/artifacts. Local checks do not establish hosted CI or deployment.
