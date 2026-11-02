# Plan 001: Track standalone claim progress with maxima (O02)

> Execute this plan only after the operator requests implementation. Follow each verification gate; update this plan's row in plans/README.md when finished. This plan authorizes local changes within its scope; publication is a separate operation.

## Status

- Priority: P2
- Effort: S
- Risk: LOW
- Depends on: none
- Category: perf
- Planned at: commit `901c82ca0339d27748af414e537a6d47a0643ec3`, 2026-10-12
- Repository: `/Users/andreikorokhov/symbiotic/adapters`
- State: DONE

## Why this matters

ClaimRecipe measures whether each claim group and the whole execution received any new output. It currently converts every output delta to zero/one and adds those flags. Maxima establish the same predicates with one fewer numerical instruction per output. The current four-group/five-output fixture should lose five instructions and 800 bytes of ABI encoding, while preserving actual claims, payouts, failures and permissions.

## Drift check and dirty baseline

Run from the repository:

```sh
git diff --stat 901c82ca0339d27748af414e537a6d47a0643ec3..HEAD -- script/recipes/ClaimRecipe.sol test/adapters/merkle-adapter/RecipeClaims.t.sol docs/RECIPE-CLAIMS.md script/recipes/examples/manifests/claim.json snapshots/RecipeClaims.json
shasum -a 256 script/recipes/ClaimRecipe.sol
git status --short
```

The source hash at planning time is `1aa2eac422fe3e5d7c4e494dc2dd63db99b282599cefc9515330b0844043a175`. ClaimRecipe, its tests, documentation and example manifests are currently untracked; HEAD alone does not contain this baseline. This snapshot includes amount caps, exact selected-amount debit checks, and conditional output reads. Compare the excerpt below if the hash differs. Stop on unexplained drift. Never reset, stash, overwrite or omit existing working-tree changes. A new checkout from HEAD alone is insufficient; an isolated executor must receive the current in-scope files and dependencies.

Before editing, complete Step1's existing-suite and catalogue checks, then run the snapshot command there. `plans/recipe_plan_checks.py` records content hashes and modes for every tracked/untracked nonignored file and copies in-scope/generated files into ignored out/. Its scope gate compares with those existing edits, including untracked files; it does not compare only with HEAD. It copies no secret env files. Do not recapture the baseline to hide an unexpected change.

## Current state

`script/recipes/ClaimRecipe.sol`, in build's output/progress loops, currently includes:

```solidity
uint256 received = builder.literal(0);
// Each output first performs its checked delta subtraction and minimum-output check.
received = builder.binary(OP_ADD, received, builder.binary(OP_MIN, delta, builder.literal(1)));
builder.check(OP_LESS_OR_EQUAL, builder.binary(OP_MIN, amount, builder.literal(1)), received);
progress = builder.binary(OP_ADD, progress, received);
// After every group:
builder.check(OP_LESS_OR_EQUAL, builder.literal(1), progress);
```

The two accumulators are local builder operands, never returned as a named layout or bound to an action. For unsigned deltas and threshold t in {0,1}, `t <= sum(min(delta,1))` iff `t <= max(delta)`. All output reads, checked subtractions and minimum-output calculations precede the group predicate.

`test/adapters/merkle-adapter/RecipeClaims.t.sol` is a real RecipeExecutor/MerkleAccount harness with local protocol fixtures. Use `test_OutputlessClaimCannotHideBehindAnotherSuccessfulClaimOrOldBalances`, `test_InsufficientClaimOutputRollsBackEarlierClaims`, and `test_AllSettledClaimsUseLiveAmountsAndReceiveCorrectTokens` as patterns. Its normal fixture has four groups and five outputs. Capture current example counts at execution time; the earlier review's absolute counts preceded conditional reads and capped-claim examples.

Preserve `amount = maxAmount > 0 ? min(claimable,maxAmount) : claimable`, action bindings to amount, capped exact claimable-debit checks, and output ReadIf gates/fallbacks. The maxAmount==0 readiness-only behavior remains. Existing unavailable-output and bounded-claim tests are required regressions.

Apply repository conventions: tests/interfaces/libraries retain minimum caret pragmas; compiler is pinned to 0.8.37, IR, optimizer 200, Osaka. Contract instances are addresses and cast inline; structs use named fields. Keep production errors argument-free and existing errors unchanged. Use builder-returned operands and `ExecutingRecipe.runtimeSteps`; do not predict shifted instruction indices. Model new tests on the existing harness. Nonfuzz gas tests use `/// forge-config: default.isolate = true` and `vm.snapshotGasLastCall`.

## Scope

Modify only:

- `script/recipes/ClaimRecipe.sol`
- `test/adapters/merkle-adapter/RecipeClaims.t.sol`
- `docs/RECIPE-CLAIMS.md` (only if needed to explain positivity tracking)
- `script/recipes/examples/manifests/claim.json`, `claim-bounded.json`
- `snapshots/RecipeClaims.json`
- `snapshots/gas.txt`, `snapshots/sizes.txt` only for final required aggregate regeneration
- This plan's status/evidence and `plans/README.md`

Do not change executor/interpreter/capability code, JSON input schema, amount caps/debit checks, conditional-read gates/fallbacks, action/read ordering, minimum rates, per-group positivity guard, global nonempty guard, other templates, sibling repositories, or pre-existing testnet/ThreeF work. O03 guard removal is a later plan.

## Git workflow

Keep all pre-existing edits. If a separate branch is requested, use `codex/recipe-claim-progress` and preserve the current working-tree baseline. Do not commit, push, open a PR, or publish recipes as part of plan execution unless the operator authorizes that step. Any authorized commit must be signed and conventional, e.g. `perf: simplify recipe claim progress`.

## Steps

### 1. Establish the current baseline

Confirm the binary below reports Foundry 1.8.1. Run the existing claims suite with manifest/snapshot writes disabled:

```sh
/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge --version
UPDATE_RECIPE_MANIFESTS=false /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --match-contract RecipeClaimsTest --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
UPDATE_RECIPE_MANIFESTS=false /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --match-contract RecipeManifestBuildTest --match-test test_AllExamplesManifestMatchesCommittedInstructionsAndRuntimeSlots --gas-snapshot-emit false --gas-snapshot-check false --threads 1
python3 plans/recipe_plan_checks.py inventory
python3 plans/recipe_plan_checks.py snapshot 001 out/plan001/baseline
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan001/before /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --isolate --match-contract RecipeClaimsTest --match-test test_AllSettledClaimsUseLiveAmountsAndReceiveCorrectTokens --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

Expected: all existing claims tests and the saved catalogue check pass. Stop if existing manifests are stale or missing; upstream example work must finish its own regeneration before this optimization starts. Do not regenerate unrelated stale artifacts into this plan's diff. The isolated baseline writes `out/plan001/before/RecipeClaims.json`, label `claimRedemptionWithdrawalMintRewards`, leaving committed snapshot files untouched. FOUNDRY_SNAPSHOTS is a verified Foundry configuration override.

### 2. Add characterization and reduction tests before editing production

Add a structural test named `test_O02RemovesOneInstructionPerOutput`. Record baseline step count, encoded length and runtime-slot count for the normal five-output fixture and an eight-output fixture. Assert the planned reductions against those recorded baselines. This test must fail on the original source for the expected instruction-count assertion.

Add semantic tests named with the prefix `test_O02` or `testFuzz_O02`: all zero outputs, one raw unit, optional zero-rate output, several outputs, several groups, missing payout in a later group after an earlier success, and preservation of checked minimum-output multiplication overflow. For full-width deltas, use a zero-minimum-rate output so the test isolates progress: two groups can each receive type(uint256).max in different tokens without progress overflow. Use the actual executor/account for effects and rollback checks; a small pure fuzz predicate comparison may supplement it. Retain existing all-empty/old-balance assertions, skipped retired/reverting output queries, capped settlement below/above caps, repeated remainder claims, and rejected overclaims from unbound reward calls.

```sh
/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --match-contract RecipeClaimsTest --match-test 'test_O02RemovesOneInstructionPerOutput' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

Expected before the fix: a failing reduction assertion, not a compile failure. Semantic tests that describe existing behavior should pass. Save the failure under out/plan001.

### 3. Replace both accumulators

Import OP_MAX; remove OP_ADD only if unused after this change. Produce these two assignments:

```solidity
received = builder.binary(OP_MAX, received, delta);
progress = builder.binary(OP_MAX, progress, received);
```

Keep the per-group threshold `min(amount,1)` and final `1 <= progress`. Both accumulation levels must use max: adding full-width group maxima could introduce overflow. The first max with zero folds away; every later output needs one max instead of Min+Add.

```sh
UPDATE_RECIPE_MANIFESTS=false /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --match-contract RecipeClaimsTest --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan001/after /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --isolate --match-contract RecipeClaimsTest --match-test test_AllSettledClaimsUseLiveAmountsAndReceiveCorrectTokens --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 - <<'PY'
import json
from pathlib import Path
label = 'claimRedemptionWithdrawalMintRewards'
before = int(json.loads(Path('out/plan001/before/RecipeClaims.json').read_text())[label])
after = int(json.loads(Path('out/plan001/after/RecipeClaims.json').read_text())[label])
assert after < before, (before, after)
print('Execution gas:', before, '->', after)
PY
```

Expected: all tests pass; five-output fixture loses five instructions/800 ABI bytes, eight-output fixture loses eight/1,280; runtime slot count/order is unchanged; representative execution gas is lower. These are O02-only counts.

### 4. Regenerate selected artifacts and verify integration

The catalogue generator discovers every top-level example and also rewrites the guarded 3F fixture. The snapshot command saved their exact baseline bytes. Current complete output set: manifests for `3f-executing`, `claim`, `claim-bounded`, `health-claim`, `health-claim-ready`, `health-recovery`, `health-repay`, `lending`, `lending-async`, `ll-executing`, `ll-cooldown`, plus `fixtures/3f-executing.json`. Inventory rederives the set and fails if it changes after capture. Only the two claim manifests may change semantically. Each should lose one instruction/160 ABI bytes from its captured baseline.

```sh
UPDATE_RECIPE_MANIFESTS=true /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --match-contract RecipeManifestBuildTest --match-test test_AllExamplesManifestMatchesCommittedInstructionsAndRuntimeSlots --gas-snapshot-emit false --gas-snapshot-check false --threads 1
pnpm dlx prettier@3.9.6 --write script/recipes/examples/manifests/*.json script/recipes/examples/fixtures/3f-executing.json
python3 plans/recipe_plan_checks.py restore-generated 001 out/plan001/baseline
python3 plans/recipe_plan_checks.py check 001 out/plan001/baseline
UPDATE_RECIPE_MANIFESTS=false /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --match-contract '^(RecipeClaimsTest|RecipeBuildTest|RecipeStagesTest|RecipeManifestBuildTest|RecipeManifestTest|RecipeOptimizationTest)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --isolate --match-contract RecipeClaimsTest --match-test test_AllSettledClaimsUseLiveAmountsAndReceiveCorrectTokens --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge build --offline
/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge fmt --check
git diff --check
python3 plans/recipe_plan_checks.py check 001 out/plan001/baseline
```

Expected: all scoped suites/build/checks pass; both claim manifests lose one instruction; query definitions and action instructions/runtime slots are identical except shifted numerical references; the new hash matches the encoded recipe. The restore command first rejects unrelated semantic changes, then returns only formatting changes outside scope to exact baseline bytes. It preserves edits predating execution. Scope checks include new/deleted/untracked files and detect concurrent outside work without reverting it. Stop and explain unexpected differences.

## Done criteria

- [x] Current baseline and pre-fix failing reduction assertion recorded.
- [x] All added and existing claims tests pass, including full-width, zero, one, partial, rollback and overflow cases.
- [x] Both progress assignments use OP_MAX and all existing success/floor guards remain.
- [x] Five-output reduction = 5 instructions/800 bytes; eight-output = 8/1,280; each claim example loses one instruction/160 bytes against its live baseline.
- [x] Runtime action count/order, permissions and payouts are preserved.
- [x] Isolated gas comparison above succeeds; snapshots/manifest refreshed and scoped integration/build/format/diff checks pass.
- [x] Only allowed files changed relative to the saved dirty baseline; index row records measurements and DONE.

## STOP conditions

Stop and report if source drift cannot be explained, the baseline suite is already failing, a generated artifact changes unrelated semantics, any case requires changing executor/schema/permissions, a semantic assertion fails twice after a focused repair, or the gas comparison does not improve. Do not weaken payout/overflow checks to meet the reduction target.

## Maintenance notes

Progress operands represent positivity, not comparable economic amounts across different tokens. Preserve both max levels when adding groups. Full-width deltas are allowed; never sum them. Rebuilt hashes/indices must be consumed through generated layouts. Existing committed recipes continue using their original instructions until separately republished.

## Execution evidence

Implemented locally on 2026-10-12. Before change, the reduction test failed (9 output/group Min operations versus target4); three semantic tests passed. Afterward all27 claims tests and98 integration tests passed. Normal fixture:46→41 instructions and11,168→10,368 ABI bytes. Eight-output fixture:60→52 and13,568→12,288. Executor gas:554,023→536,938 (17,085 saved). Both claim manifests lose one instruction; build, formatting and baseline-relative scope gates pass. No commit or publication.
