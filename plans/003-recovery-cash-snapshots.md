# Plan 003: Carry cash snapshots through conditional recovery groups (O01)

> Execute only after implementation is requested. Follow the verification gates, preserve the working-tree baseline, and update this plan's row in plans/README.md. This plan does not publish commitments or change permissions.

## Status

- Priority: P2
- Effort: M
- Risk: MED
- Depends on: none logically; execute after Plan002 for a stable integrated recovery baseline
- Category: perf
- Planned at: commit `901c82ca0339d27748af414e537a6d47a0643ec3`, 2026-10-12
- Repository: `/Users/andreikorokhov/symbiotic/adapters`
- State: DONE

## Why this matters

Conditional recovery sources and claims read cash before and after every group even though a fresh initial cash snapshot already exists. Their post-action ReadIf result is not recognized by automatic ordinary-balance reuse, so the before-repayment snapshot reads cash again. Carrying the observed cash removes one pre-action read per configured group and the final repeated read. For two active groups, this section goes from six balance calls to three while retaining exact cash-delta checks.

## Drift check and working-tree state

```sh
git diff --stat 901c82ca0339d27748af414e537a6d47a0643ec3..HEAD -- script/recipes/RecoveryRecipe.sol test/adapters/merkle-adapter/RecipeRecovery.t.sol docs/HEALTH-RECOVERY-RECIPE.md snapshots/RecipeRecovery.json
shasum -a 256 script/recipes/RecoveryRecipe.sol
git status --short
```

Planning source hash is `ecde6d5de46d46da89ec6b7c62fe9933ac4d0a4fcde376b38fa5f0bd03c78a48`, including capped and pending-free claims. Plan002 intentionally omits qualifying _claim positivity guards; this change is allowed drift if its tests/gates passed. Compare all other changes with excerpts below. Step1 uses `plans/recipe_plan_checks.py` to save current source/artifacts/status and hashes/modes of every tracked/untracked nonignored file under ignored out/plan003/. Later checks compare with this dirty baseline, including untracked/addition/deletion changes; never replace baseline evidence to conceal drift. Do not reset/stash existing work. The current checkout includes uncommitted F01, new claim/repayment templates, and unrelated testnet/ThreeF work; HEAD alone is incomplete.

## Current state

RecoveryRecipe.recovery:

```solidity
Snapshot memory initial = _snapshot(builder, config);
// Need/budget calculation and trigger check follow.
for (uint256 i; i < sourcesLength; ++i) {
    (remaining, layout.sourceCalls[i]) = _source(builder, config, config.sources[i], remaining);
}
Snapshot memory beforeRepay = _snapshot(builder, config);
```

_source:

```solidity
uint256 take = builder.binary(OP_MIN, remaining, _readIf(builder, source.capacity, config.skipUnusedReads ? remaining : 1));
uint256 gate = config.skipUnusedReads ? take : 1;
uint256 cash = _balanceIf(builder, config.asset, config.account, gate);
callIndex = builder.manage(source.leaves, take, ExecutingRecipe.amountBindings(source.amountOffsets, take));
builder.check(OP_EQUAL, builder.binary(OP_SUB, _balanceIf(builder, config.asset, config.account, gate), cash), take);
remainingAfter = builder.binary(OP_SUB, remaining, take);
```

The claim path also snapshots initial cash, calls _claim for each group, then snapshots cash again. _claim computes selected=min(claimable,maxAmount) when capped, reads pending (when configured) and cash before Manage, checks the exact selected debit against pending or claimable, reads cash after Manage and checks output. Its conditional gate is selected, not uncapped claimable. _balanceIf currently uses fallback0 for ReadIf; carrying cash requires a previous-cash fallback instead. Preserve all selected-amount and pending-free conventions.

_snapshot freshly reads health, debt and cash. _repay approves, takes fresh cash/debt delta baselines, repays, clears approval, and takes another fresh snapshot. Those repayment/barrier reads must remain. ExecutingRecipe.balance automatically reuses only OP_READ between actions; every action, including OP_CALL_IF, is a barrier. Its stable-standard-ERC20 assumption is appropriate for the configured repayment asset; arbitrary generic getters are intentionally fresh.

Apply repository conventions: retain library/test minimum caret pragmas; compile with0.8.37, IR, optimizer200, Osaka; contracts as addresses; named struct fields; no new argument-bearing errors or one-use helpers. Existing snapshot locals and tuple decoding are permitted. Use builder-returned numerical operands and runtimeSteps mapping; Layout.approve is a runtime slot, not an instruction index.

## Scope

Allowed:

- `script/recipes/RecoveryRecipe.sol`
- `test/adapters/merkle-adapter/RecipeRecovery.t.sol`
- `docs/HEALTH-RECOVERY-RECIPE.md`, `docs/RECIPE-EXECUTOR.md` for measured read/gas notes
- `snapshots/RecipeRecovery.json`
- `snapshots/gas.txt`, `snapshots/sizes.txt` for final required aggregate regeneration
- Plan/index status and evidence

Existing example inputs have skipUnusedReads=false, so their committed manifests must remain byte-identical to this plan's baseline. Generate true-option outputs only under out/ for validation. Do not modify examples to enable an optimization implicitly.

Out of scope: ExecutingRecipe, interpreter/executor/capabilities, standalone ClaimRecipe, LL/lending/3F templates, JSON schema, pending-capacity conventions, F01 sizing logic, issuer allowance guards, health/debt formulas, role/root management, sibling services, deployments and unrelated pre-existing source/snapshots. Plan002's positivity changes must be preserved.

## Git workflow

If requested, use `codex/recipe-recovery-cash-reuse` on the validated current working-tree baseline. No commit/push/PR/publication without operator authorization. Any authorized commit is signed and conventional, e.g. `perf: reuse conditional recovery cash snapshots`.

## Steps

### 1. Establish baseline and immutable gas fixtures

```sh
UPDATE_RECIPE_MANIFESTS=false /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --match-contract RecipeRecoveryTest --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
UPDATE_RECIPE_MANIFESTS=false /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --match-contract RecipeManifestBuildTest --match-test test_AllExamplesManifestMatchesCommittedInstructionsAndRuntimeSlots --gas-snapshot-emit false --gas-snapshot-check false --threads 1
python3 plans/recipe_plan_checks.py inventory
python3 plans/recipe_plan_checks.py snapshot 003 out/plan003/baseline
```

Expected: all current recovery/claim/repay tests and the saved catalogue check pass. Stop on existing stale/missing artifacts; resolve upstream regeneration separately before starting. Add isolated benchmark methods `test_GasO01TwoActiveSources`, `test_GasO01TwoActiveClaims`, `test_GasO01OneActiveGroup`. They use skipUnusedReads=true and unchanged permissions/rates. Snapshot only executor execution into RecipeRecovery labels `O01TwoActiveSources`, `O01TwoActiveClaims`, `O01OneActiveGroup`; assert actual debt, cash, pending, allowances and trace order. Use existing test_GasOptimizedFullyFundedRecovery and claim fixture setup as patterns. Keep these benchmark fixtures unchanged afterward.

```sh
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan003/before /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --isolate --match-contract RecipeRecoveryTest --match-test 'test_GasO01' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

Expected: three pass and the labels appear in out/plan003/before/RecipeRecovery.json, with tracked snapshots untouched. Capture unoptimized skipUnusedReads=false generated recipe bytes as a baseline too.

### 2. Add failure-first read-count and semantic regressions

Add `test_O01CashPrefixReadsAreMinimal` before changing production. Build a two-source true-option recipe, map the repayment approval runtime slot to its instruction with `ExecutingRecipe.runtimeSteps(recipe)[layout.approve]`, and inspect the cash-query Read/ReadIf instructions before that boundary. The target is3, current is6. Repeat for two configured claims. No groups has only the initial cash read and must remain unchanged.

The same prefix can run through the real executor/account with only its group runtime slots to verify actual balance calls via vm.expectCall counts: two active groups need3, one active needs2, zero active needs1. A zero-active claim prefix still contains the final `1 <= freshCash` check and must revert with `IRecipes.CheckFailed.selector`; verify the one-call expectation around that revert. The full zero-active claim also reverts. Never omit this guard to make the prefix succeed. Source prefixes may finish without funding because their later redemption-progress check lies outside this prefix. This count concerns the pre-approval prefix, not the entire recipe, whose later repayment checks still make additional cash calls. Full recipes must also execute in semantic tests.

```sh
/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --match-contract RecipeRecoveryTest --match-test test_O01CashPrefixReadsAreMinimal --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

Expected before source edit: failing 6-versus-3 reduction assertion, not a compile error.

Add `test_O01` / `testFuzz_O01` cases: both active, first active/second zero, first zero/second active, both zero, no configured groups, pre-existing17e6 cash preserved, partial source funding, partial and later claim settlement, capped claims below/above caps, pending-free claims and rejected overclaim, retained claim surplus, zero debt, and malformed runtime for a skipped group. All-empty/no-group claim execution must retain CheckFailed. Fuzz both optimization flags independently where existing semantics permit. Keep or extend insufficient payout, unexpected debt/health change, invalid proof, repayment failure and old-cash-spending rollback tests.

A structural barrier test must confirm a fresh cash read still occurs after approval/before repay and after clearApproval. Preserve the three F01 capped-recovery regression cases. Test reduced cash/incorrect source inflow still fails its exact delta assertion.

### 3. Thread cash through only the conditional paths

Implement the following behavior without adding an onchain state variable or opcode:

1. Start a local cash operand with initial.cash in recovery and claim.
2. Extend _source/_claim input/output tuples to accept previous cash and return post-action cash (retaining remaining/call indices).
3. Under skipUnusedReads=true, use previous cash as the delta baseline. Read post-action cash with ReadIf gated on take for sources or selected for claims, and fallback previous cash.
4. Under skipUnusedReads=false, retain the old ordinary balance reads/build order and emit the same recipe bytes. Carrying an already-produced operand as a build-time local is harmless.
5. After the group loop, fill beforeRepay.cash from the carried operand only for the conditional grouped path. Health and debt are freshly queried at the original snapshot stage. A small snapshot overload used in both paths is acceptable; keep normal _snapshot behavior for initial, repayment and final snapshots.
6. Keep pending reads, capacity reads, exact checked cash/pending deltas, approvals and all _repay reads unchanged. Never carry cash across approval or clearApproval.
7. A zero-gate group must return previous cash, not0. The next active group's baseline and fresh-cash accounting must therefore include all earlier cash, including old cash.

```sh
UPDATE_RECIPE_MANIFESTS=false /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --match-contract RecipeRecoveryTest --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan003/after /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --isolate --match-contract RecipeRecoveryTest --match-test 'test_GasO01' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 - <<'PY'
import json
from pathlib import Path
before=json.loads(Path('out/plan003/before/RecipeRecovery.json').read_text())
after=json.loads(Path('out/plan003/after/RecipeRecovery.json').read_text())
for label in ['O01TwoActiveSources','O01TwoActiveClaims','O01OneActiveGroup']:
    a,b=int(before[label]),int(after[label])
    assert b<a,(label,a,b)
    print(label,a,'->',b)
PY
```

Expected: all tests pass; the true-option two-group prefix has3 read instructions and3 calls if both active,2 calls if one active,1 if neither. For normal read-derived gates with N>=1, remove N+1 cash-read instructions and activeGroupCount+1 calls. Two groups remove512 bytes of recipe ABI encoding. These formulas exclude empty group arrays and already-literal gates. Runtime action slot counts/order remain unchanged; false-option recipe bytes match their saved baseline exactly.

### 4. Verify artifacts and final local gates

Run the saved-manifest check with updates disabled; current examples are all unoptimized, so no manifest changes are expected. Generate true-option recipes to out/ for inspection of new hashes, query definitions, full-width fallback operands and runtime mapping. Use the existing JSON builder fixtures for this test; do not publish.

```sh
UPDATE_RECIPE_MANIFESTS=false /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --match-contract '^(RecipeRecoveryTest|RecipeClaimsTest|LLExecutingTest|RecipeBuildTest|RecipeStagesTest|RecipeManifestBuildTest|RecipeManifestTest|RecipeOptimizationTest)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --isolate --match-contract RecipeRecoveryTest --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge build --offline
/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge fmt --check
git diff --check
python3 plans/recipe_plan_checks.py check 003 out/plan003/baseline
```

Expected: scoped gates pass; all existing saved manifests and unoptimized hash/instruction bytes remain unchanged relative to baseline. Conditional recovery gas labels improve; ordinary recovery/settled-cash repayment labels do not change beyond previously accepted O03 effects.

For final integrated snapshot gates, mirror the pre-commit hook with offline pinned tooling and serial tests. Save a test log before extracting the gas table so failures cannot be hidden by a pipeline:

```sh
/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge build --offline --sizes > snapshots/sizes.txt
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --isolate --no-match-contract '.*(Mainnet|Benchmark|Invariant).*' --gas-report --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0 > out/plan003/full-local.log 2>&1
sed -n '/^╭/,/^╰/p' out/plan003/full-local.log > snapshots/gas.txt
FOUNDRY_PROFILE=snapshots /Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge test --offline --isolate --match-contract '.*Invariant.*' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
git diff --check
python3 plans/recipe_plan_checks.py check 003 out/plan003/baseline
```

Require exit0 from the test command before extracting its table. Expected: all runnable local/invariant tests pass. Record existing optional live/config skips; no mainnet or hosted-CI claim follows. Serial execution avoids the known shared TESTNET_MANIFEST fixture race. Aggregate reports reflect the entire dirty checkout; do not reinterpret pre-existing source/ThreeF changes as this plan's work or regenerate unrelated JSON snapshot labels.

## Done criteria

- [x] Baseline and pre-fix 6-versus-3 failure recorded; unchanged gas fixtures all improve afterward.
- [x] True-option two-group prefix goes6->3 read instructions, with active2/1/0 groups making3/2/1 calls.
- [x] Skipped groups carry full previous cash; initial cash, exact deltas, pending accounting, surplus and partial progress remain correct.
- [x] All F01 regressions, zero-group cases, rollback tests, fresh health/debt and approval-barrier checks pass.
- [x] False-option bytes/hashes and existing example manifests remain unchanged; true-option layouts and hashes validate.
- [x] Selected gas snapshots and aggregate reports refreshed; scoped/build/format/full-serial/invariant/diff gates pass.
- [x] Only allowed files changed relative to dirty baseline; index row records actual gas and DONE.

## STOP conditions

Stop if dirty-baseline drift is unexplained, baseline tests fail, a skipped group loses earlier cash, false-option recipe bytes change, old cash can be repaid inadvertently, a new optimization needs read reuse across approval/action barriers, a change reaches executor/schema/permissions, two focused repair attempts fail, or measured gas does not improve. Do not weaken cash/debt/health/pending assertions to achieve the call target.

## Maintenance notes

A saved cash operand is valid until an action; refresh after each executed group and use the saved operand only when that group actually skips. Static queries alone do not mutate a standard ERC20 balance, but arbitrary balance getters do not qualify. Future source preparation calls or extra actions invalidate the carried snapshot and require a refresh. New conditional recipe bytes require separate rebuilding/publication; existing false-option examples are intentionally unchanged.

## Execution evidence (2026-10-12)

The pre-change reduction test failed with six cash reads against the target of three. It recorded ordinary-mode recovery and claim hashes `97caeb4b4d7974fcd88d82b08c058aea73db5fe14beb5fb5ed87013cfa71d969` and `1907dc1d8784938d4049e6c5184873f2292a6caa66973d47cb31d2c8142aaff7`; the test now asserts both remain unchanged. Conditional two-group recovery/claim encodings shrink from 101 to 98 and 60 to 57 instructions, respectively; encoding shrinks from 22,208 to 21,696 and 12,576 to 12,064 bytes. Runtime slot counts are preserved, and cash reads remain fresh around approval and cleanup.

The initial implementation passed 74 recovery tests, including the actual executor's three, two and one balance-call counts, zero-progress claim revert, full-width skipped-group fallback, independent optimization flags, bounded pending-free surplus, and short-source rollback. Broader BuildRecipe compilation exposed an IR stack-allocation failure in _source. A focused script build reproduced it; removing two redundant temporary operands fixed compilation while preserving builder order. Revalidation uses the same pinned IR/compiler configuration and unchanged execution benchmarks.

Isolated fixture measurements confirmed after the equivalent simplification:

| Fixture            |  Before |   After | Saved |
| ------------------ | ------: | ------: | ----: |
| Two active sources | 1143626 | 1128070 | 15556 |
| Two active claims  |  628597 |  613177 | 15420 |
| One active group   |  773015 |  760067 | 12948 |

Evidence is under ignored `out/plan003/`; these are local fixture measurements, not deployed estimates. Final integrated gates passed: 232 scoped tests, 75 recovery snapshot tests, 2,136 serial local tests and 18 invariant tests, all with zero failures. Four existing optional checks skipped: supplied-token Hoodi integration, factory code-size override, production-oracle RPC check, and live official-bundle interface check. Pinned full build/size regeneration, repository Solidity formatting, scoped Prettier, diff and dirty-scope gates passed. Recovery JSON snapshots and aggregate gas/size reports were refreshed. Aggregate reports describe the entire current dirty checkout, including earlier unrelated work. No mainnet, hosted CI or deployment verification is claimed.

The ordinary recovery and settled-cash repayment labels retain their pre-O01 values; the existing conditional fully funded label improves from 753,709 to 740,766 gas. All 12 catalogue outputs remain byte-identical to the Plan003 baseline. True-option artifacts generated from existing JSON inputs validate their recipe/manifest hashes and runtime mapping under ignored out/. Local changes remain uncommitted. A fresh-context read-only review found no critical, important or minor issues. It independently confirmed the original source hashes and all 12 unchanged catalogue outputs, and assessed the tests and saved gate logs. The review covers the three optimizations under the documented stable ERC20 balance model; live integrations, hosted CI, publication and unrelated dirty work remain outside this verification. The earlier loss of O02 scratch logs is disclosed in the execution ledger; historical measurements remain recorded in Plan001 and the conversation, and recovered source hashes remain available.
