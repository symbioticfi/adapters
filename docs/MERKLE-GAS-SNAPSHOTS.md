# Merkle gas snapshots

Dedicated snapshots cover the scoped contracts' callable behavior and significant
execution paths. Tests use deterministic inputs and `default.isolate = true`.
The snapshot hook also passes `--isolate` explicitly.

Successful calls use `vm.snapshotGasLastCall` immediately after the measured call.
Expected reverts use `vm.startSnapshotGas` and `vm.stopSnapshotGas` around the call:
Foundry does not retain the reverted call as the last successful external frame.
These regions include caller-side call/return overhead, so compare each label
against its own baseline, not against a successful-frame measurement.

## Coverage

| Contract or library        | Metered behavior                                                                                                                                                                                              | Tests                                                                                                                                          |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| MerkleAdapter              | Capital/NAV reads, historical checkpoints, allocation and cancellation, zero/released deallocation, cash/NAV bounds, push/pull, empty/existing/new staging, covered/uncovered/restaged/loss-capped settlement | `MerkleAdapterGas.t.sol`, `MerkleAccount.t.sol`, `MerkleAccountMigration.t.sol`                                                                |
| MerkleAccount              | Management, root acceptance, capability installation/removal/listing/routing, digest signing, validation and revocation                                                                                       | `MerkleAccount.t.sol`, `MerkleAdapter.t.sol`, `MerkleAdapterCapabilities.t.sol`, `MerkleAdapterSignatures.t.sol`, `MerkleAccountHashing.t.sol` |
| CapabilitiesRegistry       | New/replacement/empty selector approvals and reads                                                                                                                                                            | `CapabilitiesRegistry.t.sol`                                                                                                                   |
| RootRegistry               | Publishing, replacing and clearing a root; unauthorized publication                                                                                                                                           | `RootRegistry.t.sol`                                                                                                                           |
| CREOracle / CREOracleBase  | Bootstrap, growth/loss, rejection and frozen delivery; reviewed/empty recovery; fresh/frozen/stale reads; limits, workflow changes and receiver interfaces                                                    | `oracle/CREOracleGas.t.sol`                                                                                                                    |
| CREWorkflowRegistry        | Owner linking, proposals, acceptance/rotation and failed acceptance                                                                                                                                           | `oracle/CREWorkflowRegistry.t.sol`, `oracle/CREWorkflowRegistryInitialization.t.sol`                                                           |
| RecipeExecutor / Recipes   | Configuration, empty/read/arithmetic/call execution, account management, bound runtime, zero gates, approval setup/reset/clear and failure rollback                                                           | `RecipeExecutor.t.sol`                                                                                                                         |
| RecipeCapability / Recipes | Self-call execution, computed bindings, checks, lending and unauthorized/failed execution                                                                                                                     | `RecipeCapability.t.sol`, `RecipeBorrow.t.sol`                                                                                                 |
| ThreeFPolicy               | Consumer/limit/yield configuration, remaining budget, same-period/rollover consumption and rejection                                                                                                          | `ThreeFPolicy.t.sol`                                                                                                                           |
| LiquidLaneConnector        | Oracle adoption/removal, quote and budget reads, configuration, plain/discount swaps, period rollover, nonce invalidation and failed swaps                                                                    | `LiquidLaneConnector.t.sol`, `LiquidLaneConnectorDiscount.t.sol`                                                                               |
| OracleRegistry             | Setting, replacing and clearing connector-specific oracle approvals                                                                                                                                           | `LiquidLaneConnector.t.sol`                                                                                                                    |
| AssetRateLimits            | Configuration, budget reads, consumption, exhaustion and rollover through a test harness; production consumers also metered above                                                                             | `AssetRateLimits.t.sol`                                                                                                                        |
| MerkleAdapterVerifier      | Short and multiword masked leaf hashing                                                                                                                                                                       | `MerkleVerifier.t.sol`                                                                                                                         |
| ImmutableFactory           | Executor/capability deployment, dynamic arguments, subsequent entities, constructor failures, malformed arguments and empty runtime rejection                                                                 | `common/ImmutableFactory.t.sol`                                                                                                                |

Test paths are under `test/adapters/merkle-adapter/` except
`test/adapters/MerkleAdapter.t.sol` and
`test/adapters/common/ImmutableFactory.t.sol`. Generated snapshot JSON files are
under `snapshots/`; their labels identify the measured paths. Trivial generated
scalar getters and unchanged inherited OpenZeppelin/core methods are not each
given duplicate benchmark tests. Factory rows include deployment costs; fixture
setup remains outside each measured frame. Excluded liquidity and health-factor helpers retain their
existing snapshots and are outside this inventory.

## Applied hot-path optimizations

The following changes were measured against the packed-recipe tree immediately
before this follow-up, using Foundry 1.8.1, Solidity 0.8.37, optimizer 200 and Osaka
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
unchanged by these four optimizations. The executor runtime shrinks by 157 bytes;
the adapter grows by 102 bytes, the connector shrinks by 2 bytes, and ThreeFPolicy
is unchanged. Recipe-hash mismatch rejection costs 21 gas more in the existing
snapshots. Successful connector swaps save 208 gas across plain, signed, repeated
and rollover cases.

The staged revision retains the original `AssetRateLimits.consume` storage-read
and write sequence. The earlier combined connector and rate-limit measurements
(398 gas per swap and 189–190 per policy consumption) describe the preceding
experiment; they do not describe the committed implementation.

The adapter returns early only after computing the payout. With positive released
liquidity, cash and raw NAV reads still run even for a zero requested amount.
Removing no-op writes allows an authorized direct EVM `STATICCALL` to succeed when
the payout is zero. Public delegator operations and its reverting delegatecall
simulation retain NAV validation. The released public test requests 100 of 400
released units and includes the automatic sweep of the remaining 300.

`MerkleAdapterHotPaths.t.sol` covers public deallocation, simulation and managed
push paths; `MerkleAdapterDeallocatable.t.sol` covers unavailable cash and invalid
NAV. Three sequence snapshots in `RecipeExecutor.t.sol` cover the operation cache.
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
from the current dedicated adapter snapshots.

## Reproduction

Use Foundry v1.8.1 and the repository's pinned compiler configuration. The
`forge-snapshots` pre-commit hook regenerates the per-call JSON files, aggregate
gas report and size report. To check dedicated snapshots without rewriting them:

```sh
FOUNDRY_PROFILE=snapshots forge test --isolate --no-match-contract '.*(Mainnet|Benchmark|Invariant).*' --threads 1 --fuzz-seed 0 --gas-snapshot-check true --gas-snapshot-emit false
```

The hook runs invariants separately. The audit manifest records the exact input
and snapshot hashes and the results for the final tree. Aggregate gas tables
include attempted reverted calls and do not replace the dedicated labels above.
