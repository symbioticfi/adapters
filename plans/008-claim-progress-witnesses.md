# Plan 008: Use selected amounts to prove qualifying claim progress (O08)

> Execute only after implementation is requested. Follow the gates in order; stop on a failed assumption rather than widening scope or weakening tests. Planning does not authorize implementation, commits, publication or new permissions. Update this plan and its row in plans/README.md with the final evidence.

## Status

- Priority: P2
- Effort: S
- Risk: LOW
- Depends on: none logically; execute before Plan009 for a stable cumulative ClaimRecipe baseline
- Category: perf
- Planned at: commit `c925f8236e0d4768832d85cc5a5ffef4aa369675`, 2026-10-13
- Repository: `/Users/andreikorokhov/symbiotic/adapters`
- State: DONE

## Why this matters

ClaimRecipe still builds a MAX tree over outputs even when a retained minimum-output check proves that a positive selected amount produces positive output. For qualifying multi-output groups, the selected amount already witnesses progress after those checks succeed. The normal four-group fixture should lose one instruction / 160 ABI bytes; the eight-output fixture should lose seven / 1,120 bytes. Gas savings must be measured before retention.

## Drift check and dirty baseline

Run from the repository root:

```sh
git diff --stat c925f8236e0d4768832d85cc5a5ffef4aa369675..HEAD -- script/recipes/ClaimRecipe.sol test/adapters/merkle-adapter/RecipeClaims.t.sol docs/RECIPE-CLAIMS.md snapshots/RecipeClaims.json
shasum -a 256 script/recipes/ClaimRecipe.sol
git status --short
```

Planning ClaimRecipe hash: `6960542f39ea0cafca82f57681ed4ee2c5ad4f5a3c9ed83b93497325c537a002`. Compare live code with the excerpts below if it differs; stop on unexplained drift. The checkout contains unrelated ThreeFPolicy/testnet edits and untracked files. Never reset, stash or overwrite that baseline. If execution uses an isolated checkout, carry the current authorized in-scope files and prerequisites into it, and preserve the original checkout. HEAD alone does not capture all current work.

The helper's snapshot records hashes/modes of tracked and untracked nonignored files plus copies of scoped files and the complete generated catalogue under ignored out/. Its check compares with that dirty baseline, including additions and deletions. Do not replace baseline evidence or widen helper scopes during execution. Keep future source prototypes within the allowed source paths, not hidden under out/.

## Current state and proof

`script/recipes/ClaimRecipe.sol:66–78` reads claimable and selects either its full amount or `min(claimable,maxAmount)`. Output validation sets `positiveMinimum` when an output satisfies `minNumerator >= denominator > 0`. `:109–125` currently emits:

```solidity
builder.check(OP_LESS_OR_EQUAL, builder.mulDiv(amount, builder.literal(claim.outputs[j].minNumerator), builder.literal(claim.outputs[j].denominator)), delta);
received = builder.binary(OP_MAX, received, delta);
// After all outputs:
if (!positiveMinimum) {
    builder.check(OP_LESS_OR_EQUAL, builder.binary(OP_MIN, amount, builder.literal(1)), received);
}
progress = builder.binary(OP_MAX, progress, received);
// After all groups:
builder.check(OP_LESS_OR_EQUAL, builder.literal(1), progress);
```

The minimum is checked arithmetic. For positive selected amount and numerator at least denominator, every successful product/division yields a positive floor, and the comparison proves positive newly received output. For selected amount zero, all output ReadIf snapshots use fallback zero, so every delta is zero. After those checks succeed, positive output is equivalent to positive selected amount in this group.

Specialize only `positiveMinimum && claim.outputs.length > 1`. Keep the current path for single-output, fractional and optional-only groups. O02's output/progress maxima and O03's implied local-positivity removal are already part of the baseline; this plan removes the remaining redundant output MAXs only in the qualifying case. Existing output checks, cap consumption checks and global no-progress rejection stay intact.

`test/adapters/merkle-adapter/RecipeClaims.t.sol:463–500` pins the normal fixture at 35 instructions / 9,408 bytes and the eight-output fixture at 50 / 11,968. Targets are respectively 34 / 9,248 and 43 / 10,848. Queries and runtime payload-slot count/order remain unchanged; numerical instruction indices shift. `test_O03ImpliedPositivityReducesInstructions` currently compares a two-output qualifying group with a fractional one using a two-step / 320-byte gap; this becomes three / 480 because only the qualifying output MAX disappears.

The documented guarantee is that every active group delivers at least one base unit of new output and all-empty runs revert (`docs/RECIPE-CLAIMS.md:8–17`). Selected amounts are witnesses only after the retained output checks; they cannot replace balance-delta checks.

Match repository conventions: library/test minimum caret pragmas, contracts stored as address, named struct fields, no new argument-bearing errors or one-use helpers. Snapshot/evaluation-order locals are permitted. Model tests after the current real RecipeExecutor/MerkleAccount claim harness. Keep Solidity0.8.37, via-IR, optimizer200, Osaka and bytecode_hash none. Do not change dependencies/toolchain.

## Scope and Git workflow

Allowed modifications only:

- script/recipes/ClaimRecipe.sol.
- test/adapters/merkle-adapter/RecipeClaims.t.sol, including its test-only mocks.
- docs/RECIPE-CLAIMS.md.
- snapshots/RecipeClaims.json, snapshots/gas.txt and snapshots/sizes.txt for final regeneration.
- This plan and plans/README.md status/evidence.

All saved top-level claim examples have a single output, so this plan permits no saved manifest changes. Do not change source example configs, runtime/public ABI, inputs, layouts, permissions, ReadIf behavior, checked arithmetic, generic builder/runtime optimizations, other templates or unrelated dirty work. The helper already defines Plan008's scope and gas policy.

When implementation and local commits are authorized, retain one focused Conventional Commit for this plan, such as `perf: reuse selected amounts for claim progress`. The user previously allowed unsigned local commits; this planning selection authorizes neither implementation nor commits. No push, PR, merge, deployment or curator commitment publication is part of this plan.

## Steps

### 1. Establish the existing baseline before adding tests

Begin each later shell block with the same RECIPE_FORGE assignment shown here; variables do not persist between independent tool shells. Each command must exit zero before proceeding.

```sh
set -euo pipefail
RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
"$RECIPE_FORGE" --version
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^RecipeClaimsTest$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^RecipeManifestBuildTest$' --match-test '^test_AllExamplesManifestMatchesCommittedInstructionsAndRuntimeSlots\(' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py snapshot 008 out/plan008/baseline
```

Expected: pinned Foundry1.8.1, existing claims tests and exactly one selected catalogue test pass; twelve generated outputs are present. Resolve stale/missing catalogue artifacts separately before starting. An existing baseline directory is a stop condition, not permission to overwrite evidence.

### 2. Add characterization and the failing structural target

- Add `test_O08StructuralProgressWitnesses` using the exact normal/eight-output configurations from the existing O02 structural test. Assert targets 34/9,248 and 43/10,848; retain four/one runtime slots. Before the failing count assertions, emit the query hashes, freeze those baseline hashes in the test, and assert they remain equal after the edit; the finished test must not depend on ignored out/ evidence. Inspect emitted output checks and MAXs using decoded operands rather than hardcoded shifted indices. A single qualifying group with eight outputs has no remaining output MAX tree; all eight minima and deltas remain.
- Add `test_O08Semantic*` / `testFuzz_O08Semantic*` tests for qualifying versus fractional/optional-only groups, cap zero/positive, readiness zero/one/above cap, one active among skipped groups, optional zero reward, all-empty rejection and missing payout in a later group after an earlier success. Assert balances/readiness rollback. Include custom/native output snapshots and a qualifying full-width readiness case with a 1/1 required output plus optional zero output; avoid the reward mock's unrelated doubled-payout overflow by configuring its second payout off or using the existing mocks/lenses deliberately.
- Preserve existing unavailable-output tests, `test_OutputlessClaimCannotHideBehindAnotherSuccessfulClaimOrOldBalances`, `test_O03FractionalCappedClaimCannotSucceedWithoutOutput`, `test_O02FullWidthOutputsAcrossGroupsDoNotOverflowProgress` and `test_O02MinimumMultiplicationStillOverflows`. No blanket uint216 cap may be imposed on read values.

The existing isolated `test_AllSettledClaimsUseLiveAmountsAndReceiveCorrectTokens()` is the representative benchmark. Do not change its setup, assertions or snapshot call between phases. Freeze all new semantic fixture code before capturing gas; do not update old structural pins until the production change.

```sh
set -euo pipefail
RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^RecipeClaimsTest$' --match-test '^test(Fuzz)?_O08Semantic' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan008/before UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^RecipeClaimsTest$' --match-test '^test_AllSettledClaimsUseLiveAmountsAndReceiveCorrectTokens\(' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

Expected: new semantic tests pass on unchanged production source; one selected gas test writes RecipeClaims/claimRedemptionWithdrawalMintRewards. Then run the next command separately and save its expected failure:

```sh
RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
"$RECIPE_FORGE" test --offline --match-contract '^RecipeClaimsTest$' --match-test '^test_O08StructuralProgressWitnesses\(' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

Expected: exactly one test fails because the redundant output MAX instructions remain. A compile failure or zero selected tests is not the expected result.

### 3. Emit the selected-amount witness only in eligible groups

After output validation, compute the qualifying multi-output predicate. Omit `received` MAX updates only when that predicate is true. Feed `amount` to the existing cross-group MAX in that case; otherwise feed `received`. Keep the fractional local guard and the final global comparison at their existing positions. Do not remove the delta/minimum computation even when it no longer feeds an output MAX. Keep every checked multiplication.

Update the current O02 structural pins to 34/9,248 and 43/10,848 with a comment distinguishing cumulative O02/O03/O08 savings. Update the two-output O03 structural gap to three instructions / 480 bytes; preserve its semantic assertions. Do not weaken either test or change rates to force a reduction. Describe the restricted progress proof briefly in RECIPE-CLAIMS.md.

```sh
set -euo pipefail
RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^RecipeClaimsTest$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan008/after UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^RecipeClaimsTest$' --match-test '^test_AllSettledClaimsUseLiveAmountsAndReceiveCorrectTokens\(' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py gas 008 out/plan008
python3 plans/recipe_plan_checks.py check-generated 008 out/plan008/baseline
```

Expected: all claims tests pass, structural targets hold, representative executor gas strictly improves, and every saved catalogue output is byte-identical. The comparator rejects missing labels, equality and regressions. If gas fails, restore only this plan's source/artifact changes from its preserved baseline and record REJECTED rather than relaxing the gate; preserve unrelated work and any newly recorded differential evidence.

### 4. Complete artifact and local verification

```sh
set -euo pipefail
RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^(RecipeClaimsTest|RecipeBuildTest|RecipeStagesTest|RecipeManifestBuildTest|RecipeManifestTest|RecipeOptimizationTest)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^RecipeClaimsTest$' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
"$RECIPE_FORGE" build --offline
"$RECIPE_FORGE" fmt --check
git diff --check
python3 plans/recipe_plan_checks.py check-generated 008 out/plan008/baseline
python3 plans/recipe_plan_checks.py check 008 out/plan008/baseline
```

Expected: scoped tests/build/format checks pass; only permitted snapshots/advisory/source paths differ from the dirty baseline. Check modified Markdown with `pnpm dlx prettier@3.9.6 --check docs/RECIPE-CLAIMS.md plans/008-claim-progress-witnesses.md plans/README.md`; format only in-scope files during authorized implementation if needed.

For the final integrated gate, run serially and extract gas only after the full test command succeeds:

```sh
set -euo pipefail
RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
"$RECIPE_FORGE" build --offline --sizes > snapshots/sizes.txt
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --no-match-contract '.*(Mainnet|Benchmark|Invariant).*' --gas-report --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0 > out/plan008/full-local.log 2>&1
sed -n '/^╭/,/^╰/p' out/plan008/full-local.log > snapshots/gas.txt
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '.*Invariant.*' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
git diff --check
python3 plans/recipe_plan_checks.py check-generated 008 out/plan008/baseline
python3 plans/recipe_plan_checks.py check 008 out/plan008/baseline
```

Expected: all runnable local/invariant tests pass; report actual counts and skips, investigating new skips/failures. Serial execution avoids the known testnet shared-env fixture race. Full gas/size reports include the whole dirty checkout. Record exact commands, red/green structural evidence, gas numbers and scope in this plan/index before marking DONE. Local checks do not establish hosted CI, sibling Go/frontend, live-chain/wallet behavior or adoption of rebuilt recipe commitments.

## Done criteria and stop conditions

- [x] New structural target fails on the untouched baseline and passes afterward.
- [x] Normal/eight-output fixtures reach 34/9,248 and 43/10,848 without changed query or runtime-slot meanings.
- [x] Fractional/optional-only and single-output groups retain their existing path; missing payouts, old balances, checked overflow and rollback remain protected.
- [x] Frozen representative execution gas strictly improves via the executable gate.
- [x] All twelve saved outputs remain byte-identical; focused/integrated tests, formatting/build and dirty-scope checks pass.
- [x] Plan/index record evidence and DONE, or a measured rejection with production changes restored.

Stop on unexplained drift, stale catalogue/baseline, changed error/rollback/read/action behavior, a need to alter another template/runtime/permission, two unsuccessful focused repair attempts, unexpected structural counts or a failed gas gate. Do not hide a failure by editing fixture rates, changing measurements or recapturing baseline evidence.

The proof depends on retained local output checks and zero-gated fallback behavior. Future output semantics must re-establish it before retaining selected-amount progress. Public numerical result indices and custom manifests shift even though saved single-output examples do not; always consume rebuilt layouts rather than hardcoded indices.

## Execution evidence — 2026-10-13

Implemented only the qualifying multi-output predicate and selected-amount progress
witness. Retained every output snapshot/delta/minimum and capped debit check,
including checked arithmetic and rollback. Single-output, fractional and
optional-only paths retain their existing progress behavior.

- Existing baseline:29 claims and1 selected catalogue test passed,0 skips; fresh
  dirty snapshot preserves all12 generated outputs.
- Characterization before edits:6 new semantic tests passed, including100 seeded
  fuzz cases, full-width readiness, zero/positive caps, zero/one/above-cap readiness,
  skipped groups, optional zero output, old balances and native/custom rollback.
- Structural RED: exactly1 selected test failed `35 != 34` after pinning the two
  baseline query hashes. GREEN: normal34 instructions/9,248 ABI bytes;
  eight-output43/10,848; four/one runtime slots and query hashes preserved.
  Decoded operands confirm all8 minima/deltas remain and no output MAX tree remains.
- Frozen isolated benchmark: `RecipeClaims/claimRedemptionWithdrawalMintRewards`
  **514,547→510,732 gas** (−3,815); strict helper accepted.
- Claims36/0/0; scoped6 suites108/0/0; full local149 suites2,214 passed,
  0 failed,4 skipped; invariant6 suites18/0/0. Skips are existing absent mainnet,
  Hoodi and Sepolia RPC gates plus the explicit code-size environment gate.
  The code-size case separately passed1/0/0 with `FOUNDRY_CODE_SIZE_LIMIT=24576`.
- Offline build, Solidity/Markdown formatting, generated catalogue and dirty scope
  checks passed. Claim snapshot and full gas report regenerated; regenerated size
  report is unchanged. All12 saved outputs remain byte-identical.

Commands followed Steps1–4 with serial offline Forge1.8.1, Solidity0.8.37, via-IR,
optimizer200 and Osaka. Structural discovery/RED added `-vv` to capture hashes;
the representative fixture's setup/assertions/snapshot stayed frozen.
Complete logs and ledger: `out/plan008/execution-report.md`, including exact command
selectors, RED/GREEN logs, full counts and before/after snapshots.

Setup deviation: the prescribed first offline test auto-initialized missing
submodules at the existing seven pinned commits; it removed only foundry.lock's
terminal newline. Its setup hash `9480c36805726f689be12ec08312e44651701982238dd4ec15092968bf745d8f`
was captured by the immutable baseline. The original hash is
`1bd895eb0de94863f95f28206d894ef5bc24a5ddc57c514ce0d672ce451dd7e1`.
The controller excludes that lock from delivery and verifies the original bytes
against its independent pre-setup baseline. No dependency revisions, helper scopes
or frozen evidence changed. No hosted CI, live-chain behavior or published recipe
commitments are established by these local gates.
