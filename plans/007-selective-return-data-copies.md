# Plan 007: Retain selective return-data copies only when they improve real workloads (O07)

> Execute only when implementation is requested. This is a benchmark-gated optimization. Preserve the prior production path for any subpath that fails its semantic or performance gate.

## Status

- Priority: P3
- Effort: M
- Risk: MED
- Depends on: plans 004/005 DONE and plan 006 terminal (DONE or REJECTED with production restoration verified)
- Category: perf
- Planned at: commit 901c82ca0339d27748af414e537a6d47a0643ec3, 2026-10-12
- Repository: /Users/andreikorokhov/symbiotic/adapters
- State: REJECTED

## Why this matters

Ordinary reads copy a whole successful response and use one word; direct calls discard the successfully copied bytes. A narrower copy can save memory/allocation work, especially for multiword responses. Typical ERC20 responses are only 32 bytes, so realistic small-response and actual recipe measurements must pass before retaining either subpath.

## Current state and compatibility contract

src/contracts/merkle-adapter/Recipes.sol:57–66 currently decodes/binds a query, then:

```solidity
bytes memory result = target.functionStaticCall(data);
if (offset + 32 > result.length) revert InvalidQuery();
if (operation == OP_READ_CACHED) {
    state.readData = result;
    state.readIndex = state.index + 1;
}
return uint256(result.load(offset));
```

Direct Call/CallIf use target.functionCall(data) at line 78 and discard its response. OpenZeppelin Address.functionStaticCall / functionCallWithValue (lib/openzeppelin-contracts/contracts/utils/Address.sol:79–109) call LowLevelCall with no output buffer, then copy the full successful returndata. Its exact validation order is:

1. Successful call with response bytes, or successful empty response from a code-bearing target, is valid.
2. Successful empty response from a no-code target raises Address.AddressEmptyCode(target).
3. Failed call with response bytes bubbles those exact bytes.
4. Failed call with empty response raises Errors.FailedCall().

Only after this validation does a read check offset + 32 (checked arithmetic) against response size. Preserve Panic(0x11) for offset addition overflow and InvalidQuery for an incomplete word. Offsets are uint256 and may be unaligned. A successful nonempty precompile response is valid even with no deployed code.

ReadIf with a zero gate does not decode, bind or call its query; CallIf with a zero gate does not decode the complete call tuple. ReadCached must still retain the **entire** latest response. ReadWord must still reference the latest explicit producer and load every bit at the requested offset. These are documented at docs/RECIPE-EXECUTOR.md:169–181 and :236–237 and tested by RecipeTupleTest / RecipeExecutorReview.t.sol.

Manage responses and approval bool validation belong to RecipeExecutor/MerkleAccount and are **out of scope**. Do not apply this proposal to them.

Before O06, Recipes.sol SHA-256 is f6c8f8f3c7298213d1234dc021bf1233b3397d94f64abc584ef117a9ef8609a1. O06 may intentionally change only the internal signature/extraction and its wrapper callers; read/call/cache branches must still match the excerpt. Read the O06 terminal evidence and verify its exact scoped production diff and new hash before capturing this baseline. If O06 was rejected, verify the original production sources were restored without losing pre-existing edits.

```sh
git diff --stat 901c82ca0339d27748af414e537a6d47a0643ec3..HEAD -- src/contracts/merkle-adapter/Recipes.sol
shasum -a 256 src/contracts/merkle-adapter/Recipes.sol
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
python3 plans/recipe_plan_checks.py snapshot 007 out/plan007/baseline
```

Expected: catalogue passes; the helper records hashes/modes/status of tracked and untracked nonignored files and copies scoped files plus all twelve generated outputs into ignored out/plan007/baseline. Resolve existing stale/missing examples as separate upstream work before starting. Never replace evidence. Add tests only after capturing this baseline; capture gas only after the complete benchmark fixture code is frozen and before editing production.

The helper's check compares against this dirty baseline, not HEAD. restore-generated may restore only formatting-only differences outside scope and refuses semantic drift. Treat concurrent changes as drift requiring investigation, not changes to delete. out/plan007/ is ignored evidence, not an allowed place to hide source changes.

## Scope

Allowed modifications only:

- src/contracts/merkle-adapter/Recipes.sol.
- test/adapters/merkle-adapter/RecipeReturnDataOptimization.t.sol (create, with test-only harness/mocks).
- docs/RECIPE-EXECUTOR.md for measured results and precise retained semantics.

- snapshots/RecipeExecutor.json, RecipeCapability.json, RecipeTuple.json, RecipeLending.json, RecipeRecovery.json, RecipeClaims.json and LLExecuting.json.
- snapshots/gas.txt and snapshots/sizes.txt only for final required regeneration.

- snapshots/RecipeReturnData.json for the new isolated measurements.
- This plan and plans/README.md status/evidence.

Read existing benchmark tests and dependencies, but do not modify them. Do not edit executor/capability wrappers, account/approval behavior, interfaces/errors/schema/opcodes/state layout, generic query/binding ABI decoding, builders, manifests/examples, dependency code, compiler settings or sibling code. Do not replace cached reads with scalar snapshots, cache generic queries, change gas forwarding or change revert reasons. Do not widen the scope helper.

## Steps

### 1. Build the reference and response matrix before production changes

Create RecipeReturnDataOptimizationTest and a same-address test harness inheriting Recipes. Copy the current post-O06 shared interpreter method into a frozen baseline method using Address's current full-copy calls. Expose legacy/live execution entries with independent fresh State. Compare full low-level return/revert bytes and target state after restoring identical initial state. Use the same harness address so target-observed caller/context stays equal. All new external helpers/mocks remain test-only.

A configurable test target must return raw byte buffers or raw revert buffers without ABI encoding them again. Cover:

- Read/active ReadIf: lengths 0, 1, 31, 32, 33, 63, 64, 128 and a larger diagnostic buffer; offset zero, unaligned offset one, last valid word, one byte short, type(uint256).max-31 and type(uint256).max. Fuzz full-width words and valid offsets.
- No-code empty response, code-bearing empty success, nonempty identity-precompile success, empty revert, custom error/panic/string/arbitrary nonempty reverts. Exact error bytes and precedence are mandatory.
- Call/active CallIf: zero/short/32/multiword successful response, zero ETH value, caller identity, state changes and a later failed check rolling them back.
- Static-call mutation attempts must still fail with the same bubbled/empty failure behavior.
- Skipped ReadIf/CallIf retain fallback/zero results and avoid deliberately reverting or malformed unused query/call data, as currently specified.
- Full ReadCached/ReadWord response, latest-producer replacement, unaligned/full-width words, invalid/forward/old producer, invalid offset and cached data surviving intervening ordinary reads. Cached semantics must agree exactly.
- Existing malformed query/call ABI and bindings remain unchanged; do not implement a custom metadata decoder here.

Add isolated nonfuzz gas tests with group RecipeReturnData and labels scalar32, tuple128, ignoredCallEmpty, ignoredCall32, readIfSkipped, callIfSkipped and cached128. Snapshot only execution, then assert output/state/caller. Use ordinary 32-byte token-like getters, a realistic four-word getter and a setter with no/one-word response. A large synthetic response is diagnostic evidence only, never the sole adoption justification. Freeze the entire new fixture before production changes.

```sh
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract RecipeReturnDataOptimizationTest --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan007/before UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract RecipeReturnDataOptimizationTest --match-test '^test_GasO07' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

Expected: all characterization tests pass on the original full-copy implementation and all seven new baseline labels exist.

### Capture the unchanged production workload matrix

Plans 004/005 provide the stable lending fixtures and final builder bytes. The following existing tests provide fourteen required gas labels: lending O04Sync/O04Async; recovery recovery/O01TwoActiveSources/O01TwoActiveClaims; standalone claim claimRedemptionWithdrawalMintRewards; LL O03LLPositiveMinimum; capability executeChecksAndBindings/executeReadAndCheck/executeEmpty; tuple ordinaryTupleReads/cachedTupleReads; executor executeCall/executeRead. Read their assertions and preserve them.

```sh
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan007/before UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^(RecipeLendingTest|RecipeRecoveryTest|RecipeClaimsTest|LLExecutingTest|RecipeCapabilityTest|RecipeTupleTest|RecipeExecutorTest)$' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
"$RECIPE_FORGE" inspect RecipeExecutor abi --json > out/plan007/before/RecipeExecutor.abi.json
"$RECIPE_FORGE" inspect RecipeCapability abi --json > out/plan007/before/RecipeCapability.abi.json
```

Expected: all suites pass and all fourteen labels exist under before/. Capture deployed bytecode lengths from out/RecipeExecutor.sol/RecipeExecutor.json and out/RecipeCapability.sol/RecipeCapability.json into the plan's evidence before editing production; strip an optional 0x prefix and divide deployedBytecode.object's length by two. Also freeze a copy/hash of every benchmark test source under ignored evidence. Do not modify benchmark code between measurements.

### 2. Prototype narrow successful-return paths

Prefer the existing OpenZeppelin LowLevelCall.callNoReturn/staticcallNoReturn/returnDataSize/bubbleRevert primitives. Import existing Address and Errors error names without redefining signatures. Keep cached reads on the current Address full-response path.

For ordinary Read and active ReadIf: bind data in the same order, call with STATICCALL, reproduce Address's success/failure validation exactly, then perform the original Solidity checked offset+32 size test. Only after those checks copy the selected 32 bytes with memory-safe assembly and return the complete word. Do not perform another external call between the low-level query and inspecting/copying its returndata. Keep scratch/free-memory use correct and explain it.

For direct Call and active CallIf: call with CALL, zero value and normal gas forwarding, preserve target-code/success/error handling, and avoid allocating/copying successful returndata. Failures still bubble the entire error. Keep gate and binding validation positions unchanged.

Inline single-use logic under the repository rule; use a helper only if genuinely shared across more than one site. Do not change third-party files. Scalar and ignored-call subpaths may be retained independently if only one proves worthwhile; keep the other on its old path and re-run the entire matrix.

```sh
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^(RecipeReturnDataOptimizationTest|RecipeExecutor.*Test|RecipeCapabilityTest|RecipeTupleTest|RecipePackingTest|RecipeOptimizationTest)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots FOUNDRY_SNAPSHOTS=out/plan007/after UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract RecipeReturnDataOptimizationTest --match-test '^test_GasO07' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

Expected: exact semantic agreement and seven after labels from unchanged fixtures. A gas-dependent out-of-gas cutoff is not an exact-semantic comparison target; all deterministic errors and application-visible effects are.

### Verify gas, ABI and commitments

Repeat the identical workload matrix with FOUNDRY_SNAPSHOTS=out/plan007/after. Test files and environment must match before; production code is the only difference. Then run:

```sh
python3 plans/recipe_plan_checks.py gas 007 out/plan007
"$RECIPE_FORGE" inspect RecipeExecutor abi --json > out/plan007/after/RecipeExecutor.abi.json
"$RECIPE_FORGE" inspect RecipeCapability abi --json > out/plan007/after/RecipeCapability.abi.json
python3 - <<'PY'
import json
from pathlib import Path
evidence = Path('out/plan007')
for name in ('RecipeExecutor', 'RecipeCapability'):
    assert json.loads((evidence / 'before' / (name + '.abi.json')).read_text()) == json.loads((evidence / 'after' / (name + '.abi.json')).read_text()), name
    artifact = json.loads(Path('out', name + '.sol', name + '.json').read_text())
    size = len(artifact['deployedBytecode']['object'].removeprefix('0x')) // 2
    assert size <= 24576, (name, size)
    print(name, 'deployed bytes:', size)
PY
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract RecipeManifestBuildTest --match-test test_AllExamplesManifestMatchesCommittedInstructionsAndRuntimeSlots --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
python3 plans/recipe_plan_checks.py check-generated 007 out/plan007/baseline
```

Expected: all gas criteria pass, both public ABIs are identical, both implementations remain under 24,576 deployed bytes, and all twelve saved generated files retain exact baseline bytes. Record size differences and any added deployment cost separately from execution savings. Do not regenerate recipe manifests or change hash/schema/version constants for an internal runtime optimization.

Gas acceptance is explicit: all fourteen representative labels and seven new small/control labels must be no worse, and at least one lending/recovery/claim/LL/active-capability/ordinary-tuple workload must strictly improve. A gain confined to the synthetic large-response case does not qualify. Report which subpaths were retained, absolute savings and code-size cost.

If either subpath regresses, restore that subpath only and retest. If the resulting candidate still fails the overall gate, restore this plan's production diff against the captured baseline and mark REJECTED with evidence. Do not change benchmark fixtures or comparator thresholds to manufacture a pass.

## Final local verification

After the focused semantic and gas gates pass, run:

```sh
UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --match-contract '^(RecipeReturnDataOptimizationTest|RecipeDecodeOptimizationTest|RecipeExecutor.*Test|RecipeCapabilityTest|RecipeTupleTest|RecipePackingTest|RecipeOptimizationTest|RecipeLendingTest|RecipeRecoveryTest|RecipeClaimsTest|LLExecutingTest|RecipeBuildTest|RecipeStagesTest|RecipeManifestBuildTest|RecipeManifestTest)$' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '^(RecipeReturnDataOptimizationTest|RecipeExecutorTest|RecipeCapabilityTest|RecipeTupleTest|RecipeLendingTest|RecipeRecoveryTest|RecipeClaimsTest|LLExecutingTest)$' --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
"$RECIPE_FORGE" build --offline
"$RECIPE_FORGE" fmt --check
git diff --check
python3 plans/recipe_plan_checks.py check 007 out/plan007/baseline
```

Expected: all scoped tests, build, formatting and dirty-scope checks pass. Snapshot emission is restricted to the groups allowed by this plan; do not regenerate unrelated JSON snapshot files. Format only modified in-scope files if a check fails. Check modified Markdown/JSON with pnpm dlx prettier@3.9.6 --check, naming the individual modified files; do not format the repository.

For the final integrated gate, mirror the repository hook with the pinned compiler and serial tests. Each command below must exit zero before running the next; do not extract a report from a failed test log.

```sh
"$RECIPE_FORGE" build --offline --sizes > snapshots/sizes.txt
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --no-match-contract '.*(Mainnet|Benchmark|Invariant).*' --gas-report --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0 > out/plan007/full-local.log 2>&1
sed -n '/^╭/,/^╰/p' out/plan007/full-local.log > snapshots/gas.txt
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false "$RECIPE_FORGE" test --offline --isolate --match-contract '.*Invariant.*' --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
git diff --check
python3 plans/recipe_plan_checks.py check 007 out/plan007/baseline
```

Expected: all runnable local and invariant tests pass. Four optional config/live skips existed in the preceding validation; record actual skips and investigate new ones. Serial execution avoids the known testnet TESTNET_MANIFEST fixture race. Aggregate gas/size reports describe the entire dirty checkout, including pre-existing unrelated work. Every saved recipe/guarded fixture must remain byte-identical to this plan's starting baseline.

Record commands, before/after gas, source/artifact changes and limitations in this plan and its index row. Local verification does not establish hosted CI, sibling Go/frontend compatibility, live wallet/chain behavior or deployment.

## Done criteria

- [x] Frozen same-context reference matches complete values/reverts/effects across the response, offset, conditional and cached matrix.
- [x] Full ReadCached/ReadWord behavior, upstream errors, no-code/precompile semantics and rollback are unchanged.
- [ ] All 21 measured labels are nonregressing; at least one representative production workload strictly improves.
- [x] Public ABIs, saved commitments/recipe bytes/runtime maps and authorization are unchanged.
- [x] Code-size, scoped/full-local/invariant/format/snapshot/scope gates pass.
- [ ] This plan and index record DONE, retained subpaths, evidence and limitations.

## STOP conditions and maintenance

Stop on unexplained O06/baseline drift, missing predecessor fixture, changed upstream helper semantics, loss of cached response bytes, changed error precedence or caller behavior, gas-forwarding changes, need to alter dependency/schema/Manage/approval code, two unsuccessful focused repairs or a failing gas gate. Do not reinterpret a semantic failure as a permissible optimization.

Future OpenZeppelin/compiler upgrades require rechecking exact error/copy behavior and rebenchmarking small responses. Never use a scalar copy for ReadCached, and never let an intervening call replace the returndata before copying. Local bytecode changes require separate deployment; the recipe wire format remains unchanged.

## Execution evidence and rejection

The combined selective scalar-read/ignored-call prototype passed 159 focused semantic tests and 281 unchanged production workload tests, but failed the 21-label gas gate. It also removed the upstream InsufficientBalance(uint256,uint256) error from both generated public ABIs. The original Address call path therefore remains. An independent scalar-only prototype inlined its single-use call validation, retained identical ABIs and passed the same semantic/workload suites, but also failed the gas gate. No runtime change is retained.

Measurements use Foundry 1.8.1, Solidity 0.8.37, via-IR, optimizer 200, Osaka, isolated snapshots, serial tests and fuzz seed 0. Both prototypes used the same frozen eight test sources and frozen legacy interpreter. The unchanged-source performance target was observed RED because no representative workload improved.

| Workload                                          |  Baseline |           Combined |        Scalar only |
| ------------------------------------------------- | --------: | -----------------: | -----------------: |
| RecipeLending/O04Sync                             |   781,661 |   780,414 (-1,247) |   779,925 (-1,736) |
| RecipeLending/O04Async                            |   788,391 |   787,144 (-1,247) |   786,655 (-1,736) |
| RecipeRecovery/recovery                           | 1,105,658 | 1,103,065 (-2,593) | 1,101,920 (-3,738) |
| RecipeRecovery/O01TwoActiveSources                | 1,124,516 | 1,121,926 (-2,590) | 1,120,780 (-3,736) |
| RecipeRecovery/O01TwoActiveClaims                 |   613,177 |   611,683 (-1,494) |   610,991 (-2,186) |
| RecipeClaims/claimRedemptionWithdrawalMintRewards |   514,494 |   513,399 (-1,095) |   512,920 (-1,574) |
| LLExecuting/O03LLPositiveMinimum                  |   868,316 |   867,148 (-1,168) |   866,632 (-1,684) |
| RecipeCapability/executeChecksAndBindings         |   154,861 |     154,654 (-207) |     154,635 (-226) |
| RecipeCapability/executeReadAndCheck              |    84,093 |       84,028 (-65) |      83,977 (-116) |
| RecipeCapability/executeEmpty                     |    57,766 |        57,766 (+0) |        57,766 (+0) |
| RecipeTuple/ordinaryTupleReads                    |    46,235 |      46,044 (-191) |      45,978 (-257) |
| RecipeTuple/cachedTupleReads                      |    43,059 |       43,045 (-14) |       43,071 (+12) |
| RecipeExecutor/executeCall                        |    81,257 |       81,174 (-83) |       81,269 (+12) |
| RecipeExecutor/executeRead                        |    38,024 |       37,929 (-95) |      37,896 (-128) |
| RecipeReturnData/scalar32                         |    32,667 |       32,711 (+44) |       32,678 (+11) |
| RecipeReturnData/tuple128                         |    34,816 |       34,842 (+26) |        34,809 (-7) |
| RecipeReturnData/ignoredCallEmpty                 |    81,667 |       81,641 (-26) |       81,751 (+84) |
| RecipeReturnData/ignoredCall32                    |    81,622 |       81,592 (-30) |       81,706 (+84) |
| RecipeReturnData/readIfSkipped                    |    26,230 |        26,230 (+0) |        26,230 (+0) |
| RecipeReturnData/callIfSkipped                    |    24,942 |       24,986 (+44) |       24,995 (+53) |
| RecipeReturnData/cached128                        |    37,153 |      37,333 (+180) |      37,328 (+175) |

The combined prototype regressed scalar32 (+44), tuple128 (+26), skipped CallIf (+44) and cached128 (+180). The scalar-only prototype regressed the representative cachedTupleReads (+12), scalar32 (+11), both ignored-call fixtures (+84), skipped CallIf (+53) and cached128 (+175). Neither meets the binding gate; thresholds and fixtures were unchanged. A calls-only candidate was not applied because removing the Address call helper already failed the exact ABI requirement.

Baseline deployed sizes were RecipeExecutor 7,234 bytes and RecipeCapability 2,618 bytes. Combined sizes were 7,324 (+90) and 2,714 (+96); scalar-only sizes were 7,316 (+82) and 2,698 (+80). All are below 24,576 bytes. These hypothetical deployment costs yield no retained savings because both prototypes are rejected. The production source is restored byte for byte to SHA-256 f6c8f8f3c7298213d1234dc021bf1233b3397d94f64abc584ef117a9ef8609a1.

Evidence in `out/plan007/` includes both variant sources, frozen reference/fixtures, all 21 before/variant/restored labels, ABI differences, deployed sizes, exact response/revert/effect comparisons and gas rejection logs. Tests cover raw responses/reverts through 8,192 bytes, no-code targets and identity precompiles, full-width and unaligned reads, checked offset overflow precedence, STATICCALL mutation rejection, skipped malformed metadata, full cached producer behavior and call rollback. The getter selector was corrected before fixture freeze after an initial test-only compile error; the original log is preserved. No hosted CI, live-chain, sibling compatibility or deployment verification is claimed.

Restored validation so far: all 419 scoped tests and all 281 unchanged workload tests pass; all 21 gas labels exactly equal baseline. Both restored public ABIs and deployed sizes equal baseline. All twelve generated outputs are byte-identical. Allowed-group snapshot emission passes 297 tests. Final full build and gas-report gates pass: 2,187 tests passed, zero failed, four existing optional skips. All 18 tests in invariant suites pass with no skips. Solidity formatting, scoped Prettier, whitespace, allowed snapshot emission, scope and exact generated-output gates pass.
