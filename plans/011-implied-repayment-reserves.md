# Plan 011: Remove reserve comparisons implied by repayment accounting (O12)

> Execute only after explicit implementation authorization. This selection requests a plan, not source edits or commits. Follow the gates in order and record evidence here and in plans/README.md.

## Status

- Priority: P2
- Effort: S
- Risk: LOW if restricted to the two final comparisons
- Depends on: completed 008–010 and a fresh snapshot of the current dirty baseline
- Category: perf
- Planned at: commit dfea206f3a427968cf98cb766e0eab1399b93349, 2026-10-14
- Repository: /Users/andreikorokhov/symbiotic/adapters
- State: DONE (verified locally; parent review and local commit pending)

## Why this matters

The health-claim and settled-cash repayment templates repeat reserve checks already enforced by their selected repayment amount and final cash conservation. Three saved programs each lose one instruction and 160 ABI bytes. Gas is unmeasured; retain the change only if all three representative executor workloads improve and both unchanged controls stay exactly equal.

## Current state and proof

RecoveryRecipe.claim at script/recipes/RecoveryRecipe.sol:205–213 builds checked freshCash = beforeRepay.cash - initial.cash, checks positive fresh cash, and bounds repayment by fresh cash, target-health need and maxRepayment. It ends with:

```solidity
Snapshot memory afterRepay = _repay(builder, config, amount, beforeRepay, layout);
builder.check(OP_LESS_OR_EQUAL, initial.cash, afterRepay.cash);
```

RecoveryRecipe.repay at lines 231–242 selects min(min(saturatingSub(initial.cash, literal(minCashBalance)), need), maxRepayment), checks positive amount, and ends with:

```solidity
Snapshot memory afterRepay = _repay(builder, config, amount, initial, layout);
builder.check(OP_LESS_OR_EQUAL, builder.literal(minCashBalance), afterRepay.cash);
```

The retained _repay at lines 414–424 checks actualCashDebit == amount and, after approval cleanup and fresh reads, afterRepay.cash == beforeRepay.cash - actualCashDebit using checked subtraction. In claim, amount <= beforeRepay.cash - initial.cash therefore implies afterRepay.cash >= initial.cash. In repay, positive amount excludes initial.cash <= reserve; amount <= initial.cash - reserve proves the reserve. The earlier literal(minCashBalance) at line 235 retains uint216-width rejection. Zero reserve already folds its final check and changes nothing.

These are implications between the same immutable operands, not assumptions that successive getters match. Keep all reads, checked arithmetic, positivity, bounds, exact debit, debt tolerance, final cash/debt conservation, health checks, approvals, cleanup and callback barriers. Keep recovery()'s cash equality at line 144 and final observations at lines 167–170: general removal there would require a stronger observation-stability assumption. No helper or interpreter optimization belongs here.

Source SHA-256 pins: RecoveryRecipe.sol = 0b401e056abfc01978a568439a89953b26cdc6f494876d69cec4b4cd43020061; ExecutingRecipe.sol = 728b5f07daf84cdede4bbad1bb792fa62b6da1cd7ff642fc0ca47f641854a3b1; Recipes.sol = f6c8f8f3c7298213d1234dc021bf1233b3397d94f64abc584ef117a9ef8609a1; RecipeExecutor.sol = a5568329cae1dbeb05dc48842b42100a55549c2345e9862f7b662f3d3b33ca7a.

## Toolchain, baseline, scope and Git workflow

Use an isolated checkout containing the complete current tracked/untracked dirty baseline. Preserve unrelated ThreeFPolicy/testnet work. Do not reset, clean or stash the original checkout. Use Foundry 1.8.1 at the path below, Solidity 0.8.37, via-IR, optimizer 200, Osaka and bytecode_hash=none. Missing tools/dependencies require a stop, not an upgrade or installation during this task.

Allowed files only:

- script/recipes/RecoveryRecipe.sol.
- test/adapters/merkle-adapter/RecipeRecovery.t.sol, including test-only helpers and mocks in that file.
- docs/HEALTH-RECOVERY-RECIPE.md.
- script/recipes/examples/manifests/health-claim.json, health-claim-ready.json and health-repay.json.
- snapshots/RecipeRecovery.json, snapshots/gas.txt and snapshots/sizes.txt.
- This plan and plans/README.md.

Do not change generic builders, interpreter/executor/capability, _repay, health/repayment/request formulas, other templates, example configurations, permissions, other saved outputs, deployment code, helper scopes or sibling consumers. The helper already defines scope 011; do not widen it. Match supplied AGENTS.md: address-valued contract instances with inline casts, named struct fields, sorted imports, feature-minimum library/test pragmas, argument-free repository errors, and no single-use production helper. Existing named layout and packed operands remain authoritative.

If implementation and commits are later requested, use one focused Conventional Commit, for example perf: omit implied repayment reserve checks. Unsigned local commits were explicitly allowed earlier. Do not push, open a PR, publish recipes or deploy without separate authorization. A requested new branch uses codex/.

Run each shell block independently with its own prologue; exports from another tool shell do not persist. Except for the explicit RED block, any nonzero exit stops the next gate. Evidence directories must be new and ignored; never overwrite an earlier run.

```sh
set -euo pipefail
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
"$RECIPE_FORGE" --version
git status --short
git diff --stat dfea206f3a427968cf98cb766e0eab1399b93349..HEAD -- script/recipes/RecoveryRecipe.sol test/adapters/merkle-adapter/RecipeRecovery.t.sol docs/HEALTH-RECOVERY-RECIPE.md
shasum -a 256 script/recipes/RecoveryRecipe.sol script/recipes/ExecutingRecipe.sol src/contracts/merkle-adapter/Recipes.sol src/contracts/merkle-adapter/automations/RecipeExecutor.sol
python3 plans/recipe_plan_checks.py inventory
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^RecipeManifestBuildTest$' --match-test '^test_AllExamplesManifestMatchesCommittedInstructionsAndRuntimeSlots\(\)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py snapshot 011 out/plan011/baseline
```

Expected: version and pins match; the catalogue selects exactly one passing test; inventory/snapshot covers all twelve generated outputs and the complete nonignored dirty tree. Unexplained drift, stale catalogue or zero selected tests means stop.

## Steps

### 1. Freeze original programs, semantics and five gas workloads

Use RecipeRecoveryTest's existing setup, real RecipeExecutor/MerkleAccount and permission proofs. Add test_GasO12ZeroReserveRepay, isolated and nonfuzzed: prepare _repayRuntime(0,17e6), decode _recipe and allocate empty inputs before calling execute; immediately snapshot RecipeRecovery/O12ZeroReserveRepay. Expected account cash 0, debt 283e6, Aave cash 1017e6, allowance 0, trace count 1 and calls(0) == 5. No issuer claims or withdrawals precede this control.

Freeze these unchanged existing methods and labels:

| Test method                                                   | RecipeRecovery label          | Acceptance     |
| ------------------------------------------------------------- | ----------------------------- | -------------- |
| test_GasO03HealthClaim                                        | O03HealthClaim                | Strictly lower |
| test_GasO09BoundedIdentityHealthClaim                         | O09BoundedIdentityHealthClaim | Strictly lower |
| test_RepayUsesPreviouslySettledCashAndPreservesReserve        | repaySettledCash              | Strictly lower |
| test_RecoveryWithdrawsMorphoThenAaveRepaysThenRequestsInOrder | recovery                      | Exactly equal  |
| test_GasO12ZeroReserveRepay                                   | O12ZeroReserveRepay           | Exactly equal  |

snapshotGasLastCall must immediately follow the measured executor call, before any other external assertion. The existing _execute ends with execute. Freeze benchmark methods, setup, helper paths, mocks, permissions and amounts before the before capture. Hash the entire completed RecipeRecovery.t.sol to out/plan011/frozen-tests.sha256; it must match after capture. Complete the legacy-test adjustments below before freezing, not after production edits.

Construct a small test-only frozen original-footer reference, restricted to the ordinary fixture where health/debt queries are distinct from the ERC20 cash query. Match cash query bytes against abi.encode(config.asset, abi.encodeCall(IERC20.balanceOf,(config.account)), new uint256[](0), uint256(0)). Decode OP_READ query indices, assert distinct health/debt query encodings, find the first matching cash producer before any runtime instruction and the last after runtimeSteps(recipe)[layout.clearApproval]. Assert both exist. Build the original OP_LESS_OR_EQUAL footer from result(initialCashIndex)/result(finalCashIndex) for claim, or literal(reserve)/result(finalCashIndex) for positive-reserve repay. Use ExecutingRecipe.result and builder.literal width validation, not guessed indices. Strip a last step only if its complete bytes exactly match this footer; append the independently reconstructed footer. Zero-reserve reference appends nothing. Before editing production this must reproduce the original exactly.

Before production changes, record and put literal original-program AND prefix-program keccak256 hashes in tests for normal claim, bounded claim pending-present/free and both read modes, positive-reserve repay and zero-reserve repay. Prefix excludes only the matched old footer. Tests must never read out/plan011/ or other ignored files. Assert fixed pins and every query/prefix byte/runtime slot and layout before and after. References derived from a candidate alone without frozen prefix pins are insufficient. Keep aliased/volatile-read adversarial fixtures separate from this fixed-reference helper; it must not infer cash from an ambiguous query match.

Add test_O12ReserveComparisonsAreImplied as the strict structural target, requiring the candidate to end at the retained debt equality, absence of only the two old footers, one fewer step/160 bytes for claim and positive-reserve repay, and exact equality for zero reserve/recovery. Compare each candidate prefix against the pinned original prefix. Include both read and approval flags. Prepare legacy O01/O05 ordinary-claim hash assertions to verify the reconstructed original hash 0x1907dc1d8784938d4049e6c5184873f2292a6caa66973d47cb31d2c8142aaff7. Legacy size assertions may accept the exact original shape when the old footer is present and the exact candidate shape when absent, with original prefix pins always enforced; the new strict target alone rejects the original.

Intentional legacy size changes: O09 four health modes [57,57,55,55]/[11616,12000,10720,10976] become [56,56,54,54]/[11456,11840,10560,10816]; O01 conditional claim 57/12064 becomes 56/11904. Keep recovery hashes/counts, cash-read counts, runtime ordinals and O03's +4 instructions/+640 bytes comparison unchanged.

Add test_O12Semantic* and testFuzz_O12Semantic* cases listed below. For execution parity, prepare runtime with _baseRuntime plus _one, then install and directly execute each program from identical snapshotted state. _claimRuntime and _repayRuntime reinstall production: never call them after installing a reference. Compare success/exact revert bytes, numerical result prefixes, cash, debt, pending/readiness, allowances and trace; original positive-reserve/claim has one extra nonnumerical trailing result. All semantic tests must pass on unchanged production.

```sh
set -euo pipefail
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^RecipeRecoveryTest$' --match-test '^(test_O12Semantic.*|testFuzz_O12Semantic.*)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0 -vv
shasum -a 256 test/adapters/merkle-adapter/RecipeRecovery.t.sol > out/plan011/frozen-tests.sha256
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan011/before UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^RecipeRecoveryTest$' --match-test '^(test_GasO03HealthClaim|test_GasO09BoundedIdentityHealthClaim|test_RepayUsesPreviouslySettledCashAndPreservesReserve|test_RecoveryWithdrawsMorphoThenAaveRepaysThenRequestsInOrder|test_GasO12ZeroReserveRepay)\(\)$' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

Expected: every new semantic test passes without skips, fuzz cases use the pinned 100 runs/seed zero, exactly five benchmark methods pass, and all five positive labels exist in before/RecipeRecovery.json. Recorded snapshot numbers are historical context, never substitutes for this fresh measurement. Preserve logs and source hashes.

Run the failing-first target separately:

```sh
set -uo pipefail
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^RecipeRecoveryTest$' --match-test '^test_O12ReserveComparisonsAreImplied\(\)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0 -vv > out/plan011/structural-red.log 2>&1
red_status=$?
test "$red_status" -ne 0
```

Expected: exactly one selected failing test solely because the original reserve footer remains. Open the log; compiler/fixture errors, zero selection or another failure do not qualify as RED.

### 2. Delete only the two footers and verify GREEN plus gas

In claim and repay, replace the two excerpts with calls to _repay that ignore its return. Delete each final reserve comparison. Do not alter _repay's returned snapshots or other call sites. Re-run the structural and full RecipeRecoveryTest selection, then the identical frozen five gas fixtures.

```sh
set -euo pipefail
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
shasum -a 256 -c out/plan011/frozen-tests.sha256
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^RecipeRecoveryTest$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan011/after UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^RecipeRecoveryTest$' --match-test '^(test_GasO03HealthClaim|test_GasO09BoundedIdentityHealthClaim|test_RepayUsesPreviouslySettledCashAndPreservesReserve|test_RecoveryWithdrawsMorphoThenAaveRepaysThenRequestsInOrder|test_GasO12ZeroReserveRepay)\(\)$' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py gas 011 out/plan011
```

Expected: the strict structural target and all recovery tests pass; all three changed workloads improve; both controls equal exactly. Missing/nonpositive labels, regression, unchanged candidate gas or changed control means reject, not weaken the comparator or tune frozen fixtures.

### 3. Regenerate only three saved manifests and document the proof

Update docs/HEALTH-RECOVERY-RECIPE.md to explain that both reserve guarantees follow from retained amount bounds and exact final cash conservation. Record measured results only after Step 2. The catalogue update writes all generated outputs; restore excluded formatting-only changes with the helper and stop on any semantic drift outside scope.

```sh
set -euo pipefail
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
UPDATE_RECIPE_MANIFESTS=true "$RECIPE_FORGE" test --offline --match-contract '^RecipeManifestBuildTest$' --match-test '^test_AllExamplesManifestMatchesCommittedInstructionsAndRuntimeSlots\(\)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py restore-generated 011 out/plan011/baseline
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^(RecipeRecoveryTest|RecipeBuildTest|RecipeInspectTest|RecipeStagesTest|RecipeManifestBuildTest|RecipeManifestTest|RecipeBuilderOrderingTest)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py check 011 out/plan011/baseline
```

Expected saved shapes: health-claim 57/11680 → 56/11520; health-claim-ready 55/10720 → 54/10560; health-repay 33/6432 → 32/6272. Independently decode instructions against baseline copies: queries and every preceding step/runtime/action/proof byte and index stay exact; only the final comparison disappears and outer commitments/derived inspection summaries update. Add these artifact assertions to test_O12Semantic* before freezing where feasible. All other nine catalogue outputs must be byte-identical. Do not run check-generated 011 as an all-output equality gate: the three intentional changes would correctly fail it.

## Test plan and boundaries

Use existing reserve/claim cases at RecipeRecovery.t.sol:1292–1399 and :1530–1538 as patterns, plus fixed-reference parity above. Cover zero/full/partial fresh-cash repayment, zero repayment at target health, repeated claims, old cash, claim surplus and live need/repayment cap. Test reserve zero, one, uint216.max and uint216.max+1; cash below/equal/one above reserve; empty or zero-ready claim groups; all read/approval flag combinations. Invalid reserve width must retain exact SafeCastOverflowedUintDowncast(216,value), including failure precedence before protocol actions.

Full-width tests must exercise complete recipes without causing unrelated health or token-supply overflow. Burn existing asset balances of account, Morpho, Aave and both issuers first. Claim: mint account uint256.max-20e6 and issuer A 20e6; seed/mature A 20e6, leave B inactive, keep ordinary 300e6 debt/collateral. Cash reaches uint256.max before repaying 20e6 and leaves old cash untouched. Repay: mint account uint256.max, reserve one, repay bounded 100e6 with the same ordinary debt/collateral. For reserve uint216.max, cash uint216.max+1 and repayment one are valid. Include seeded full-uint256 fuzzing constrained only to avoid unrelated supply/health overflow, and assert the reserve implications over independent model inputs.

Ordinary RecoveryTokenMock has no approval callbacks or wrong-debit modes. Add a separate test-only subclass exclusively for effect cases, leaving the metered mocks unchanged. Override approve to mint/burn an account unit on nonzero approval or zero cleanup; retain allowance in a configured _spendAllowance mode so OP_CLEAR_APPROVAL really executes; override _update for account-to-repay transfer to debit ±1 without changing debt. Rebind that semantic fixture's asset/protocol/config and permissions. Test callback reentry with precise failure parity, approval/cleanup cash effects, wrong debit, overclaim/underclaim, malformed runtime/proof and protocol/read failures. Compare exact original/candidate revert bytes and full atomic rollback, including issuer pending/readiness, debt, cash, allowances and trace. Never claim cleanup coverage when the zero-approval optimization silently skipped it.

## Final local verification

Run serially only after focused retention and artifact gates pass. Emit only the recovery snapshot group, then regenerate aggregate reports from a successful full-local run. No hosted CI or live/fork behavior is established here.

```sh
set -euo pipefail
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
shasum -a 256 -c out/plan011/frozen-tests.sha256
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^RecipeRecoveryTest$' --match-test '^(test_GasO03HealthClaim|test_GasO09BoundedIdentityHealthClaim|test_RepayUsesPreviouslySettledCashAndPreservesReserve|test_RecoveryWithdrawsMorphoThenAaveRepaysThenRequestsInOrder|test_GasO12ZeroReserveRepay)\(\)$' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
"$RECIPE_FORGE" build --offline
"$RECIPE_FORGE" fmt --check
git diff --check
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --no-match-contract '.*(Mainnet|Benchmark|Invariant).*' --gas-report --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0 > out/plan011/full-local.log 2>&1
sed -n '/^╭/,/^╰/p' out/plan011/full-local.log > snapshots/gas.txt
"$RECIPE_FORGE" build --offline --sizes > snapshots/sizes.txt
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '.*Invariant.*' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py gas 011 out/plan011
python3 plans/recipe_plan_checks.py restore-generated 011 out/plan011/baseline
python3 plans/recipe_plan_checks.py check 011 out/plan011/baseline
git diff --check
```

Expected: all selected local/invariant tests pass, no new skip, nonempty gas/size reports, pinned Solidity formatting and scope pass. Compare optional full-suite skips to the baseline: production oracle RPC, Hoodi lending RPC, Sepolia native bundle RPC and code-storage boundary under permissive test size limits were the four prior skips. Check changed Markdown/JSON using the repository's Prettier 3.9.6 workflow with explicit allowed paths during authorized execution; do not install/upgrade unrelated dependencies. Perform any test formatting before Step 1 freeze; a changed test hash requires investigation, never silent baseline recapture.

## Done criteria

- [x] One strict target fails for the original footer and passes after only two production deletions.
- [x] Frozen semantic/parity tests pass before and after, including full-width, width-revert and callback/rollback cases.
- [x] Frozen test-file hash remains identical; gas 011 passes three strict improvements and two exact controls.
- [x] Three saved manifests lose only their tails with the stated counts/bytes; nine other outputs stay byte-identical.
- [x] Recovery's old-cash equality and final request observations remain unchanged.
- [x] Full local/invariant, build, formatting, aggregate reports and scope gates pass; actual counts/skips and evidence paths are recorded here and in plans/README.md.

## STOP conditions, rejection and maintenance

Stop on unexplained pin drift, ambiguity in cash operand reconstruction, a broken reference/prefix pin, empty selection, new skip, out-of-scope need or a verification failure repeated after one reasonable repair. A via-IR test size/Tag error may be resolved with separate test contracts/helper deployment inside the same allowed test file before freezing; retain IR and the pinned compiler. If another file is required, stop for scope refinement.

If semantics, artifact or gas gates fail, preserve evidence and restore only this plan's production, tests, docs and generated/snapshot changes from its dirty-baseline copies, including removing new files; never git reset/stash/clean the repository. Re-run original scoped tests and catalogue, verify allowed files match baseline, mark REJECTED with the precise reason and update the index. A rejection may advance the next plan only after restoration is verified.

Future changes to selected repayment bounds, cash debit equality or final snapshot timing must re-prove both reserve implications. Hash changes require separately authorized curator publication/setRecipe adoption; local regeneration does not adopt new commitments. O11 and broader recovery equality removal remain deferred.

## Execution ledger

- 2026-10-14: Human authorized implementation. Worktree: `/Users/andreikorokhov/.codex/worktrees/recipe-optimizations-008-010/adapters`; original checkout preserved. Parent owns the index and commit review.
- Preflight: pinned Foundry 1.8.1 and all four source hashes matched; catalogue selected exactly one passing test. Complete dirty baseline and twelve outputs saved at `out/plan011/baseline`; preflight log at `out/plan011/preflight.log`.
- Step 1 scaffolding: original production retained. Recorded 24 original/prefix/layout/runtime hashes in `out/plan011/pin-record.log`, then embedded literal hashes in tests before frozen capture. Added an ordinary zero-reserve gas control and separate effect-token fixture; existing metered setup/mocks unchanged.
- Fixture rulings before freezing: full-width repayment resets the ordinary debt/collateral position after the separate claim case to avoid unrelated one-unit health rounding; failing-read mock uses a distinct selector so state comparisons can inspect issuer readiness. Extra cash debit fails retained exact-debit equality with `CheckFailed`.

- Review ruling: corrected the new effect-token `approve` comparison to put `msg.sender` on the right, as supplied AGENTS requires. This is the only post-capture test edit and changes no measured fixture. Parent required preserving the first cycle at `out/plan011/first-capture-style-review`, restoring only the pinned original RecoveryRecipe source, and repeating the complete semantics/RED/five-label before/after cycle with a new frozen hash. Repeated gas must equal the first cycle in every label.

### Retained implementation and evidence

- Step 1: twelve semantic tests passed on the original; five fuzz methods each used 100 runs with seed zero. The strict target selected exactly one test and failed only with `old reserve footer remains`. Final test-file SHA-256: `81f53520e9c0c4ff4a2f6bb7c6f9fc2725707c4bada155c821180998e63d8504`.
- Step 2: exactly the two planned footers were removed; all 108 recovery tests passed without skips. The corrected frozen hash remained unchanged. Both repeated before/after gas JSON files equal the preserved first cycle byte for byte.

| Frozen workload               | Before gas | After gas | Gate                      |
| ----------------------------- | ---------: | --------: | ------------------------- |
| O03HealthClaim                |     607602 |    603674 | Strict improvement, -3928 |
| O09BoundedIdentityHealthClaim |     631377 |    627341 | Strict improvement, -4036 |
| repaySettledCash              |     339278 |    335718 | Strict improvement, -3560 |
| recovery                      |    1105759 |   1105759 | Exact control             |
| O12ZeroReserveRepay           |     344540 |    344540 | Exact control             |

- Step 3: catalogue regeneration selected exactly one passing test; focused artifact/build/structure selection passed 180 tests across seven suites, without skips. Machine-readable `out/plan011/artifact-gate.json` independently decodes all twelve outputs and checks recipe keccak: health-claim 57/11680 to 56/11520, health-claim-ready 55/10720 to 54/10560 and health-repay 33/6432 to 32/6272. Queries, preceding raw instructions, runtime/action/proof bytes and inspection prefixes remain exact; nine excluded outputs are byte-identical.
- Final verification: pinned offline build, Solidity formatting, diff and scope checks passed. Full local suite passed 2260 tests across 149 suites, with zero failures and the same four optional skips. Separate invariants passed 18 tests across six suites, without failures/skips. Aggregate gas and size reports are nonempty and regenerated from the successful full run.
- The four skips remain the production ETH-oracle RPC check, Hoodi funded-deployment RPC check, Sepolia official native-interface RPC check and code-storage boundary test under the permissive test code-size limit. No hosted CI, fork or live-chain verification is claimed.
- Snapshot maintenance ruling: Foundry replaces a snapshot group when emitting a partial selection. After detecting missing legacy keys, regenerated all nine unchanged metered methods together, retaining all nine baseline labels plus the new zero-reserve control. `out/plan011/snapshot-group-gate.json` proves all recovery-only labels stay exact, the frozen five labels match the accepted after capture and the additional O01TwoActiveClaims label changes from 613246 to 609305. The five-label acceptance comparator was not changed.
- Logs: `out/plan011/semantic-before.log`, `structural-red.log`, `recovery-green.log`, `gas-before.log`, `gas-after.log`, `gas-comparison.log`, `catalogue-update.log`, `focused-artifacts.log`, `all-recovery-snapshots.log`, `build.log`, `fmt.log`, `full-local.log`, `invariants.log` and `scope-final.log`. First-cycle evidence is retained under `out/plan011/first-capture-style-review/`; baseline copies remain under `out/plan011/baseline/`.
- Commit workflow: parent review precedes integration. Copy only exact reviewed scoped files to the original current branch, preserve helper and unrelated dirty prerequisites, and create one unsigned local commit. Installed staged-only hooks would stash unrelated changes, so run explicit-file pre-commit checks first and skip only `forge-snapshots`, already covered by pinned full-local/invariant/build/snapshot checks. Use a one-command `core.hooksPath=/dev/null` for the subsequent local commit; do not change persistent hook or Git configuration.

- Explicit-file pre-commit 4.6.2 checks passed; YAML/import/error sort hooks had no applicable paths, while line endings, whitespace, EOF, conflict markers, JSON, pinned Solidity formatting and cached Prettier 3.9.6 passed. Only `forge-snapshots` was intentionally skipped for the completed equivalent pinned checks above. No stashing or test/source mutation occurred. Evidence: `out/plan011/pre-commit-explicit.log`.
