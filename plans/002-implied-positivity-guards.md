# Plan 002: Omit positivity guards implied by output floors (O03)

> Execute only after implementation is requested. Follow every verification gate and update this plan's row in plans/README.md. Publication of rebuilt recipes is a separate operation.

## Status

- Priority: P2
- Effort: S
- Risk: LOW
- Depends on: `plans/001-claim-progress-maxima.md` (O02), for a stable cumulative claim baseline
- Category: perf
- Planned at: commit `901c82ca0339d27748af414e537a6d47a0643ec3`, 2026-10-12
- Repository: `/Users/andreikorokhov/symbiotic/adapters`
- State: DONE

## Why this matters

Three templates separately require positive output and enforce a minimum-output formula. When the configured raw-unit numerator is at least its positive denominator, the stronger floor check already proves positivity. Omitting only the implied guard saves two instructions per qualifying claim group and one for LL redemption. Fractional and zero rates must keep their existing guards.

## Drift and baseline

```sh
git diff --stat 901c82ca0339d27748af414e537a6d47a0643ec3..HEAD -- script/recipes/ClaimRecipe.sol script/recipes/RecoveryRecipe.sol script/recipes/LLExecuting.sol test/adapters/merkle-adapter/RecipeClaims.t.sol test/adapters/merkle-adapter/RecipeRecovery.t.sol test/adapters/merkle-adapter/LLExecuting.t.sol
shasum -a 256 script/recipes/RecoveryRecipe.sol script/recipes/LLExecuting.sol
git status --short
```

At planning, RecoveryRecipe hash is `ecde6d5de46d46da89ec6b7c62fe9933ac4d0a4fcde376b38fa5f0bd03c78a48`; LLExecuting is `cf11400a76e97d16f996a0cb4ea91654b3b4bb5a0b3bbc1e5e0614f639ee3325`. These include capped/pending-free claims and bound/retained-inventory LL redemption. ClaimRecipe intentionally changes through Plan001: verify both max accumulators and both existing positivity guards are present. Other source drift requires comparison with the excerpts below and an explanation before proceeding.

Step1 captures status, content hashes/modes for tracked/untracked nonignored files, and exact source/generated artifact copies with `plans/recipe_plan_checks.py` under ignored out/plan002/. Its later check compares against the dirty baseline, not HEAD; restore-generated rejects unrelated semantic changes and restores only formatting changes outside scope. Preserve existing tracked/untracked changes, including new claim code and unrelated testnet/ThreeF edits. An isolated checkout must include that working-tree baseline, not merely HEAD. Never replace baseline evidence to conceal drift.

## Current state and proof

ClaimRecipe.build (after O02, max tracking changes only) checks each output's floor, then `min(amount,1) <= received`:

```solidity
builder.check(
    OP_LESS_OR_EQUAL,
    builder.mulDiv(amount, builder.literal(output.minNumerator), builder.literal(output.denominator)),
    delta
);
// After all outputs:
builder.check(OP_LESS_OR_EQUAL, builder.binary(OP_MIN, amount, builder.literal(1)), received);
```

RecoveryRecipe._claim:

```solidity
uint256 minimum = builder.mulDiv(selected, builder.literal(claimConfig.minAssetPerClaimWad), builder.literal(1e18));
uint256 positive = builder.binary(OP_MIN, builder.literal(1), selected);
// Pending and cash reads, Manage, pending-delta check, checked cash subtraction follow.
builder.check(OP_LESS_OR_EQUAL, positive, received);
builder.check(OP_LESS_OR_EQUAL, minimum, received);
```

LLExecuting.build builds its minimum before redemption, then:

```solidity
uint256 received = builder.binary(OP_SUB, total, receipt);
builder.check(OP_LESS_OR_EQUAL, builder.literal(1), received);
builder.check(OP_LESS_OR_EQUAL, minimum, received);
```

LL already checks `1 <= amountIn`. For numerator >= denominator > 0, successful checked multiplication/division produces floor >= selected amount. For Claim/Recovery, positive selected amount therefore requires positive delta; zero amount's omitted guard would merely assert 0 <= an unsigned delta. For LL, amount is already positive. The unchanged checked subtraction still rejects decreased output balances.

Preserve caps and selected-amount bindings/debit checks in ClaimRecipe, including zero-gate output ReadIf behavior. Preserve Recovery's selected=min(claimable,maxAmount), optional pending query, and exact selected debit against pending or claimable. LL's amountOffsets and retainsRwa check are unchanged. These paths must pass their existing bounded and retained-inventory tests.

Do not cancel equal numerator/denominator factors. Multiplication overflow is part of runtime semantics even for a 1e18/1e18 ratio. A fractional ratio can round a positive amount's floor to zero; its positivity guard is essential.

Conventions: library/test caret pragmas retain their feature minimum; builds use Solidity0.8.37, IR, optimizer200 and Osaka. Contract instances remain addresses; structs use named fields; do not add production argument-bearing errors, a production optimization flag, or a single-use helper. Use returned operands/layouts. Gas tests are isolated and nonfuzz with vm.snapshotGasLastCall. Existing real executor/account fixtures, not a pure predicate alone, must establish effects and rollback.

## Scope

Allowed:

- `script/recipes/ClaimRecipe.sol`, `RecoveryRecipe.sol`, `LLExecuting.sol`
- `test/adapters/merkle-adapter/RecipeClaims.t.sol`, `RecipeRecovery.t.sol`, `LLExecuting.t.sol`
- `docs/RECIPE-CLAIMS.md`, `docs/HEALTH-RECOVERY-RECIPE.md`, `docs/RECIPE-EXECUTOR.md` for concise behavior/measurement notes
- `script/recipes/examples/manifests/claim.json`, `claim-bounded.json`, `health-claim.json`, `health-claim-ready.json`, `ll-executing.json`, `ll-cooldown.json`
- `snapshots/RecipeClaims.json`, `RecipeRecovery.json`, `LLExecuting.json`
- `snapshots/gas.txt`, `snapshots/sizes.txt` only for final required regeneration
- Plan/index status and measurements

Do not change inputs/rates/schema, interpreter/executor/capabilities, action ordering, output reads, checked arithmetic, global progress guards, pending/debt/cash semantics, ThreeF/lending templates, or sibling code. Recovery source cash carry is O01 and belongs to the next plan. Stage/manifest tests should consume generated layouts; stop if a source change outside this list becomes necessary.

## Git workflow

Preserve current working-tree edits. If a branch is requested, use `codex/recipe-implied-positive-checks` on the validated current baseline. No commit/push/PR/publication without operator authorization. Authorized commits are signed and conventional, e.g. `perf: omit implied recipe positivity guards`.

## Steps

### 1. Verify prerequisite and add unchanged gas fixtures

Plan001 must be DONE, or its exact scoped max changes and gates must be independently verified. Run all three template suites:

```sh
UPDATE_RECIPE_MANIFESTS=false /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --match-contract '^(RecipeClaimsTest|RecipeRecoveryTest|LLExecutingTest)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
UPDATE_RECIPE_MANIFESTS=false /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --match-contract RecipeManifestBuildTest --match-test test_AllExamplesManifestMatchesCommittedInstructionsAndRuntimeSlots --gas-snapshot-emit false --gas-snapshot-check false --threads 1
python3 plans/recipe_plan_checks.py inventory
python3 plans/recipe_plan_checks.py snapshot 002 out/plan002/baseline
```

Expected: all pass, including the saved catalogue. Stop if existing manifests are stale or missing; finish that upstream baseline's own regeneration separately before this plan. Capture current counts from this post-O02 baseline, rather than using the earlier review's absolute counts. Add isolated benchmark tests before production changes: `test_GasO03HealthClaim` in RecipeRecoveryTest for two active 1e18-rate claims, and `test_GasO03LLPositiveMinimum` in LLExecutingTest for a successful 1/1 redemption. Name snapshot labels `O03HealthClaim` in RecipeRecovery and `O03LLPositiveMinimum` in LLExecuting. Model existing recovery gas test and LL gas tests; assert actual cash/debt/receipts/allowances and only snapshot executor execution. The existing all-settled Claim test covers the standalone fixture.

```sh
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan002/before /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --isolate --match-contract '^(RecipeClaimsTest|RecipeRecoveryTest|LLExecutingTest)$' --match-test '^(test_AllSettledClaimsUseLiveAmountsAndReceiveCorrectTokens|test_GasO03HealthClaim|test_GasO03LLPositiveMinimum)' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

Expected: three pass and three baseline labels exist under out/plan002/before. Leave benchmark fixture code unchanged for after comparison.

### 2. Add reduction and semantic tests

Use `test_O03ImpliedPositivityReducesInstructions` in each template suite to record and assert precise qualifying-vs-fractional instruction reductions. Run before editing production; expected count assertion fails, compilation succeeds:

```sh
/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --match-contract '^(RecipeClaimsTest|RecipeRecoveryTest|LLExecutingTest)$' --match-test test_O03ImpliedPositivityReducesInstructions --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

Add `test_O03` / `testFuzz_O03` semantics: zero and one selected amount, rates zero (where allowed), below/equal/above denominator, required output plus optional zero output, short payout, earlier successful group then later failure, and full-width multiplication overflow. Exercise bounded claimable below/above maxAmount and pending-free Recovery claims; an amount cap must not change the implication's threshold or permit overclaim. Keep unavailable output reads skipped when amount is zero, all-pending/all-empty failure and old-balance protection. In Recovery, minAssetPerClaimWad==0 must retain InvalidConfiguration. In Claim, denominator==0 must retain InvalidConfiguration. In LL, zero numerator and positive amount with zero receipt must still fail CheckFailed, including retainsRwa=true.

For fractional LL coverage, extend only the test Plan/harness with a receipt-denominator field defaulting to1, or construct an equivalent direct builder fixture; preserve all existing fixture defaults. A positive amount of1 at rate1/2 with zero receipt must fail. Verify custom native/generic outputs also remain checked. Do not invent blanket uint216 caps on queried amounts to sidestep overflow.

### 3. Apply configuration-specific emission

- ClaimRecipe: while validating/processing outputs, set a local bool when any output satisfies minNumerator >= denominator (denominator's existing nonzero validation stays). After outputs, emit the existing group Min+check only when that bool is false. Keep output floors, O02 maxima, global progress check, and all reads.
- RecoveryRecipe._claim: only construct/use positive Min when minAssetPerClaimWad <1e18. Keep its location before actions if emitted. Retain the existing final minimum check and checked MUL_DIV.
- LLExecuting: emit `1 <= received` when denominator==0 or numerator < denominator; equivalently omit only when numerator >= denominator >0. Keep the minimum calculation at its original stage and minimum check after the delta.

```sh
UPDATE_RECIPE_MANIFESTS=false /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --match-contract '^(RecipeClaimsTest|RecipeRecoveryTest|LLExecutingTest)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan002/after /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --isolate --match-contract '^(RecipeClaimsTest|RecipeRecoveryTest|LLExecutingTest)$' --match-test '^(test_AllSettledClaimsUseLiveAmountsAndReceiveCorrectTokens|test_GasO03HealthClaim|test_GasO03LLPositiveMinimum)' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 - <<'PY'
import json
from pathlib import Path
pairs = [('RecipeClaims','claimRedemptionWithdrawalMintRewards'),('RecipeRecovery','O03HealthClaim'),('LLExecuting','O03LLPositiveMinimum')]
for group,label in pairs:
    before=int(json.loads(Path(f'out/plan002/before/{group}.json').read_text())[label])
    after=int(json.loads(Path(f'out/plan002/after/{group}.json').read_text())[label])
    assert after<before,(group,label,before,after)
    print(group,label,before,'->',after)
PY
```

Expected: all tests pass and each representative gas label improves. Claim fixture loses six additional instructions/960 bytes beyond O02; total O02+O03 reduction is eleven/1,760. Relative to this plan's captured baseline, each claim example loses two instructions/320 bytes; each two-group health-claim example loses four/640; each LL example loses one/160. Fractional/zero-rate recipes retain positivity guards; actions/read queries/runtime slots remain identical except numerical-index remapping. Record actual before/after absolute counts from the live baseline.

### 4. Refresh artifacts and verify consuming boundaries

The snapshot command saved the complete generator output set: manifests for `3f-executing`, `claim`, `claim-bounded`, `health-claim`, `health-claim-ready`, `health-recovery`, `health-repay`, `lending`, `lending-async`, `ll-executing`, `ll-cooldown`, plus `fixtures/3f-executing.json`. Inventory rederives the list and rejects changes during execution. Only the six selected claim/health-claim/LL manifests may change semantically.

```sh
UPDATE_RECIPE_MANIFESTS=true /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --match-contract RecipeManifestBuildTest --match-test test_AllExamplesManifestMatchesCommittedInstructionsAndRuntimeSlots --gas-snapshot-emit false --gas-snapshot-check false --threads 1
pnpm dlx prettier@3.9.6 --write script/recipes/examples/manifests/*.json script/recipes/examples/fixtures/3f-executing.json
python3 plans/recipe_plan_checks.py restore-generated 002 out/plan002/baseline
python3 plans/recipe_plan_checks.py check 002 out/plan002/baseline
UPDATE_RECIPE_MANIFESTS=false /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --match-contract '^(RecipeClaimsTest|RecipeRecoveryTest|LLExecutingTest|RecipeBuildTest|RecipeStagesTest|RecipeManifestBuildTest|RecipeManifestTest|RecipeOptimizationTest)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --isolate --match-contract '^(RecipeClaimsTest|RecipeRecoveryTest|LLExecutingTest)$' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge build --offline
/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge fmt --check
git diff --check
python3 plans/recipe_plan_checks.py check 002 out/plan002/baseline
```

Expected: all gates pass. Preserve pre-existing snapshot labels; unrelated measured values may not be overwritten casually. The restore command verifies semantics before returning generator-induced formatting changes outside scope to exact saved bytes, preserving prior user edits. Nonqualifying zero-minimum LL recipe bytes/counts stay unchanged from the live baseline. The scope check includes tracked, untracked, added and deleted files, and flags concurrent work without reverting it. Record actual gas savings separately from instruction savings.

## Done criteria

- [x] O02 prerequisite verified; unchanged-fixture before/after gas labels recorded and all improve.
- [x] New reduction tests failed before implementation and pass afterward.
- [x] Guards remain for fractional/zero rates; every nonzero claim still needs fresh output; all-empty execution still fails.
- [x] Checked SUB/MUL_DIV overflow and exact selectors/revert rollback remain.
- [x] Each claim/health-claim/LL example's relative reduction is confirmed against the live post-O02 baseline; manifest hashes/actions/layouts and named-stage tests agree.
- [x] Expected additional six instructions/960 bytes saved in Claim fixture; scope/integration/build/format/diff gates pass.
- [x] Only allowed files changed relative to dirty baseline; status records DONE and measured savings.

## STOP conditions

Stop if drift is unexplained, prerequisite is incomplete, an old semantic test fails before editing, a fractional-rate zero-output case succeeds, overflow behavior changes, the method requires executor/schema/action/read changes, a semantic assertion fails twice, or unchanged-fixture gas does not improve. Do not force the rate condition by altering configured rates or weakening tests.

## Maintenance notes

This implication concerns raw output units, not token prices or decimal-normalized economics. Revisit it when new rate conventions appear. Minimum arithmetic remains required even for equal factors. Keep global/nonempty guards after omitting group guards, and regenerate commitments before separately authorized publication.

## Execution evidence

Implemented locally on2026-10-12. All three reduction tests failed before emission changes; six new semantic/benchmark tests passed. Afterward148 template tests and219 integration tests passed. Execution gas: standalone claim536,938→514,494; health claim622,460→607,533; LL871,863→868,316. Six selected manifests lose2/2/4/4/1/1 instructions. Fractional rounding, rollback, capped/pending-free behavior and checked multiplication remain covered. Build, formatting and baseline-relative scope pass. The terminal-dollar benchmark regex was corrected because Foundry matches function signatures. LL test construction uses a self-call to isolate the builder from a verified IR stack-depth issue; execution measurement is unchanged. Scratch baseline was recreated after a cache reset, before production O03 edits; source originals were recovered and hashes checked. No commit or publication.
