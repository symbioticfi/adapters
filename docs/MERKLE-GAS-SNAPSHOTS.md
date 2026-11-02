# Merkle gas snapshots

Dedicated snapshots cover the scoped contracts' callable behavior and significant
execution paths. Tests use deterministic inputs and `default.isolate = true`.
The snapshot hook also passes `--isolate` explicitly. The default build uses
`via_ir = true` globally with Solidity 0.8.37, optimizer 200, Osaka and bytecode
hash `none`; contracts, scripts, tests and imported dependencies share this
pipeline.

The hook runs deployment tests separately without aggregate gas tracing. Their
full-system fixtures retain large call traces but are not gas benchmarks. They
remain required checks; contract gas reports come from the other unit tests.

Successful calls use `vm.snapshotGasLastCall` immediately after the measured call.
Expected reverts use `vm.startSnapshotGas` and `vm.stopSnapshotGas` around the call:
Foundry does not retain the reverted call as the last successful external frame.
These regions include caller-side call/return overhead, so compare each label
against its own baseline, not against a successful-frame measurement.

## Coverage

| Contract or library        | Metered behavior                                                                                                                                                            | Tests                                                                                                                                          |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| MerkleAdapter              | Capital/NAV reads, historical checkpoints, immediate allocation, no-op requests, account pulls, zero/released deallocation and release/NAV bounds                           | `MerkleAdapterGas.t.sol`, `MerkleAdapterSyncReport.t.sol`, `MerkleAccount.t.sol`, `MerkleAccountMigration.t.sol`                               |
| MerkleAccount              | Management, root acceptance, capability installation/removal/listing/routing, digest signing, validation and revocation                                                     | `MerkleAccount.t.sol`, `MerkleAdapter.t.sol`, `MerkleAdapterCapabilities.t.sol`, `MerkleAdapterSignatures.t.sol`, `MerkleAccountHashing.t.sol` |
| CapabilitiesRegistry       | New/replacement/empty selector approvals and reads                                                                                                                          | `CapabilitiesRegistry.t.sol`                                                                                                                   |
| RootRegistry               | Publishing, replacing and clearing a root; unauthorized publication                                                                                                         | `RootRegistry.t.sol`                                                                                                                           |
| CREOracle                  | Bootstrap, growth/loss, deviation rejection and subsequent acceptance; exact-payload curator acceptance; limits and receiver interfaces                                     | `oracle/CREOracleGas.t.sol`                                                                                                                    |
| CREWorkflowRegistry        | Owner linking, proposals, acceptance/rotation and failed acceptance                                                                                                         | `oracle/CREWorkflowRegistry.t.sol`, `oracle/CREWorkflowRegistryInitialization.t.sol`                                                           |
| RecipeExecutor / Recipes   | Configuration, empty/read/arithmetic/call execution, account management, bound runtime, zero gates, approval setup/reset/clear and failure rollback                         | `RecipeExecutor.t.sol`                                                                                                                         |
| RecipeCapability / Recipes | Self-call execution, computed bindings, checks, lending and unauthorized/failed execution                                                                                   | `RecipeCapability.t.sol`, `RecipeBorrow.t.sol`                                                                                                 |
| ThreeFPolicy               | Account binding and limit/yield configuration, checked collateral-underlying resolution, remaining budget, request-validated same-period/rollover consumption and rejection | `ThreeFPolicy.t.sol`                                                                                                                           |
| LiquidLaneConnector        | Oracle adoption/removal, quote and budget reads, configuration, plain/discount swaps, period rollover, nonce invalidation and failed swaps                                  | `LiquidLaneConnector.t.sol`, `LiquidLaneConnectorDiscount.t.sol`                                                                               |
| OracleRegistry             | Setting, replacing and clearing connector-specific oracle approvals                                                                                                         | `LiquidLaneConnector.t.sol`                                                                                                                    |
| AssetRateLimits            | Configuration, budget reads, consumption, exhaustion and rollover through a test harness; production consumers also metered above                                           | `AssetRateLimits.t.sol`                                                                                                                        |
| ActionMasker               | Short and multiword masked leaf hashing                                                                                                                                     | `ActionMasker.t.sol`                                                                                                                           |
| ImmutableFactory           | Executor/capability deployment, dynamic arguments, subsequent entities, constructor failures, malformed arguments and empty runtime rejection                               | `common/ImmutableFactory.t.sol`                                                                                                                |

Test paths are under `test/adapters/merkle-adapter/` except
`test/adapters/MerkleAdapter.t.sol` and
`test/adapters/common/ImmutableFactory.t.sol`. Generated snapshot JSON files are
under `snapshots/`; their labels identify the measured paths. Trivial generated
scalar getters and unchanged inherited OpenZeppelin/core methods are not each
given duplicate benchmark tests. Factory rows include deployment costs; fixture
setup remains outside each measured frame. Excluded liquidity and health-factor helpers retain their
existing snapshots and are outside this inventory.

`ThreeFPolicy.consume` snapshots include the inlined factory/facility checks and
collateral-underlying resolution. The immutable `REQUESTS_FACTORY()` and `FACILITY()` getters are covered
by factory-creation assertions and aggregate gas output; they follow the scalar-getter
benchmark convention above. Recipe builders pass the request to `consume` and retain
the cash, principal and yield checks around minting. These costs belong to the
request-validating implementation; earlier policy measurements below remain historical.

Oracle `latestSnapshot()` returns `(0, 0)` before the first report, then calls the
oracle's `snapshotBlock()` and `totalAssets()` getters without adapter calls. Adapter
`totalAssets()` reconciles this tuple with historical and current net flow using checked
signed arithmetic. The tuple exposes the previous report during its acceptance block;
`reportBlock()` records acceptance immediately. Deallocation
synchronizes the accepted report first. A positive release then requires a NAV
read; the payout relies on released liquidity remaining cash-backed. A zero release returns without further reads. The historical comparisons below retain their original behavior
and measurements.

## Compiler comparison before adoption

A controlled comparison compiled the same minimally fixed recipe source with
and without IR, using Foundry 1.8.1, Solidity 0.8.37, optimizer 200, Osaka,
bytecode hash `none`, isolated calls and seed 0. All production and test
dependencies in the fixture were recompiled for the global comparison below.
These are measurements of that frozen comparison source, not the final simpler
IR implementation.

| Path                        |  Non-IR | Global viaIR |  Change |
| --------------------------- | ------: | -----------: | ------: |
| 16 dependent additions      |  89,100 |       79,555 |  -9,545 |
| 16 reads                    | 115,074 |      101,720 | -13,354 |
| Three approvals with resets | 200,048 |      198,028 |  -2,020 |
| Checks and bindings         | 113,486 |      108,270 |  -5,216 |
| Manage                      | 115,365 |      115,428 |     +63 |
| Manage with bound actions   | 236,436 |      236,835 |    +399 |
| Empty execution             |  29,474 |       29,517 |     +43 |
| Native epoch receipt        | 202,841 |      196,679 |  -6,162 |

Executor runtime in that comparison fell from 8,526 to 6,442 bytes. Both modes
passed 45 executor tests and a broader 93-test recipe check, with no failures or
skips. This was a targeted comparison, not a full repository run. A separate
control held every dependency and the test contract at identical non-IR bytecode:
16 additions still saved 9,545 gas, 16 reads saved 12,778, and Manage saved 518.
The global results therefore include changes in account, adapter, token and
fixture code. Revert-region measurements also include the caller's compiled code.

The later, simpler IR source keeps `_step`'s operation and payload locals and
separate Manage/Approve branches. It restores runtime consumption before the
Manage gate. That source compiled to 6,371 runtime bytes in the targeted check
and passed all 45 executor tests. Its source changes are separate from the
identical-source compiler comparison above. Full-tree results and current
measurements belong to the refreshed manifest and snapshots.

Raw compiler inputs, per-call results and logs are retained locally under
`report/recipe-viair-2026-09-27/` and
`report/recipe-stack-2026-09-27/global-via-ir/`. The latter records the global
fixture comparison; the former also records the executor-only control and
simpler-source check.

## Historical non-IR hot-path optimizations

The following historical changes were measured against the packed-recipe tree
immediately before the earlier hot-path follow-up, using Foundry 1.8.1, Solidity 0.8.37, optimizer 200 and Osaka
without IR. Values are isolated call-frame gas, excluding transaction intrinsic
gas and fixture setup. Each row compares identical fixtures and inputs.

| Change                            | Measured path                                                  |  Before |   After | Change |
| --------------------------------- | -------------------------------------------------------------- | ------: | ------: | -----: |
| Cache executor operation          | 16 dependent additions                                         |  90,908 |  85,996 | -4,912 |
| Cache executor operation          | 16 reads                                                       | 116,882 | 111,970 | -4,912 |
| Cache executor operation          | Three approvals, including allowance resets                    | 201,383 | 199,541 | -1,842 |
| Skip unchanged zero-payout writes | Public deallocation without released liquidity                 | 205,654 | 202,152 | -3,502 |
| Skip unchanged zero-payout writes | Public deallocation with released liquidity and trailing sweep | 268,576 | 268,620 |    +44 |
| Skip unchanged zero-payout writes | Public zero request with released-liquidity sweep              | 243,775 | 243,797 |    +22 |
| Skip unchanged zero-payout writes | Public simulation without released liquidity                   |  86,395 |  83,644 | -2,751 |
| Cache push asset                  | Account-managed push                                           | 110,393 | 108,884 | -1,509 |
| Cache push asset                  | Account-managed zero push                                      |  87,669 |  86,160 | -1,509 |
| Reuse authenticated sender        | Signed connector swap                                          | 175,865 | 175,657 |   -208 |

`Recipes._run` already cached the operation in this baseline; the additional cache
is in `RecipeExecutor._run`. Recipe encoding, public ABIs and storage layouts are
unchanged by those four optimizations. In that non-IR comparison the executor
runtime shrank by 157 bytes, the adapter grew by 102, the connector shrank by 2,
and ThreeFPolicy was unchanged. Recipe-hash mismatch rejection cost 21 gas more.
Successful connector swaps saved 208 gas across plain, signed, repeated and
rollover cases. These values predate the global IR switch and later executor
layout.

The implementation retains the original `AssetRateLimits.consume` storage-read
and write sequence. The earlier combined connector and rate-limit measurements
(398 gas per swap and 189–190 per policy consumption) describe the preceding
experiment; they do not describe the committed implementation.

In this historical comparison, the adapter returned early only after computing the payout.
With positive released liquidity, cash and raw NAV reads ran even for a zero requested amount.
Removing no-op writes allows an authorized direct EVM `STATICCALL` to succeed when
the payout is zero. Public delegator operations and its reverting delegatecall
simulation retain NAV validation. The released public test requests 100 of 400
released units and includes the automatic sweep of the remaining 300.

`MerkleAdapterHotPaths.t.sol` covers public deallocation and simulation;
`MerkleAdapterDeallocate.t.sol` covers independence from cash reads and invalid NAV. Three sequence snapshots in `RecipeExecutor.t.sol` cover the operation cache.
Existing connector and policy tests cover authentication, overflow, callbacks,
budget exhaustion and rollback. Gas ceilings used to demonstrate failing baseline
checks remain in local evidence; the connector/policy budget gates describe the
preceding combined experiment. Canonical tests use snapshots and behavior checks.

Token behavior and access order affect deployed costs. These local comparisons
are recorded in the audit manifest; raw before/after logs are under
`report/merkle-hotpath-implementation-2026-09-27/` when retaining local evidence.

## Earlier zero-release optimization

These historical measurements compare the cached zero-release shortcut with its preceding implementation,
under identical fixtures using Solidity 0.8.37, optimizer 200 and Osaka without IR.

| Measurement                                            |      Before |       After |      Change |
| ------------------------------------------------------ | ----------: | ----------: | ----------: |
| Isolated getter, zero released liquidity               |  38,350 gas |   7,324 gas | -31,026 gas |
| Isolated getter, nonzero released liquidity            |  38,350 gas |  38,381 gas |     +31 gas |
| Public delegator deallocation, zero released liquidity | 216,970 gas | 205,654 gas | -11,316 gas |
| Public delegator deallocation, released liquidity      | 268,514 gas | 268,576 gas |     +62 gas |
| Adapter runtime                                        | 9,157 bytes | 9,179 bytes |   +22 bytes |

The public-call comparison uses `MerkleCapitalFlowFixture` with real factory/proxy
initialization and the inherited `UniversalDelegator.deallocate` path. Its released
case requests 100 of 400 released units and includes the automatic sweep of the
remaining 300. Both variants use the same implementation address, storage and
factory immutables. These are isolated call-frame measurements; they exclude
transaction intrinsic gas and fixture setup. Token behavior and access order
affect deployed costs. The direct-getter comparison uses a separate cold fixture
with injected storage and no checkpoint history, so its absolute values differ
from dedicated adapter snapshots with different fixtures and compiler settings.

## Reproduction

Use Foundry v1.8.1 and the repository's pinned global IR configuration. The
`forge-snapshots` pre-commit hook regenerates the per-call JSON files, aggregate
gas report and size report. To check dedicated snapshots without rewriting them:

```sh
FOUNDRY_PROFILE=snapshots forge test --isolate --no-match-contract '.*(Mainnet|Benchmark|Invariant).*' --threads 1 --fuzz-seed 0 --gas-snapshot-check true --gas-snapshot-emit false
```

The hook runs invariants separately. The audit manifest records the exact input
and snapshot hashes and current results under `verification`; the earlier
comparisons above are retained under `historical_evidence`. The 28 September 2026
refresh regenerates the optimized size and gas reports and checks both the
dedicated JSON snapshots and byte-identical aggregate gas-table reproduction.
Raw logs are local Git-ignored artifacts under
`report/threef-policy-compact-2026-09-28/`, with hashes in the tracked manifest.
Aggregate gas tables include attempted reverted calls and do not replace the
dedicated labels above.
