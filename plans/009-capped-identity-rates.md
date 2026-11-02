# Plan 009: Omit identity-rate calculations proven safe by a claim cap (O09)

> Execute only when implementation is requested. Follow every gate in order; stop on the conditions below. Record evidence in this plan and its plans/README.md row. This planning task does not authorize source edits, commits, push, PR creation or deployment.

## Status

- Priority: P2
- Effort: S
- Risk: LOW with the complete cap and literal-width predicates
- Depends on: Plan 008 verified DONE or verified REJECTED with source restored; freeze the resulting baseline
- Category: perf
- Planned at: commit c925f8236e0d4768832d85cc5a5ffef4aa369675, 2026-10-13
- Repository: /Users/andreikorokhov/symbiotic/adapters
- State: DONE

## Why this matters

Capped claims calculate a minimum as checked selected*numerator/denominator. When both rate factors equal a positive d and the cap proves selected*d cannot overflow, the minimum is selected. The saved claim-bounded example projects 12→11 instructions and 3,008→2,816 ABI bytes; health-claim-ready projects 57→55 and 11,104→10,720. Each removed three-word MUL_DIV saves 192 bytes. These are structural projections; completion requires improved gas on identical frozen workloads.

## Current state and exact proof

script/recipes/ClaimRecipe.sol:67–68 selects min(claimable,maxAmount) when maxAmount>0. Its minimum at lines 109–116 is:

```solidity
builder.mulDiv(
    amount,
    builder.literal(claim.outputs[j].minNumerator),
    builder.literal(claim.outputs[j].denominator)
)
```

script/recipes/RecoveryRecipe.sol:310–318 similarly caps selected, then calculates:

```solidity
uint256 minimum =
    builder.mulDiv(selected, builder.literal(claimConfig.minAssetPerClaimWad), builder.literal(1e18));
```

For standalone claims, specialize only when maxAmount>0, minNumerator==denominator==d, d>0, d<=type(uint216).max, and maxAmount<=type(uint256).max/d. The existing cap literal conversion must still run: maxAmount must fit uint216. Then selected<=maxAmount proves selected*d<=uint256.max and floor(selected*d/d)==selected, including selected zero. For health claims, require maxAmount>0, minAssetPerClaimWad==1e18 and maxAmount<=type(uint256).max/1e18; the cap conversion still validates its width. Do not substitute maxRepayment for maxAmount: a claim may collect surplus above its repayment budget.

The interpreter's src/contracts/merkle-adapter/Recipes.sol:88–90 performs checked a*b before division. An uncapped selected value or cap above the threshold can overflow even with equal factors. Keep that multiplication exactly in all nonqualifying cases. ExecutingRecipe.literal at script/recipes/ExecutingRecipe.sol:104–105 uses SafeCast.toUint216; skipping a rate's width check without the predicate changes configuration rejection.

docs/RECIPE-CLAIMS.md:46–48 says “Rates use raw units, including differences in decimals” and requires a positive denominator. docs/HEALTH-RECOVERY-RECIPE.md:110–124 requires an exact selected-principal debit and actual received cash. Preserve these meanings, every output delta/minimum comparison, progress witness, pending/readiness debit, lazy gate and approval/callback barrier.

Current SHA-256 pins: ClaimRecipe.sol 6960542f39ea0cafca82f57681ed4ee2c5ad4f5a3c9ed83b93497325c537a002; RecoveryRecipe.sol 9608a9306ba243ef09fbb3bf8ea54b7e8b94494274cdd0ee38e87a8b7328f5a6; ExecutingRecipe.sol 728b5f07daf84cdede4bbad1bb792fa62b6da1cd7ff642fc0ca47f641854a3b1; Recipes.sol f6c8f8f3c7298213d1234dc021bf1233b3397d94f64abc584ef117a9ef8609a1; RecipeExecutor.sol a5568329cae1dbeb05dc48842b42100a55549c2345e9862f7b662f3d3b33ca7a. Only the documented Plan 008 changes to ClaimRecipe and its tests/docs/snapshot may precede execution; other unexplained drift is a stop condition.

## Toolchain, baseline and scope

Run from this repository or an isolated checkout containing the complete current dirty/untracked baseline. Never reset, clean or overwrite unrelated edits. Use Foundry 1.8.1, Solidity 0.8.37, via-IR, optimizer 200, Osaka and bytecode_hash=none from foundry.toml. Do not upgrade dependencies or compilation settings.

Initialize RECIPE_FORGE in every independent shell; the blocks below repeat it deliberately. Run blocks as scripts with their set -e prologue, requiring a zero exit before advancing. The explicitly captured failing-first command is the sole expected nonzero command.

```sh
set -e
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
"$RECIPE_FORGE" --version
git status --short
git diff --stat c925f8236e0d4768832d85cc5a5ffef4aa369675..HEAD -- script/recipes/ClaimRecipe.sol script/recipes/RecoveryRecipe.sol test/adapters/merkle-adapter/RecipeClaims.t.sol test/adapters/merkle-adapter/RecipeRecovery.t.sol docs/RECIPE-CLAIMS.md docs/HEALTH-RECOVERY-RECIPE.md script/recipes/examples/manifests/claim-bounded.json script/recipes/examples/manifests/health-claim-ready.json snapshots/RecipeClaims.json snapshots/RecipeRecovery.json snapshots/gas.txt snapshots/sizes.txt plans/009-capped-identity-rates.md plans/README.md
shasum -a 256 script/recipes/ClaimRecipe.sol script/recipes/RecoveryRecipe.sol script/recipes/ExecutingRecipe.sol src/contracts/merkle-adapter/Recipes.sol src/contracts/merkle-adapter/automations/RecipeExecutor.sol
python3 plans/recipe_plan_checks.py inventory
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^RecipeManifestBuildTest$' --match-test '^test_AllExamplesManifestMatchesCommittedInstructionsAndRuntimeSlots\(\)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py snapshot 009 out/plan009/baseline
```

Expected: pinned version; the catalogue runs one real test and passes; helper captures the complete dirty baseline and twelve generated outputs under ignored out/plan009/baseline. Confirm Plan 008 either DONE (normal claims 34/9,248, eight-output fixture 43/10,848) or verified REJECTED with original source restored (35/9,408 and 50/11,968). Save the resulting source hashes, tests and gas baseline before snapshotting. Missing helper scope/gas support for 009, missing toolchain, stale catalogue or unrelated drift means stop. Never overwrite an earlier evidence directory.

Allowed modifications only:

- script/recipes/ClaimRecipe.sol and script/recipes/RecoveryRecipe.sol.
- test/adapters/merkle-adapter/RecipeClaims.t.sol and RecipeRecovery.t.sol, including focused test-only mocks in those files.
- docs/RECIPE-CLAIMS.md and docs/HEALTH-RECOVERY-RECIPE.md.
- script/recipes/examples/manifests/claim-bounded.json and health-claim-ready.json.
- snapshots/RecipeClaims.json, snapshots/RecipeRecovery.json, snapshots/gas.txt and snapshots/sizes.txt.
- This plan and its plans/README.md evidence/status row.

Do not modify example configurations, generic ExecutingRecipe optimizations, interpreter/executor/capability, lending/recovery requests/repay formulas, other manifests, other plans, helper scope, sibling code or unrelated dirty work. Follow supplied AGENTS.md: address-valued contract references with inline casts, named structs, alphabetic imports, minimum-feature library/test pragmas, no new argument-bearing repository errors or single-use production helper/alias. Existing returned packed operands and runtime layout remain authoritative; never guess shifted indices.

When implementation and local commits are authorized, retain one focused Conventional Commit; the user previously allowed unsigned local commits. This planning selection authorizes neither. Do not push, create a PR or publish/deploy without separate authorization.

## Steps

### 1. Freeze representative fixtures and add failing-first structure tests

Add isolated, nonfuzzed test_GasO09BoundedIdentityClaim in RecipeClaimsTest. Start from _claims()[1] (withdrawal), set maxAmount=40e6 and its sole output numerator=denominator=1e18. Use _singleClaim with the existing withdraw(0,account,account) action, settle 100e18 shares into 100e6 ready assets, then execute exactly 40e6 through the real account/executor. Snapshot RecipeClaims/O09BoundedIdentityClaim immediately after _execute. Assert account cash 57e6, maxWithdraw readiness 60e6, maxRedeem ready shares 60e18 and pendingRedeem zero. In this fixture settleRedeem already removes settled shares from pending at RecipeClaims.t.sol:802–804; withdraw later consumes ready shares at :854–858. This one-output workload works unchanged before/after O08 and O09 and isolates one removable MUL_DIV.

Add isolated test_GasO09BoundedIdentityHealthClaim in RecipeRecoveryTest. Set skipUnusedReads=true; set both claim caps to 20e6, keep both existing 1e18 rates and pending queries, seed/mature 50e6 principal for each issuer, and call _claim(20e6,20e6,40e6). Snapshot RecipeRecovery/O09BoundedIdentityHealthClaim immediately afterward. Assert debt 260e6, old cash 17e6, pending/readiness 30e6 each, cleared repayment allowance and trace count three. Freeze both tests, setup, permissions, mocks and amount choices before either production edit.

Gas placement is load-bearing: RecipeClaims._execute ends with RecipeExecutor.execute; RecipeRecovery._claim ends with _execute, whose final call is RecipeExecutor.execute. Neither helper performs a later external call before returning. Keep snapshotGasLastCall as the next call in each benchmark, ahead of balance/debt/readiness assertions; if a helper changes, call the executor directly or preserve that final-call property. Annotate both benchmarks with /// forge-config: default.isolate = true and do not fuzz them.

Keep test_AllSettledClaimsUseLiveAmountsAndReceiveCorrectTokens (RecipeClaims/claimRedemptionWithdrawalMintRewards) and test_GasO03HealthClaim (RecipeRecovery/O03HealthClaim) as exact-equality controls. The former has maxAmount zero and already-foldable 1/1 rates; the latter has zero claim caps. Both remain unchanged by O09. Their frozen reference is the checkout after verified O08 retention or restoration, not historical snapshot numbers.

Add test_O09CappedIdentityReducesInstructions in both test contracts. Use recorded fixture counts/bytes and decoded instruction assertions in committed tests, never ignored baseline files as test inputs. Before editing production, build/log the exact new configurations and verify their original counts; record those observations in this plan. The single standalone fixture is 12/3,008 before and targets 11/2,816. Two pending-present capped health claims are 59 steps before and target 57; pending-free claims are 57 before and target 55. For the pending-present conditional benchmark, bytes are 12,384 before and 12,000 after. Every removed MUL_DIV saves 192 bytes; record equivalent exact byte pins for the other health modes before using them.

The standalone test must find no identity MUL_DIV, two expected query templates, runtime length one and claimCalls[0]==0; its minimum comparison must reference the selected MIN operand. The health test must retain the target-need MUL_DIV while removing both claim-minimum MUL_DIVs, compare query encodings against the configured expected read templates, and preserve claimCalls [0,1], approve 2, repay 3 and clearApproval 4. Assert both minimum comparisons reference the corresponding selected MIN operands. Cover pending-present/pending-free modes and skipUnusedReads false/true. These tests use normal local fixtures and fixed expected observations, so they remain runnable without out/plan009/. A nontrivial d such as 1e18 is required: 1/1 already folds and cannot demonstrate O09.

Add test_O09Semantic* and testFuzz_O09Semantic* covering the boundaries below. Characterizations must pass before source edits; only the structural deletion target should fail.

```sh
set -e
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^(RecipeClaimsTest|RecipeRecoveryTest)$' --match-test '^test(Fuzz)?_O09Semantic' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan009/before UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^(RecipeClaimsTest|RecipeRecoveryTest)$' --match-test '^(test_GasO09BoundedIdentityClaim|test_GasO09BoundedIdentityHealthClaim|test_AllSettledClaimsUseLiveAmountsAndReceiveCorrectTokens|test_GasO03HealthClaim)\(\)$' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
set +e
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^(RecipeClaimsTest|RecipeRecoveryTest)$' --match-test '^test_O09CappedIdentityReducesInstructions\(\)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
O09_RED_EXIT=$?
set -e
test "$O09_RED_EXIT" -ne 0
```

Expected: nonzero semantic selection passes, exactly four benchmark tests pass and write four labels, then both structural targets fail because safe identity MUL_DIV instructions remain. Stop if a selector runs zero tests, a benchmark is missing, or the structural failure is compilation/unrelated behavior. Preserve all logs; the failing-first command is intentionally nonzero.

### 2. Specialize only safe capped identity minima

At ClaimRecipe's existing minimum argument, use amount for the complete standalone predicate stated above; otherwise call the existing builder.mulDiv with both builder.literal conversions unchanged. At RecoveryRecipe._claim's existing minimum initializer, use selected for the complete health predicate; otherwise retain its current checked calculation. Keep specialization inline. Short-circuit d>0 before division, preserve denominator-zero validation at its current location, and never remove an invalid-width conversion unless the predicate already proves that value fits uint216.

Do not alter amount selection, fresh reads, action order, principal debit, minimum-output comparison, O08 progress witnesses, later need calculations or approval checks. No unconditional cancellation and no new bound on caller/query amounts. All full-width read/input values remain supported; only the existing explicit claim cap bounds selected.

```sh
set -e
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^(RecipeClaimsTest|RecipeRecoveryTest)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan009/after UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^(RecipeClaimsTest|RecipeRecoveryTest)$' --match-test '^(test_GasO09BoundedIdentityClaim|test_GasO09BoundedIdentityHealthClaim|test_AllSettledClaimsUseLiveAmountsAndReceiveCorrectTokens|test_GasO03HealthClaim)\(\)$' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py gas 009 out/plan009
```

Expected: both full focused suites pass, both bounded identity labels strictly improve, and both uncapped controls are exactly equal. If any fixture code must change, discard the pair of measurements, restore production to the captured pre-edit source, freeze the revised fixture and recapture before/after; never compare different workloads or weaken the gate.

### 3. Refresh capped examples and document the proof

```sh
set -e
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
UPDATE_RECIPE_MANIFESTS=true "$RECIPE_FORGE" test --offline --match-contract '^RecipeManifestBuildTest$' --match-test '^test_AllExamplesManifestMatchesCommittedInstructionsAndRuntimeSlots\(\)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py restore-generated 009 out/plan009/baseline
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^RecipeManifestBuildTest$' --match-test '^test_AllExamplesManifestMatchesCommittedInstructionsAndRuntimeSlots\(\)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

Expected: only claim-bounded and health-claim-ready change semantically. Verify respectively 11/2,816 and 55/10,720 instructions/ABI bytes, with unchanged query bytes and runtime count/order. Restore-generated may remove formatting-only drift outside scope; it must reject semantic drift. Uncapped claim, health-claim, health-recovery and health-repay outputs remain byte-identical to the dirty baseline. Document the exact cap predicate, unsafe-cap/uncapped exclusion, 192-byte unit and measured results in the two scoped docs.

## Test plan and cumulative assertions

- Safe selection: zero/one, ready below/equal/above cap, full-width ready with a small cap; rates d=1, 2, 1e18 and uint216.max. Test cap floor(uint256.max/d) and threshold+1 only as runtime overflow boundaries when both caps fit uint216; d=1e18 and d=uint216.max support these cases. Threshold+1 must retain MUL_DIV and Panic(0x11) for a selected overflowing product. For d=1 or 2, those threshold caps exceed uint216 and must instead retain the original cap SafeCast failure; use ordinary small caps for their safe cases, and remember 1/1 already folds. Uncapped equal rates retain their original overflow where the product can overflow. Unequal, zero-numerator, zero-denominator and fractional rates retain existing behavior.
- Literal/failure order: maxAmount>uint216.max retains SafeCastOverflowedUintDowncast(216,value) at the cap selection; equal factors d>uint216.max with cap one must still fail their original conversion. Denominator zero remains InvalidConfiguration, not an introduced division panic. Keep invalid account/claim configuration, invalid pending target/data, query failure and malformed active runtime rejection in their original relative positions. Test an invalid cap plus invalid output config to guard the original earlier cap rejection.
- Use existing public build wrappers and test-only lenses/raw production-recipe prefixes for extreme values; do not cap full-width test inputs to avoid failures or force huge amounts through ERC20 fixture supply/health arithmetic. For runtime arithmetic, compare the original retained checked instruction with the generated safe replacement in the same execution context, including exact revert bytes. Existing RecipeClaims test_O02MinimumMultiplicationStillOverflows must remain green.
- Accounting/rollback: short/excess selected debit, short/zero payout, old balances, partial repeated claims, skipped unreadable outputs, pending-present/pending-free health claims, both optimization flags, surplus cash, zero debt and failed repayment. Existing bounded tests at RecipeClaims.t.sol:185–265 and RecipeRecovery.t.sol:1086–1178 are required, not substitutes for threshold cases.
- If Plan 008 is retained, RecipeClaims.test_O02RemovesOneInstructionPerOutput uses normal 34/9,248 and eight 43/10,848, and test_O03ImpliedPositivityReducesInstructions uses +3 steps/+480 bytes. If O08 is rejected, their original pins remain 35/9,408, 50/11,968 and +2/+320. O09 must not change either verified baseline: these rates are unequal/already-foldable 1/1 or caps zero. test_ManyRewardOutputsFitBuilderCapacity query count nine remains unchanged.
- Recovery.test_O01CashPrefixReadsAreMinimal ordinary claim hash 1907dc1d8784938d4049e6c5184873f2292a6caa66973d47cb31d2c8142aaff7, conditional claim 57/12,064, three prefix cash reads, recovery pins and approval/cleanup barriers remain unchanged because those claims are uncapped. Recovery.test_O03ImpliedPositivityReducesInstructions remains +4/+640. Do not refresh these controls to hide drift.

## Final local verification

After focused semantic, structural and gas gates pass, run these commands sequentially; require a zero exit before the next command. Serial execution avoids the existing testnet fixture environment race.

```sh
set -e
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^(RecipeClaimsTest|RecipeRecoveryTest|RecipeBuildTest|RecipeStagesTest|RecipeManifestBuildTest|RecipeManifestTest|RecipeOptimizationTest)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^(RecipeClaimsTest|RecipeRecoveryTest)$' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
"$RECIPE_FORGE" build --offline
"$RECIPE_FORGE" fmt --check
git diff --check
pnpm dlx prettier@3.9.6 --check plans/009-capped-identity-rates.md plans/README.md docs/RECIPE-CLAIMS.md docs/HEALTH-RECOVERY-RECIPE.md script/recipes/examples/manifests/claim-bounded.json script/recipes/examples/manifests/health-claim-ready.json
python3 plans/recipe_plan_checks.py check 009 out/plan009/baseline
"$RECIPE_FORGE" build --offline --sizes > snapshots/sizes.txt
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --no-match-contract '.*(Mainnet|Benchmark|Invariant).*' --gas-report --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0 > out/plan009/full-local.log 2>&1
sed -n '/^╭/,/^╰/p' out/plan009/full-local.log > snapshots/gas.txt
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '.*Invariant.*' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
git diff --check
python3 plans/recipe_plan_checks.py check 009 out/plan009/baseline
```

Expected: all selected, runnable local and invariant tests pass; build, formatting, whitespace and dirty-scope gates pass. Record actual skips; four optional config/live skips existed historically, but new skips require investigation. Snapshot JSON writes stay within RecipeClaims/RecipeRecovery. Format only modified scoped files if required. Aggregate gas/size reports include the existing dirty baseline; do not attribute unrelated changes to O09.

## Done criteria

- [x] Both structural targets fail first and pass after; safe capped minima lose exactly one MUL_DIV per qualifying output.
- [x] Both frozen bounded benchmarks strictly improve and both uncapped controls are equal through the 009 comparator.
- [x] Checked overflow, width/error ordering, full-width values, debit/output/rollback, O08 and uncapped recovery assertions pass.
- [x] Only two capped manifests change: 11/2,816 and 55/10,720; queries/actions/runtime order preserved and other output bytes unchanged.
- [x] All focused, catalogue, integrated local/invariant, formatting and baseline-scope gates pass.
- [x] This plan and its index row record commands, before/after measurements, changed artifacts, skips, limitations and DONE.

## STOP conditions and maintenance

Stop on an unverified Plan 008 outcome, unexplained source/baseline drift, stale catalogue, absent benchmark labels, zero-test selection, a structural failure unrelated to MUL_DIV removal, changed uncapped bytes/gas, suppressed width/overflow failures, any action/read/check reordering, out-of-scope requirements, two unsuccessful focused repairs, or a failed gas gate. Reject and restore the source candidate if valid frozen workloads do not improve; do not weaken measurements or substitute a new fixture after capture.

The cap proves only the selected claim's product safe. New rates, uncapped claims, request budgets and target-health formulas need independent proofs. Local verification does not establish hosted CI, downstream Go/frontend compatibility, live issuer behavior, wallet/chain execution or deployment; rebuilt commitments must be adopted separately through the curator's normal process.

## Execution evidence — 2026-10-13

Executed after verified Plan 008 DONE at `321802b5f208aa9f6af23ad3ceda5e515cc51045` in the isolated complete-dirty-baseline checkout. Fresh catalogue selected exactly one passing test; `out/plan009/baseline` captured twelve generated outputs and the complete current inventory. Source pins are recorded in `out/plan009/source-before.sha256`; the ClaimRecipe difference from the planning pin is only verified O08. Foundry 1.8.1 / Solidity 0.8.37 / via-IR / optimizer 200 / Osaka / no bytecode hash were retained. No dependency changes or setup lock deviation occurred in this plan.

Frozen before-edit health modes (pending present false/true skipUnusedReads, then pending free false/true): 59/12,000,59/12,384,57/11,104,57/11,360. After: 57/11,616,57/12,000,55/10,720,55/10,976. The saved health-claim-ready example uses pending-free false, so its planned 55/10,720 target is unchanged. Standalone bounded fixture 12/3,008→11/2,816. Every removed MUL_DIV saves 192 bytes; query/action/runtime meanings are preserved.

The final frozen semantic characterization selection passed 16/0/0 before production edits. Both structural targets then failed solely on retained identity products (standalone 1!=0; health 3!=1), and both pass afterward. Tests cover full-width raw observations, cap thresholds and threshold+1 checked overflow, literal widths and failure precedence, genuine production-prefix checked arithmetic controls, zero/unequal/fractional rates, exact debit and payout rollback, both pending modes and both optimization flags, old balances, repeated claims, surplus above repayment cap, zero debt and repayment failure. Existing O08 count/gap assertions and uncapped recovery hash/read/approval controls remain unchanged. Benchmark test source stayed hash-identical across final before/after phases.

| Frozen executor workload                          | Before gas | After gas | Result        |
| ------------------------------------------------- | ---------: | --------: | ------------- |
| RecipeClaims/O09BoundedIdentityClaim              |     149212 |    145223 | 3989 lower    |
| RecipeRecovery/O09BoundedIdentityHealthClaim      |     639433 |    631377 | 8056 lower    |
| RecipeClaims/claimRedemptionWithdrawalMintRewards |     510732 |    510732 | exactly equal |
| RecipeRecovery/O03HealthClaim                     |     607602 |    607602 | exactly equal |

The executable 009 comparator passes both strict improvements and both equality controls. Only claim-bounded and health-claim-ready manifests changed. Exact query bytes, runtime slot counts/opcode order, managed leaves, approval fields and mapped numerical gate/binding references are preserved; the other ten generated outputs remain byte-identical. Catalogue update and post-update verification each select one passing test.

Final serial local verification: focused 140/0/0; integrated scoped 212/0/0; snapshots profile 140/0/0; full-local 2234 passed,0 failed,4 existing skips; invariants 18/0/0. The four skip names match Plan 008:production deployment oracle prices without ETH_RPC_URL, funded Hoodi faucets, code-storage boundary under the permissive test code-size configuration, and official live native interface bundle. No new skip. Offline build, Solidity formatting, scoped Markdown/JSON Prettier 3.9.6, whitespace, manifest preservation and final dirty-scope checks pass. Two test-only lenses add size-report rows; aggregate gas/size reports include the existing dirty baseline.

Before frozen gas capture, scaffold corrections fixed public-getter encoding and expectRevert placement after runtime setup. The first structural attempt exposed the existing cleanup opcode distinction: skipZeroApprovals=false emits OP_APPROVE with zero amount; true emits OP_CLEAR_APPROVAL. The corrected assertion validates the configured opcode plus zero/token/spender payload. All initial logs and first gas snapshots are preserved separately; no production candidate had been edited and no baseline was recaptured. The final measurements use the same frozen tests, setup, mocks and configurations. Production candidate focused repair count: 0. Manifest formatting was corrected only in the two scoped regenerated JSON files before final checks.

All prescribed commands ran with the exact Step 1–3 and final-verification selectors, serial offline execution, threads 1 and fuzz seed 0. Structural discovery/RED and focused characterization added `-vv` for readable counts. Evidence, exact commands and all logs are indexed in `out/plan009/execution-report.md`. Independent task review reports PASS spec/quality, no required findings. No original-checkout writes, commit, push, PR, publication or deployment occurred during this execution; controller review/integration and the focused local commit follow separately. Local checks do not establish hosted CI, live issuer behavior or curator adoption of rebuilt commitments.
