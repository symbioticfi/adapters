# Plan 012: Omit cap-proven scaled identity floors in Liquid Lane (O13)

> Execute only after explicit implementation authorization. This selection requests a plan, not source edits or commits. Follow the gates in order and record evidence here and in plans/README.md.

## Status

- Priority: P3
- Effort: S
- Risk: LOW only with the complete cap, positive-factor and literal-width predicate
- Depends on: Plan 011 verified DONE or verified REJECTED with its changes restored; capture a new baseline
- Category: perf
- Planned at: commit dfea206f3a427968cf98cb766e0eab1399b93349, 2026-10-14
- Repository: /Users/andreikorokhov/symbiotic/adapters
- State: DONE — locally verified; parent integration and separate commit pending

## Why this matters

Liquid Lane redemption still calculates checked amountIn*numerator/denominator for scaled identity rates such as 1e18/1e18. A safe positive amount cap proves that product cannot overflow, so the minimum can be amountIn. Eligible programs lose one MUL_DIV and 192 ABI bytes. Current saved LL examples use 1/1, already folded by the builder; all twelve catalogue outputs must remain byte-identical. Workload value is optional and gas is unmeasured: retain only if both signed scaled-rate workloads improve and both 1/1 controls stay exactly equal.

## Current state and exact predicate

script/recipes/LLExecuting.sol:67–70 builds input 0 and 1, then checks literal(1) <= amountIn <= literal(config.maxAmountIn) before funding. Inside the nonempty redemption branch at lines 103–108:

```solidity
uint256 minimum = builder.mulDiv(
    layout.amountIn,
    builder.literal(config.redemption.minReceiptNumerator),
    builder.literal(config.redemption.receiptDenominator)
);
```

Specialize inline only when maxAmountIn > 0, numerator == denominator == d, d > 0, d <= type(uint216).max, and maxAmountIn <= type(uint256).max/d. Keep the existing maxAmountIn literal conversion at line 70. Use the full predicate with short-circuit d > 0 before division; no new production helper or alias is necessary. Then 1 <= amountIn <= cap proves amountIn*d <= uint256.max and floor(amountIn*d/d) == amountIn. Return layout.amountIn for this branch; otherwise execute the original mulDiv expression with the same conversions and evaluation order.

ExecutingRecipe.literal at script/recipes/ExecutingRecipe.sol:104–105 uses SafeCast.toUint216. Recipes.sol:90 uses checked a*b before division. Equality alone cannot cancel an overflowing product. The width predicate prevents losing the original rate conversion error. Cap zero, zero denominator, unequal rates, invalid widths and unsafe caps must use the original path; do not add a configuration validator or change division-by-zero/overflow failure behavior. A raw uint256 input remains full width and must fail the cap check before funding when too large.

Keep every cash/recipient delta, exact newly received RWA, consuming/retained-RWA check, fresh receipt delta/minimum, approval cleanup, binding, permission, signature and callback barrier. docs/RECIPE-EXECUTOR.md:495–520 defines funding and both redemption modes. Existing receipts/old RWA cannot satisfy a new receipt/disposal requirement.

Source SHA-256 pins: LLExecuting.sol = f5b1cd6bdc888ac79ab405723f26fb171dbad1d8bb964dab41f39513338f5b29; ExecutingRecipe.sol = 728b5f07daf84cdede4bbad1bb792fa62b6da1cd7ff642fc0ca47f641854a3b1; Recipes.sol = f6c8f8f3c7298213d1234dc021bf1233b3397d94f64abc584ef117a9ef8609a1; RecipeExecutor.sol = a5568329cae1dbeb05dc48842b42100a55549c2345e9862f7b662f3d3b33ca7a. Only verified Plan 011 changes to its documented recovery scope may precede execution; unexplained LL/shared-runtime drift is a stop.

## Toolchain, baseline, scope and Git workflow

Use an isolated checkout containing the complete current tracked/untracked dirty baseline and the verified result of 011. Preserve unrelated ThreeFPolicy/testnet work. Do not reset, clean or stash the original checkout. Use Foundry 1.8.1 at the path below, Solidity 0.8.37, via-IR, optimizer 200, Osaka and bytecode_hash=none. Missing tools/dependencies require a stop, not an upgrade or installation during this task.

Allowed files only:

- script/recipes/LLExecuting.sol.
- test/adapters/merkle-adapter/LLExecuting.t.sol, including test-only references/helpers in that file.
- docs/RECIPE-EXECUTOR.md.
- snapshots/LLExecuting.json, snapshots/gas.txt and snapshots/sizes.txt.
- This plan and plans/README.md.

Do not change connector/account/signing code, generic builder/interpreter/executor/capability, other templates, permissions, runtime actions/masks, example configurations, saved manifests/fixtures, Plan 011 files, helper scopes, deployment code or sibling consumers. The helper already defines scope 012; do not widen it. Match supplied AGENTS.md: address-valued instances with inline casts, named struct fields, sorted imports, feature-minimum library/test pragmas, argument-free repository errors, no single-use production helper and explanatory unchecked comments if any arithmetic is unchecked. No unchecked arithmetic is needed for this candidate.

If implementation and commits are later requested, use one separate Conventional Commit, for example perf: omit capped Liquid Lane identity floors. Unsigned local commits were explicitly allowed earlier. Do not push, open a PR, publish recipes or deploy without separate authorization. A requested new branch uses codex/.

Every shell block repeats its prologue and pinned executable. Except the explicit RED block, require a zero exit before the next gate. Evidence directories must be new and ignored; never overwrite an earlier run.

```sh
set -euo pipefail
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
"$RECIPE_FORGE" --version
git status --short
git diff --stat dfea206f3a427968cf98cb766e0eab1399b93349..HEAD -- script/recipes/LLExecuting.sol test/adapters/merkle-adapter/LLExecuting.t.sol docs/RECIPE-EXECUTOR.md
shasum -a 256 script/recipes/LLExecuting.sol script/recipes/ExecutingRecipe.sol src/contracts/merkle-adapter/Recipes.sol src/contracts/merkle-adapter/automations/RecipeExecutor.sol
python3 plans/recipe_plan_checks.py inventory
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^RecipeManifestBuildTest$' --match-test '^test_AllExamplesManifestMatchesCommittedInstructionsAndRuntimeSlots\(\)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py snapshot 012 out/plan012/baseline
```

Expected: version/pins match, verified 011 retention/restoration is recorded, the catalogue selects exactly one passing test, and the helper saves the complete dirty tree plus all twelve generated outputs. Never reuse 011's baseline. A stale catalogue, missing tool or unexplained drift means stop.

## Steps

### 1. Freeze original LL construction, signed semantics and four gas workloads

Copy the complete current LLExecuting.build into a test-only frozen reference library in LLExecuting.t.sol BEFORE production edits. Keep the original minimum expression and every action/check/read in original order. It may reuse unchanged ExecutingRecipe.Builder, but must never call LLExecuting.build internally. Add a separate pure buildReferenceRecipe wrapper; let _prepare choose this wrapper only in differential/reference fixtures. Keep the existing production buildRecipe wrapper. Add test-only cap overrides defaulting to the original 1000 if needed for threshold execution; freeze their setup/helper paths before gas capture. Do not splice numeric indices to create the old reference.

Independently compare query bytes, leaves/data masks, action order, bindings and named layout to configured expected values. Prepare both versions from identical snapshotted chain state, including permissions, signer/domain/nonces, source liquidity and token state. Execute through the actual RecipeExecutor, MerkleAccount and LiquidLaneConnector; never mock signature acceptance. Compare success, exact revert bytes, meaningful numerical values via decoded producer mapping, balances, source calls/liquidity, redeemed count, allowances, signer/nonce state and logs. Raw result arrays differ in length/indices after removing a numerical instruction and cannot be compared wholesale.

Freeze isolated nonfuzzed test_GasO13ScaledIdentityConsume and test_GasO13ScaledIdentityRetain. Begin with _plan() at LLExecuting.t.sol:940: amountIn/redeemAmount/receiptAmount 100, amountOut 90, source amounts 30/60, minReceiptNumerator 1e18; set _receiptDenominator = 1e18 and cap 1000. Use _swapData(10_000_000,type(uint48).max,type(uint48).max,false), retaining actual delegated signer and protocol signatures. Retain mode also sets _retainsRwa = true and RecipeIssuerReceipt(_issuer).setRetainsRwa(true).

Both scaled fixtures must end with source withdrawals 30/60, recipient cash 90, account cash 0, receipt balance 100, lane RWA 999900, issuer RWA 0 and both account allowances 0. Consume leaves account RWA 0 and RecipeRwaToken.redeemed() 100; retain leaves account RWA 100 and redeemed 0. _execute at line 1224 ends with the native executor call under _provider. Allocate/build/sign/configure before measurement, snapshotGasLastCall immediately after that call, then assert effects.

Keep existing test_GasO03LLPositiveMinimum / O03LLPositiveMinimum as the consuming 1/1 control. Add test_GasO13IdentityRetainControl with the same retained fixture but original rate 1/1. Its scaled sibling differs only in the rate factors. Gas policy 012 is:

| LLExecuting label        | Acceptance     |
| ------------------------ | -------------- |
| O13ScaledIdentityConsume | Strictly lower |
| O13ScaledIdentityRetain  | Strictly lower |
| O03LLPositiveMinimum     | Exactly equal  |
| O13IdentityRetainControl | Exactly equal  |

Adjust existing test_O03ImpliedPositivityReducesInstructions before freezing: compare prepareO03(1e18-1) versus prepareO03(1e18+1). Both are nonidentity rates; its original +1 instruction/+160-byte assertion still isolates O03. The old 1e18 comparison would include this plan's additional 192-byte removal. No other previous optimization gate may be weakened.

Add test_O13CappedIdentityReducesInstructions as the strict RED/GREEN target. For consume and retain, assert the reference has one scaled identity MUL_DIV, candidate has none, candidate is one step/192 ABI bytes smaller, and minimum <= freshReceiptDelta uses layout.amountIn directly. Assert exact equality for 1/1, unsafe, unequal and no-redemption controls. Compare six query bytes in order: first capacity, account cash, second capacity, recipient cash, account RWA, receipt. Runtime ordinals sourceCalls [0,1], approve/operation/clearApproval [2,3,4], redeemApprove/redeem/redeemClearApproval [5,6,7] and sourceAmounts operands remain unchanged; derive numerical instruction references from builder/layout/runtimeSteps. Verify source binding 36 and signed-swap binding 100 to input 0; the two configured redemption actions remain fixed/unbound in one group.

Static tracing projects consume 45/9952 → 44/9760 with runtime instruction indices [7,14,18,22,32,34,37,44] → [7,14,18,22,32,33,36,43]. Confirm and put literal observed counts/lengths and reference hashes in tests before production edits; record the retained-mode observations separately rather than assuming equal sizes. A mismatch means investigate the fixture before capture, not edit source to fit projections. Tests must not read ignored evidence files.

Add test_O13Semantic* and testFuzz_O13Semantic* covering the boundary list below. They must pass on the original source. Finish Solidity formatting, reference review and all test scaffolding before hashing the entire LLExecuting.t.sol to out/plan012/frozen-tests.sha256. The file, metered methods, setup, helper paths, mocks, authorization and amounts must remain identical through before/after capture.

```sh
set -euo pipefail
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^LLExecutingTest$' --match-test '^(test_O13Semantic.*|testFuzz_O13Semantic.*|test_O03ImpliedPositivityReducesInstructions\(\))$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0 -vv
shasum -a 256 test/adapters/merkle-adapter/LLExecuting.t.sol > out/plan012/frozen-tests.sha256
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan012/before UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^LLExecutingTest$' --match-test '^(test_GasO13ScaledIdentityConsume|test_GasO13ScaledIdentityRetain|test_GasO03LLPositiveMinimum|test_GasO13IdentityRetainControl)\(\)$' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

Expected: semantic tests and the preserved O03 comparison pass without skips, fuzz uses the pinned 100 runs/seed zero, exactly four benchmark methods pass and every positive label exists in before/LLExecuting.json. Historical O03 snapshot gas is context only; use fresh measurements.

Run the strict failing-first target separately:

```sh
set -uo pipefail
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^LLExecutingTest$' --match-test '^test_O13CappedIdentityReducesInstructions\(\)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0 -vv > out/plan012/structural-red.log 2>&1
red_status=$?
test "$red_status" -ne 0
```

Expected: exactly one failing test solely on the original scaled identity product. Open the log; compile/fixture failures or zero tests do not qualify.

### 2. Inline the complete safe identity predicate and verify GREEN plus gas

Replace only the quoted minimum expression with the predicate described above and layout.amountIn for qualifying cases, preserving the existing expression as the fallback. Keep it inside the nonempty-redemption branch. Do not change positivity logic, maxAmountIn literal validation, fund/swap/redemption checks, layouts or authorization.

```sh
set -euo pipefail
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
shasum -a 256 -c out/plan012/frozen-tests.sha256
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^LLExecutingTest$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan012/after UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^LLExecutingTest$' --match-test '^(test_GasO13ScaledIdentityConsume|test_GasO13ScaledIdentityRetain|test_GasO03LLPositiveMinimum|test_GasO13IdentityRetainControl)\(\)$' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py gas 012 out/plan012
```

Expected: strict structure and all LL tests pass; both scaled gas labels improve; both 1/1 labels equal exactly. Missing/nonpositive labels, a regression, absent strict savings or changed control requires rejection, not fixture tuning or comparator relaxation.

### 3. Document the proof and verify exact export preservation

Update docs/RECIPE-EXECUTOR.md's Liquid Lane section with the cap/overflow/width proof, checked fallback and measured scaled-rate results. State that current saved examples get no additional savings. Do not regenerate or reformat saved outputs: no catalogue artifact is in scope. Existing build/catalogue tests must validate inspection and exported runtime slots against current source.

```sh
set -euo pipefail
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^(LLExecutingTest|RecipeBuildTest|RecipeInspectTest|RecipeStagesTest|RecipeManifestBuildTest|RecipeManifestTest|RecipeBuilderOrderingTest)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py check-generated 012 out/plan012/baseline
python3 plans/recipe_plan_checks.py check 012 out/plan012/baseline
```

Expected: all scoped tests pass; all twelve generated outputs, including ll-executing 44 instructions and ll-cooldown 42, match the verified post-011 baseline byte for byte. Add scaled build/inspection assertions within the allowed LL test file if missing; do not modify BuildRecipe or export test files to achieve this.

## Test plan and boundaries

Follow test_GasO03LLPositiveMinimum, test_RetainedCooldownMustMeetFreshReceiptMinimum and existing signature/rollback cases. Verify both redemption modes, all read/approval flag combinations, no-redemption paths, empty runtime/input, amount zero and cap zero, zero numerator/denominator, equal/unequal/fractional factors and denominators, literal width boundaries, full-width inputs, short/zero fresh receipt, old receipts/RWA/cash, consuming/retained mismatch, wrong input binding/payment recipient, approvals/cleanup and callback failures. Preserve invalid domain/signature/nonce/deadline/proof/role failures and exact rollback; rate specialization must not bypass native authorization.

For d = 1e18 and uint216.max, test threshold = uint256.max/d and threshold+1 using complete signed execution. Cap threshold plus amount threshold is safe; cap threshold+1 plus amount threshold+1 must retain MUL_DIV and Panic(0x11); amount threshold+1 above a threshold cap fails early with CheckFailed. To avoid mock inventory/funding overflow, set discount 100_000_000, amountOut and both source amounts zero, amountIn/redeemAmount/receiptAmount to the tested amount, cap to the tested literal-valid value, and use forge-std deal(_rwa,_lane,amount,true) before the differential snapshot. LiquidLaneConnector.getAmountOut uses full-precision mulDiv, then its discounted output multiplies by zero; real signatures/transfers/burns still execute. Restore identical protocol and supply state between versions. Do not mock the minimum or manually execute a substituted prefix.

For d=1 use literal-valid caps (uint216.max), since uint256.max/d itself does not fit the cap literal. Input uint256.max with any literal-valid cap must fail before funding. Test d=0 and denominator zero on the original path with Panic(0x12), while recognizing that earlier width/amount errors can take precedence. Test numerator and denominator uint216.max+1 independently and together, cap uint216.max+1, and mixed invalid inputs/configurations. Compare frozen-reference exact error bytes; do not invent Solidity argument evaluation ordering. SafeCast errors keep their upstream arguments. Fuzz positive equality/product thresholds with full-uint256 seeds, plus unsafe caps and nonidentity controls; keep gas tests nonfuzzed.

## Final local verification

Run serially only after the focused retention/export gates pass. Emit only the LL snapshot group and regenerate aggregate reports from a successful full-local run. No hosted CI or live issuer/fork behavior is established here.

```sh
set -euo pipefail
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
shasum -a 256 -c out/plan012/frozen-tests.sha256
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^LLExecutingTest$' --match-test '^test_Gas.*' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
"$RECIPE_FORGE" build --offline
"$RECIPE_FORGE" fmt --check
git diff --check
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --no-match-contract '.*(Mainnet|Benchmark|Invariant).*' --gas-report --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0 > out/plan012/full-local.log 2>&1
sed -n '/^╭/,/^╰/p' out/plan012/full-local.log > snapshots/gas.txt
"$RECIPE_FORGE" build --offline --sizes > snapshots/sizes.txt
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '.*Invariant.*' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py gas 012 out/plan012
python3 plans/recipe_plan_checks.py check-generated 012 out/plan012/baseline
python3 plans/recipe_plan_checks.py check 012 out/plan012/baseline
git diff --check
```

Expected: local/invariant tests pass, no new skips, nonempty gas/size reports and formatting/scope gates pass. Compare optional full-suite skips to the fresh baseline: the prior four were production oracle RPC, Hoodi lending RPC, Sepolia native bundle RPC and code-storage boundary under permissive test size limits. Check changed Markdown via the repository's Prettier 3.9.6 workflow with explicit allowed paths during authorized execution; do not install/upgrade unrelated dependencies. Test formatting must precede the frozen hash; investigate any later mismatch without silent baseline recapture.

## Done criteria

- [x] Strict target fails for the original product and passes after the sole inline specialization.
- [x] Qualifying scaled fixtures each lose one MUL_DIV/192 ABI bytes; unsafe/nonidentity/1/1/no-redemption controls preserve original instructions/errors.
- [x] Frozen native signed differential tests pass before and after, including threshold overflow, width precedence and rollback.
- [x] Frozen test-file hash matches; gas 012 passes two strict reductions and two exact controls.
- [x] All twelve saved catalogue outputs and native action/authorization bytes remain exact.
- [x] Full local/invariant, build, formatting, aggregate reports and scope gates pass; actual counts/skips, gas and evidence paths are recorded here and in plans/README.md.

## STOP conditions, rejection and maintenance

Stop on unexplained pin drift, an unfaithful frozen reference, incorrect source/runtime mapping, inability to exercise native signatures or threshold arithmetic, empty selection, new skip, out-of-scope need or a verification failure repeated after one reasonable repair. Resolve via-IR test size/Tag errors with separate test/helper contracts in the same allowed LL test file before freezing, using helper deployment if needed; retain IR/compiler settings. If a new file is necessary, stop for scope refinement.

If semantic/export/gas gates fail, preserve evidence and restore only this plan's production, tests, docs and snapshot changes from dirty-baseline copies, including removing any newly created file. Never git reset/stash/clean the original repository. Re-run original scoped tests and catalogue, verify all allowed files match baseline, mark REJECTED with the exact failed gate and update the index. No saved example benefit is expected; synthetic instruction savings alone do not justify retention.

Future changes to the pre-funding amount cap, literal encoding width or checked product semantics require re-proving this predicate. New qualifying recipe commitments require separately authorized publication/setRecipe adoption. Generic identity cancellation, O11 cached-read experiments and lending identity specialization remain deferred.

## Execution ledger

- 2026-10-14: Human authorized implementation and separate unsigned local commits. Plan 011 was verified and integrated first as `b1cb6cad03d07398558028f265dc7f9a1af4e93b`. Execution used `/Users/andreikorokhov/.codex/worktrees/recipe-optimizations-008-010/adapters`; its HEAD intentionally stayed at `dfea206f3a427968cf98cb766e0eab1399b93349`, with the complete dirty prerequisites and verified Plan 011 files. The original checkout was not edited by this executor. Parent owns the index, integration and commit review.
- Preflight: pinned Foundry 1.8.1, compiler/configuration and all four source SHA-256 pins matched. The catalogue selected exactly one passing test. A fresh complete dirty baseline and all twelve outputs were saved at `out/plan012/baseline/`, after Plan 011 verification; its earlier baseline was not reused. Evidence: `out/plan012/preflight-catalogue.log`.
- Step 1: copied the complete original LL builder into the test-only `O13FrozenLLExecuting` library, preserving its complete body except qualification of the original Config/Layout types. Native signatures, signer/domain/nonces, real connector/account/executor, bindings, permission and callback barriers remain active. Added independent state/log/error and numerical-producer comparisons, full native threshold executions, width/error precedence and rollback cases. Existing O03 comparison uses the planned two nonidentity rates and retains its original instruction/byte gate.
- Pre-freeze review corrected reserved test identifiers, added the frozen library title/notice and made the optional redemption state comparison distinguish the five-slot no-redemption recipe. These corrections were completed before application, compilation and frozen capture. No test-file edits occurred after the final frozen hash, so no capture repeat was necessary.
- Original observation: consuming and retained references both contain 45 steps and 9952 ABI bytes, with numerical/runtime mappings asserted independently in tests. Consuming reference instructions hash: `339aab82f84de39a1a458644f8779c586e4846ada6e231889ea8bb43eda3a733`; retained reference hash: `47cb0e8529d0231299bd69492855147ad9b706bf2b9ae69d3c396e5696795379`. Literal observations were embedded before production edits; tests do not read evidence files. Evidence: `out/plan012/reference-pins.log`.
- Original semantic selection passed 13 tests with no failures/skips, including three fuzz methods at 100 runs and seed zero. The strict RED selection ran exactly one failing test, solely `capped identity product remains: 1 != 0`. There were no compilation or fixture failures. Whole LL test-file SHA-256 frozen before gas capture: `72010b182a73128be7720f842231338a62a7ef53e0c045231b7f7b08cd61d51d`.
- Step 2: production changes only the nonempty-redemption minimum expression, with the complete cap/equality/positive-factor/literal-width/product-safety predicate and unchanged checked fallback. Qualifying native signed consuming and retained programs are 44 steps/9760 bytes, one MUL_DIV and 192 bytes smaller. The GREEN LL selection passed all 74 tests without failures/skips. The frozen test hash remained identical.

| Frozen workload          | Before gas | After gas | Gate                      |
| ------------------------ | ---------: | --------: | ------------------------- |
| O13ScaledIdentityConsume |     872491 |    868455 | Strict improvement, -4036 |
| O13ScaledIdentityRetain  |     848945 |    844909 | Strict improvement, -4036 |
| O03LLPositiveMinimum     |     868455 |    868455 | Exact control             |
| O13IdentityRetainControl |     844909 |    844909 | Exact control             |

- Step 3: documentation records the overflow/width proof, checked fallback and measured native execution gas. Export/build/inspection/runtime/ordering selection passed 146 tests across seven suites, with no failures/skips. All twelve saved catalogue outputs remain byte-identical to the fresh post-011 baseline. Current saved LL examples use 1/1 and receive no additional savings; no recipe publication or `setRecipe` adoption was performed.
- Final verification: pinned offline build, global Solidity formatting and diff checks passed. Full local gas-report suite passed 2276 tests across 149 suites, with zero failures and exactly the same four optional skips as Plan 011. Separate invariants passed 18 tests across six suites without failures/skips. Gas and size reports are nonempty and were regenerated from the successful full run; the size report remains byte-identical to the baseline.
- The four unchanged skips are the production ETH-oracle RPC check, Hoodi funded-deployment RPC check, Sepolia official native-interface RPC check and code-storage boundary test under the permissive test code-size limit. No hosted CI, fork, live issuer or live-chain verification is claimed.
- Complete LL snapshot maintenance: emitted all eight LL gas methods together rather than a partial group. The final group contains all eight baseline labels plus the three new labels. Every baseline value remains exact; the four accepted labels match the frozen after capture. `out/plan012/final-snapshot-and-skip-gate.json` records the label equality, exact skip equivalence, summaries and final frozen hash. The gas acceptance comparator was not weakened.
- Evidence: `out/plan012/scaffold-semantic-original.log`, `structural-red.log`, `ll-green.log`, `gas-before.log`, `gas-after.log`, `export-focused.log`, `ll-snapshot-complete.log`, `build.log`, `fmt-check.log`, `full-local.log`, `invariants.log` and `final-snapshot-and-skip-gate.json`. Original copies remain under `out/plan012/baseline/`; before/after measurements remain under `out/plan012/before/` and `out/plan012/after/`.
- Parent independently verified gas acceptance, all twelve catalogue bytes, complete LL snapshot preservation and both frozen test hashes. A separate read-only reviewer passed production, frozen scaffold and final documentation with no material issues. Integration and the separate unsigned local commit remain subject to the parent's final gate; no original writes, commits or pushes have been performed by this executor.

- Explicit-file pre-commit 4.6.2 checks passed with pinned Forge and cached Prettier 3.9.6. Line endings, whitespace, EOF, conflict markers, Solidity formatting and non-Solidity formatting passed; JSON/YAML/import/error hooks had no applicable files under their configured filters. Only `forge-snapshots` was intentionally skipped after completing the equivalent pinned full-local, invariant, build and complete LL snapshot gates. There was no stashing or source/test mutation. Evidence: `out/plan012/pre-commit-explicit.log`; the final record is checked again at `out/plan012/pre-commit-explicit-final.log`.
