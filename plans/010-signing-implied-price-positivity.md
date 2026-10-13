# Plan 010: Omit signing price positivity implied by the output floor (O10)

> Executed after explicit implementation authorization, first independently and then cumulatively after committed plans 008 and 009. Fresh cumulative local retention gates pass; controller review and the focused local commit follow separately.

## Status

- Priority: P2
- Effort: S
- Risk: LOW
- Depends on: none semantically; execute after 008 and 009 for a stable serial baseline
- Category: perf
- Planned at: commit c925f8236e0d4768832d85cc5a5ffef4aa369675, 2026-10-13
- Repository: /Users/andreikorokhov/symbiotic/adapters
- State: DONE locally (cumulative verification complete)

## Why this matters

Signing checks both a positive oracle price and a positive computed output floor. A zero price necessarily produces a zero quote and zero minimum, so the retained floor check already rejects it with CheckFailed. Removing only the price comparison projects the existing CoW fixture from 15 to 14 instructions and the Liquid Lane fixture from 14 to 13, saving 160 ABI-encoded bytes each. Successful execution gas must improve in both frozen workloads; no new gas result has been measured.

## Current state and proof

script/recipes/SigningRecipe.sol:94–103 currently emits:

```solidity
builder.check(OP_LESS_OR_EQUAL, builder.literal(config.minAmount), amount);
builder.check(OP_LESS_OR_EQUAL, amount, builder.literal(config.maxAmount));
uint256 price = builder.read(config.price);
builder.check(OP_LESS_OR_EQUAL, builder.literal(1), price);
uint256 quote = builder.mulDiv(amount, price, builder.literal(config.priceDenominator));
uint256 minimum = builder.binary(
    OP_SUB, quote, builder.mulDiv(quote, builder.literal(config.slippageBps), builder.literal(10_000))
);
builder.check(OP_LESS_OR_EQUAL, builder.literal(1), minimum);
builder.check(OP_LESS_OR_EQUAL, minimum, output);
```

Configuration at lines 53–59 already requires minAmount > 0, minAmount <= maxAmount, priceDenominator > 0 and slippageBps < 10_000. For price = 0, both products and minimum are zero without overflow or division by zero. The retained minimum check fails before input 1 is read, the clock is queried or the account is managed. For positive prices, all currently checked multiplication/subtraction and failure order remain intact. Zero-price rejection executes extra numerical instructions after the change; its selector/effects remain identical, but its gas need not improve.

Recipes.sol:90 implements checked a * b / denominator; do not substitute full-precision Math.mulDiv or cancel factors. SigningRecipe.sol:104–109 retains the trusted clock read, deadline bounds and CoW uint32 check. Lines 60–88 validate canonical sign calldata and restrict masking to distinct buffer words; lines 114–121 sort bindings by calldata offset while preserving each input association. None of those operations changes.

SigningRecipeTest.setUp at test/adapters/merkle-adapter/SigningRecipe.t.sol:35–62 builds real RecipeExecutor/MerkleAccount authorization. Its config uses amount bounds 1e18/100e18, priceDenominator 1e30, slippageBps 100, maxDuration 300 and CoW offsets 260/292/324 with deadlineBytes 4. SigningReads defaults to price 2e18 and rejects observations older than 60 seconds. The Liquid Lane test at lines 98–153 supplies the fixed three-element hash plan and offsets amount 196, output 420, deadline 260 and nonce 292, with deadlineBytes 32.

The unmodified CoW runtime map is [14]; Liquid Lane is [13]. Both have two queries and one final Manage with literal-one gate. After O10 those maps become [13] and [12]; runtime slot count/order stays one. CoW binds inputs 0/1/2 at offsets 260/292/324. Liquid Lane binds inputs 0/2/3/1 in increasing offset order 196/260/292/420. The sign leaf, data, mask, target and proof requirements stay exact; only the outer recipe commitment and numerical instruction references shift.

docs/RECIPE-SIGNING.md:21–25 requires an oracle for the fixed pair that rejects stale/invalid observations and a trusted clock returning block.timestamp. Lines 34–48 require verified protocol economic offsets and fixed domain/pair/recipient/hash plan. Line 80 makes limits per authorization, without an aggregate order budget. Preserve these policies; this reduction adds no permissions or new economic guarantees.

Production SHA-256: SigningRecipe.sol = e4cc9e8238119caf213a02c709b2d0153d668cdd6bf3009d3be3b09b2fa73ffe.

## Toolchain, drift and dirty baseline

Run in the repository or an isolated checkout containing the complete current working-tree baseline. Preserve concurrent ThreeFPolicy/testnet work and completed F01/O01–O05. O06/O07 were rejected; do not revive them. Never reset, clean, overwrite or commit unrelated edits.

Initialize RECIPE_FORGE in every independent tool shell; an export from a previous shell does not persist. The passing gate blocks below use set -euo pipefail so a failed command cannot be hidden by a later success. Run the expected structural failure in its separate shell block with errexit disabled.

```sh
set -euo pipefail
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
git status --short
git diff --stat c925f8236e0d4768832d85cc5a5ffef4aa369675..HEAD -- script/recipes/SigningRecipe.sol test/adapters/merkle-adapter/SigningRecipe.t.sol docs/RECIPE-SIGNING.md snapshots/SigningRecipe.json snapshots/gas.txt snapshots/sizes.txt plans/README.md plans/010-signing-implied-price-positivity.md
shasum -a 256 script/recipes/SigningRecipe.sol
"$RECIPE_FORGE" --version
python3 plans/recipe_plan_checks.py inventory
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract RecipeManifestBuildTest --match-test test_AllExamplesManifestMatchesCommittedInstructionsAndRuntimeSlots --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py snapshot 010 out/plan010/baseline
```

Expected: the production pin and excerpts match, Foundry is 1.8.1, the catalogue passes and the helper captures tracked/untracked hashes plus all twelve generated outputs. Planning/index/helper changes are expected metadata drift; unexplained production/test drift is a stop condition. Do not replace existing evidence directories. An unavailable pinned executable or stale/missing catalogue must be resolved separately before implementation.

foundry.toml pins Solidity 0.8.37, via-IR, optimizer 200, Osaka and bytecode_hash=none. Keep these settings and dependencies. Follow AGENTS.md: retain feature-minimum library/test pragmas, use address for contract instances, named struct initializers, grouped sorted imports, argument-free repository errors and no single-use production helper. Match the existing test fixtures and returned packed operands rather than guessed result indices.

The planning helper defines scope 010 and strict gas labels SigningRecipe/O10CoW and SigningRecipe/O10LiquidLane. Its check compares the live tree with this fresh dirty baseline. Do not modify or widen the helper during execution. Tests may write ignored out/plan010 evidence; source changes must stay reviewable in their normal paths.

## Scope and Git workflow

Allowed modifications only:

- script/recipes/SigningRecipe.sol.
- test/adapters/merkle-adapter/SigningRecipe.t.sol, including reusable test-only helpers in that file.
- docs/RECIPE-SIGNING.md for the implication and measured result.
- NEW snapshots/SigningRecipe.json, plus required snapshots/gas.txt and snapshots/sizes.txt.
- This plan and plans/README.md status/evidence.

Do not change BuildRecipe, RecipeManifest, generic builder/interpreter/executor/capability, signing interfaces, masks, hash plans, input layouts, example configs, saved manifests/fixtures, other templates, permissions, deployment code or sibling consumers. No tree-file update is required. All twelve existing generated outputs must remain byte-identical.

When implementation and local commits are authorized, retain one focused Conventional Commit; the user previously allowed unsigned local commits. This planning selection authorizes neither. A suitable message is perf: omit implied signing price positivity. Do not push, open a PR, publish recipes, deploy or grant new permissions. A separately requested new branch uses codex/.

## Steps

### 1. Add and freeze characterization and gas fixtures

After the baseline snapshot, add test_GasO10CoW and test_GasO10LiquidLane in SigningRecipeTest. Annotate each with /// forge-config: default.isolate = true and keep them nonfuzzed. Build/configure the recipe, accepted root, executor leaf role and recipe commitment before measurement. Copy queries/steps to memory and allocate the input/action/runtime arrays before calling execute. Use price 2e18, inputs [100e18, 198e6, block.timestamp + 300], plus nonce 7 for Liquid Lane, and the existing canonical protocol buffers/hash plans. Reuse a test-only Liquid Lane config helper across the existing semantic test and new fixtures if needed; freeze all setup/helper/method code before baseline gas capture.

Call RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, inputs, runtime) directly; its signature is execute(bytes[],bytes[],uint256[],bytes[]) returning uint256[]. Immediately call vm.snapshotGasLastCall("SigningRecipe", "O10CoW") or vm.snapshotGasLastCall("SigningRecipe", "O10LiquidLane"), before any assertion or other external call. Then verify the expected CoW or Liquid Lane digest is accepted by account.isValidSignature and signatures(digest). No build, permission setup or unrelated settlement belongs in the measured call.

Add test_O10PriceGuardReducesInstructions for both exact configs. Create a small frozen test-only reference that rebuilds the baseline numerical sequence above, the unchanged clock/deadline sequence and final Manage payload. The Manage payload contains only input/literal operands, so copying that verified final payload from the production recipe into the reference does not require result-index rewriting. Derive other result references through ExecutingRecipe.Builder. Independently assert query bytes, sign data/mask/leaf and the final sorted bindings against the config. Require baseline counts 15/14, optimized counts 14/13 and a 160-byte encoded-length reduction against the same reference configuration. Assert the price comparison is absent, the positive minimum check remains, and both checked MUL_DIV instructions remain. This target must fail before the production change.

Add test_O10Semantic*/testFuzz_O10Semantic* before baseline gas capture. Compare reference/current exact revert bytes and accepted digests using real executor/account calls and reset state between successful runs; configure each tested recipe outside execution. Cover zero/live/stale prices, floor-minus-one/exact-floor, zero/one-unit rounding, both amount boundaries, slippage 0/1/100/9999, deadline now/expired/too long and the uint32 boundary. Refresh the oracle after a timestamp warp in deadline tests so StalePrice cannot mask the deadline check; retain deliberate stale-price cases separately. Retain forged-runtime overwrite, nonce binding, fixed domain/pair/recipient/hash plan and direct-provider rejection coverage. Authorization data/mask/leaf must match exactly in both versions.

Include both distinct checked multiplication failures with representable config literals: quote overflow uses the standard amount 100e18 and queried price type(uint256).max; slippage overflow sets priceDenominator = 1, amount = 1e18 and queried price type(uint256).max / 1e18, so the first product fits while quote * 100 overflows. The existing min/max/slippage literals fit uint216. Require exact Panic(0x11), with no approved digest or event/state effects; never constrain queried prices to uint216 or introduce a runtime cap to avoid the case.

For malformed inputs, assert Panic(0x32) for missing amount, missing output with a valid positive floor, missing deadline with a valid output, and missing Liquid Lane nonce after valid checks. A one-element array holding a valid amount with zero price must instead retain CheckFailed before attempting input 1. Pair zero price with a reverting clock query and malformed runtime to confirm CheckFailed still precedes either operation; stale price must retain SigningReads.StalePrice. Price/time remain distinct trusted observations, with no provider-supplied clock.

```sh
set -euo pipefail
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^SigningRecipeTest$' --match-test '^test(Fuzz)?_O10Semantic' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan010/before UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^SigningRecipeTest$' --match-test '^test_GasO10' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

Expected: all semantic characterizations pass; verify exactly two isolated gas tests actually ran and wrote positive O10CoW/O10LiquidLane labels to out/plan010/before/SigningRecipe.json. A zero-test success is a stop condition. Freeze the complete fixture/test source before production editing; do not tune benchmarks afterward.

Run this expected structural failure separately from the passing block above; its nonzero exit is required and must not suppress the later authorized production step:

```sh
set +e
set -uo pipefail
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^SigningRecipeTest$' --match-test test_O10PriceGuardReducesInstructions --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

Expected: only the structural target fails on the retained price guard. Confirm the test ran and its failed assertion describes the intended reduction. Empty selections or compilation failures are not a failing-first result.

### 2. Remove only the implied comparison

Delete builder.check(OP_LESS_OR_EQUAL, builder.literal(1), price) at SigningRecipe.sol:97. Retain the price query and every other check/arithmetic operation in relative order. Add no option, local alias, helper, rounding rewrite, full-precision multiplication or permission change. Update the docs' positive-price bullet to explain the retained positive output floor rejects zero prices; preserve stale-oracle, units, clock, verified-layout and per-authorization policies.

```sh
set -euo pipefail
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^SigningRecipeTest$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan010/after UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^SigningRecipeTest$' --match-test '^test_GasO10' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py gas 010 out/plan010
```

Expected: all semantic/structural tests pass, exactly two isolated benchmark tests run and both unchanged successful workloads strictly improve. Verify both positive labels came from this run; empty selections fail the gate. The comparator rejects missing/nonpositive labels, equal gas or regressions. Zero-price rejection may cost more while preserving the exact selector, query order and rollback; disclose this rather than claiming every failure path improves. If either success benchmark fails, restore only this plan's builder/docs/snapshot changes to its captured baseline and mark REJECTED with evidence; do not weaken checks or retain an unprofitable rewrite.

### 3. Verify export consistency and preserve the catalogue

The existing test_BuildScriptProducesTheSameSigningProgramAndAuthorization builds temporary signing JSON and compares its recipeHash, signData and signMask to the current builder. It must continue passing with the changed outer hash. The catalogue discovers every direct examples/*.json at RecipeManifest.t.sol:84–98; there is no signing exclusion, but no signing JSON example currently exists. Do not add one for O10 or regenerate unrelated samples.

```sh
set -euo pipefail
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^(SigningRecipeTest|RecipeBuildTest|RecipeInspectTest|RecipeStagesTest|RecipeManifestBuildTest|RecipeManifestTest|RecipeBuilderOrderingTest)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py check-generated 010 out/plan010/baseline
```

Expected: all scoped tests pass and all twelve generated outputs match byte for byte. The signing export's queries, sign leaf/data/mask and runtime count/order remain unchanged; CoW/Liquid Lane final instruction indices each decrease by one. A new signing commitment requires separately authorized recipe publication for adoption.

## Final local verification

After the focused gates pass, run commands serially. Each must exit zero before the next; extract an aggregate gas report only from a successful test log. Snapshot emission is restricted to the new SigningRecipe group.

```sh
set -euo pipefail
export RECIPE_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^SigningRecipeTest$' --match-test '^test_GasO10' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
"$RECIPE_FORGE" build --offline
"$RECIPE_FORGE" fmt --check
git diff --check
python3 plans/recipe_plan_checks.py check-generated 010 out/plan010/baseline
python3 plans/recipe_plan_checks.py check 010 out/plan010/baseline
"$RECIPE_FORGE" build --offline --sizes > snapshots/sizes.txt
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --no-match-contract '.*(Mainnet|Benchmark|Invariant).*' --gas-report --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0 > out/plan010/full-local.log 2>&1
sed -n '/^╭/,/^╰/p' out/plan010/full-local.log > snapshots/gas.txt
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '.*Invariant.*' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
git diff --check
python3 plans/recipe_plan_checks.py check-generated 010 out/plan010/baseline
python3 plans/recipe_plan_checks.py check 010 out/plan010/baseline
```

Expected: all runnable local/invariant tests, build, formatting and scope gates pass. Record actual optional skips and investigate new ones. Serial runs preserve the existing testnet environment fixtures. Format only allowed changed files if needed; check changed docs/plan/index with pnpm dlx prettier@3.9.6 --check, naming those files. Aggregate reports include the whole dirty baseline; do not mistake concurrent work for this plan's effect.

## Evidence to record

Keep the failing-first log, semantic/focused logs, before/after SigningRecipe.json measurements, gas-comparator output and final catalogue/scope outputs under ignored out/plan010/. Record the exact toolchain version, executed/skipped test counts, unchanged authorization and generated-output checks, and the two instruction/length reductions in this plan and its index row.

Review the sole production deletion independently from the new test reference. A reference that silently mirrors the optimized source cannot prove the old baseline; preserve its explicit positive-price guard and the original arithmetic/check ordering.

## Done criteria

- [x] The structural target fails on the baseline guard and passes after its sole deletion.
- [x] CoW is 15→14; Liquid Lane is 14→13; both lose 160 bytes, with exact query/auth bytes and one unchanged runtime slot.
- [x] Both checked multiplication failures, malformed-input selectors, zero-price ordering, trusted/stale reads and native digests pass.
- [x] Both frozen gas labels strictly improve through the executable comparator; fixture code stayed unchanged after baseline capture.
- [x] All twelve generated outputs remain byte-identical; only allowed snapshots/source/docs/status change.
- [x] Final serial local/scope checks pass; this plan/index record measurements, limits and DONE, or a verified rejection.

## STOP conditions and maintenance

Stop on unexplained source/test drift, missing baseline/pinned toolchain, stale catalogue, an empty benchmark selection, altered mask/leaf/hash plan/input schema or runtime order, changed overflow/revert semantics, an out-of-scope requirement, two unsuccessful focused repairs or either success gas gate failing. Do not remove the positive minimum check or replace checked arithmetic to force improvement.

Future economic-layout, slippage, unit, oracle or clock changes require a fresh proof. Keep authorization leaf roles restricted to the executor. Record local evidence separately from hosted CI, sibling consumer compatibility, live permissions/chain execution and deployment, none of which this plan establishes. No implementation, new measurement or generated output was produced during planning.

## Independent execution evidence (2026-10-13)

The sole production change removes the explicit price-positivity comparison. Frozen original reference and real-account differential tests preserve checked arithmetic, exact errors, native signatures, queries, sign data/mask/leaf and bindings. CoW is **15→14 instructions** and Liquid Lane is **14→13**, each losing **160 ABI-encoded bytes**; their one runtime slot shifts from instruction 14→13 and 13→12 respectively.

Authoritative RED/GREEN and before/after evidence lives under `out/plan010/revision2/`; full report: `out/plan010/execution-report.md`. Restored-guard RED executed one structural test and failed at the intended `15 != 14` reduction assertion (exit 1); GREEN passed **22/22 signing tests**, no skips. Both isolated benchmarks ran exactly two tests per capture. Strict executable comparison passes: **CoW 189,236→185,734 gas (−3,502)**; **Liquid Lane 193,686→190,136 (−3,550)**. The entire test-source SHA stayed unchanged after authoritative before capture. Zero-price rejection executes extra arithmetic; its exact error/order/rollback remain tested, but zero-price gas was not measured and no failure-path improvement is claimed.

The final serial local run passed **2,219 tests across 149 suites, 0 failures, 4 skips**; invariants passed **18 tests across 6 suites, 0 failures/skips**. Scoped export verification passed **94 tests across 7 suites, 0 failures/skips**. Baseline catalogue passed 1/1, and all twelve generated outputs remain byte-identical. Build, repository formatting, diff, allowed-scope and generated-output gates pass; SigningRecipe snapshots contain the two measured final labels. Optional full-suite skips are the ETH production oracle/RPC check, Hoodi lending RPC check, Sepolia live-native-interface RPC check and the code-storage-limit test requiring `FOUNDRY_CODE_SIZE_LIMIT=24576`.

Setup initially found incomplete dependency source folders; the parent restored exact original pinned sources and verified clean dependency/lockfile status before the catalogue/baseline gates. No dependency upgrade was retained. Before final fixture capture, a reserved test identifier and an aliased forged-action struct were corrected. Revision1 GREEN exposed a hardcoded structural minimum index; with parent approval, the guard was restored and a decoded producer reference replaced that assertion before a fresh revision2 RED/before/after sequence. Original evidence is preserved; benchmark methods/setup remained unchanged, both revised baselines exactly match revision1, and the complete frozen reference retains the explicit price guard.

Only this plan's eight allowed files changed relative to the preserved dirty baseline. No commit, publication, hosted CI, sibling-consumer, live-wallet/chain/permissions or deployment verification is claimed. The subsequent cumulative verification is recorded below; a new recipe commitment requires separately authorized publication.

## Cumulative execution evidence (2026-10-13)

Executed in `/Users/andreikorokhov/.codex/worktrees/recipe-optimizations-008-010/adapters` after committed 008 `321802b5f208aa9f6af23ad3ceda5e515cc51045` and 009 `a9a2896d9e80ce2e52b4007e458dd64beee2bbbd`. Fresh catalogue passed 1/1 before transfer, and `out/plan010-cumulative/baseline/` captured the complete latest dirty inventory and all twelve outputs. Only the frozen test file was transferred before new baseline semantics/gas/RED with the old guard present. The whole test-source SHA remains **b1e5d917df6a10235e5cd38028885d4c193e89a9e986d82679b7fdac71029758**; the reviewed one-line production deletion has SHA **4bf37a80cc5356155906506708de15ebc8032033ef99b38384200d889480123f**. Independent revision2 evidence remains immutable.

Fresh cumulative baseline semantics passed **9/0/0** with 100 fuzz runs; structural RED executed one test and failed only at expected `15 != 14` (exit 1). GREEN signing passed **22/0/0**. Both isolated before/after captures ran exactly two tests, with no skips. The strict helper comparator again passes **CoW 189,236→185,734** and **Liquid Lane 193,686→190,136**; final snapshot emission is restricted to SigningRecipe. No fixture, configuration, helper or arithmetic tuning occurred. Instruction/byte/query/auth/runtime proofs remain unchanged. Zero-price gas was not measured; its extra arithmetic and identical errors/order/rollback are disclosed.

Fresh serial cumulative gates: prescribed export scope **94/0/0 across 7 suites**; expanded Claims/Recovery/Signing integration **234/0/0 across 9**; full local **2,246 passed, 0 failed, 4 skipped across 149 (2,250 selected)**; invariants **18/0/0 across 6**. The same four optional RPC/code-size skips are retained and no Plan010 test skips. Offline build, full Solidity formatting, scoped Prettier 3.9.6, diff, frozen SHA, strict gas, generated-output and allowed-scope checks pass. Both aggregate snapshots were regenerated from this successful cumulative suite; independent reports were not copied. All twelve generated outputs stay byte-identical to 009. No 008/009 source, tests, docs or manifests were changed.

Cumulative logs and exact command ledger: `out/plan010-cumulative/execution-report.md`. Independent task review passed spec and quality with no required findings; fresh whole-batch review also reports PASS with no actionable findings in `out/recipe-final-review/report.md`; all eleven reviewed hashes still match after final metadata updates. README preserves earlier DONE rows and explicitly distinguishes historical planning checkpoints from current measurements and local commits. Only the eight allowed 010 files differ from the fresh 009 dirty baseline; dependencies, lockfile and helper scopes remain unchanged. This task made no original-checkout writes, commits, new agents, push, PR, publication or deployment. New recipe commitments still require separately authorized adoption.

Controller-reported original-checkout verification separately passed **166 focused tests** and **6 isolated gas fixtures**. The six measured after labels match the cumulative evidence exactly: bounded claim 145,223; bounded health claim 631,377; uncapped claim control 510,732; uncapped health control 607,602; CoW 185,734; Liquid Lane 190,136. These were run by the controller; this task made no original-checkout writes. Fresh review did not rerun tests and is independent evidence assessment; the completed cumulative full/invariant and final scope checks are recorded above.
