# Merkle contract audit handoff

This handoff scopes the Solidity review and explicitly excludes the NAV producer. Recording that exclusion closes the documentation task; producer/receiver
integration and production validation still require the follow-up gates below.

## Reviewed inputs and scope

The [audit manifest](../snapshots/merkle-audit-manifest.json) identifies the scoped
contract/interface contents, compiler configuration, dependencies, toolchain and
regenerated snapshots by hash, with the corresponding check results. The working
tree contains tracked and untracked edits: its base `HEAD` alone does not identify
the reviewed contents. Freeze the complete manifest-bound tree for independent
review; later edits require refreshed identities and affected checks.

The implementation scope is these 16 files under `src/contracts/`:

```text
MerkleAdapter.sol
common/ImmutableFactory.sol
merkle-adapter/CapabilitiesRegistry.sol
merkle-adapter/MerkleAccount.sol
merkle-adapter/Recipes.sol
merkle-adapter/RootRegistry.sol
merkle-adapter/automations/RecipeExecutor.sol
merkle-adapter/automations/policies/ThreeFPolicy.sol
merkle-adapter/capabilities/RecipeCapability.sol
merkle-adapter/connectors/LiquidLaneConnector.sol
merkle-adapter/connectors/OracleRegistry.sol
merkle-adapter/libraries/AssetRateLimits.sol
merkle-adapter/libraries/MerkleAdapterVerifier.sol
merkle-adapter/oracle/CREOracle.sol
merkle-adapter/oracle/CREOracleBase.sol
merkle-adapter/oracle/CREWorkflowRegistry.sol
```

Related interfaces, tests, deployment tooling and dependencies provide context.
Liquidity helpers and health-factor implementations under `automations/liquidity`
and `automations/health-factors`, other adapter families, third-party protocols,
the sibling `chainlink-nav` producer and live operations are outside this scope.
This handoff does not establish production readiness or an independent audit signoff.

## Producer exclusion: observed incompatibilities

Read-only inspection on 27 September 2026 found the following in sibling
`../chainlink-nav` at `8d82f59fdfee561f88940c141c9ade81fea871db`.
Paths below are relative to that repository; its producer was not modified.

| Producer source                                   | Current behavior                                                                                                                       | Required integration change                                                                                     |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `internal/client/merkle/adapter.go:15,51`         | Reads adapter `currentBatch()`/`nextBatch()` and oracle `nonce()`/`cutoff()`.                                                          | Use the current adapter/oracle ABI; these four getters are removed.                                             |
| `internal/usecase/valuation/service.go:140`       | Rejects snapshots before the old cutoff.                                                                                               | Select a finalized snapshot satisfying current ordering, freshness and aligned-interval rules.                  |
| `internal/usecase/valuation/epoch.go:57-76`       | Subtracts pending allocations and deallocatable reserves, derives a post-release value, and requires enough idle cash for withdrawals. | Report whole-portfolio NAV without reserve subtraction or a full-withdrawal-liquidity gate.                     |
| `internal/usecase/valuation/epoch.go:25-30,84-95` | Applies a fixed 10% producer limit and withholds breached updates.                                                                     | Review delivery policy against oracle-configured limits, tolerance and authenticated rejection/review recovery. |
| `internal/workflow/workflow.go:64,71-74`          | Calls `submission.NewMock`; requires a 3,600-second oracle interval.                                                                   | Implement reviewed CRE report delivery and align scheduling with deployed timing/finality settings.             |
| `internal/client/submission/mock.go:20-32`        | Hashes JSON and returns a mock receipt with zero transactions sent.                                                                    | Encode the receiver payload and obtain actual acceptance evidence; a mock digest is not a submitted report.     |

The producer's discovery, claim valuation and completeness rules also require
their own review against the deployed strategy's actual holdings and liabilities.
This contract review does not certify them or treat a catalog as universal coverage.

## Receiver integration contract

The payload is `abi.encode(ICREOracle.Report)`, exactly 160 bytes, in this order:

```solidity
uint256 chainId;
address adapter;
uint256 totalAssets;
uint48 snapshotBlock;
uint48 snapshotTimestamp;
```

`totalAssets` values adapter cash, account cash, positions and claims, net of
external liabilities, in vault-asset base units at one completed finalized block.
It excludes vault cash. Pending withdrawals and staged/released reserves remain
inside this NAV. The receiver obtains capital flows from the adapter itself:

```text
valuationOffset = report.totalAssets - adapter.netFlowAt(report.snapshotBlock)
currentAssets = valuationOffset + adapter.netFlow()
```

The producer must not apply post-snapshot flows a second time. Internal custody
transfers do not change capital flow. Snapshot block and timestamp must advance;
at most one snapshot per Unix-aligned `REPORT_INTERVAL` is accepted, subject to
both age limits. There is no nonce, cutoff, excluded-reserve value or block hash
in the payload. See [encoding and time rules](MERKLE-ORACLE.md#time-fields-and-encoding).

Delivery must come from the configured forwarder. Its signed metadata is exactly
64 packed bytes: `bytes32 workflowId`, `bytes10 workflowName`,
`address workflowOwner`, `bytes2 reportId`. The ID must be the accepted nonzero
workflow, and the owner must equal `oracle.WORKFLOW_REGISTRY()`. DON signature
verification belongs to the forwarder. Successful delivery can emit `RejectReport`
and freeze rather than accept; require `OnReport` and advancing accepted state.

Liquidity follows request → return cash → stage → covering snapshot → acceptance
→ released cash → deallocation to the vault. `pull` stages automatically when
eligible; direct payouts need `stageLiquidity()` before the covering snapshot.
Partial funding does not block NAV acceptance. Later arrivals may need another
report. See [withdrawal accounting](MERKLE-ORACLE.md#allocation-and-withdrawal).

Trust assumptions include correct approved workflow valuation, canonical finality
and matching block/timestamp, complete strategy coverage, authenticated sources,
reviewed forwarder/DON configuration, and exact-transfer collateral without fees,
rebases or transfer callbacks. The receiver does not independently prove valuation
or finality. Provider/curator governance, oracle roles and installed capabilities remain trusted within their documented authority.

## Evidence boundaries and closure gates

| Evidence                              | Establishes                                                                                     | Does not establish                                          |
| ------------------------------------- | ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| Contract-only tests/invariants        | Receiver, flow, release and authority behavior under their fixtures.                            | Matching producer output or live CRE execution.             |
| Matching producer integration fixture | Actual producer ABI reads, valuation and encoded bytes consumed by the current receiver.        | Production DON, registry permissions or deployed operation. |
| Pinned fork tests                     | Compatibility at the recorded chain/block under stated fixtures and impersonations.             | Current permissions/liquidity or a live workflow.           |
| Actual deployment evidence            | The identified deployed artifacts/configuration execute and accept reports on the target chain. | Coverage beyond those artifacts and observed scenarios.     |

Before closing the follow-up integration review:

- [ ] Freeze both repository revisions/content hashes, producer configuration,
      supported holdings/liabilities, artifact hashes and the receiver ABI together.
- [ ] Replace removed reads and reserve/cutoff reconciliation; preserve fail-closed
      handling of incomplete valuation. Review producer movement-policy behavior so
      legitimate losses can reach authenticated on-chain rejection and guard review.
- [ ] Add a fixture using actual producer reads/encoding against the scoped adapter
      and oracle, then route its five-word payload through a signed forwarder fixture.
      Compare independently calculated whole-portfolio NAV and post-snapshot flows.
- [ ] Cover bootstrap, allocations, delayed snapshots, losses, partial funding,
      direct-payout staging, release/deallocation, replay/order/freshness failures,
      wrong workflow/owner/destination, workflow rotation, rejection and recovery.
      Check actual guard approval latency against replacement reports and age limits.
- [ ] Run the producer's `make verify` and relevant contract/integration checks;
      retain commands, results, skipped cases and immutable input identities.

Before production activation, separately verify deployed code, pairings, owners,
roles, forwarder/DON, workflow registration and timings; retain artifact hashes,
transaction receipts, accepted events and snapshot/NAV reads. Demonstrate an
actual CRE delivery and the staged-cash release/recovery path with the intended
authorities. Follow [deployment validation](MERKLE-DEPLOYMENT.md#verification-boundary).
These production checks remain open; local or fork success cannot close them.

## Reproducing gas and size evidence

The [dedicated gas snapshot inventory](MERKLE-GAS-SNAPSHOTS.md) maps the scoped
callable behavior to deterministic isolated tests, including how reverted calls
are measured. Public curator-exit tests in `MerkleCapitalFlow.t.sol` cover
`forceDeallocate`, account-managed returns, covering reports, queue settlement,
the residual-exit request and adapter removal.

The [`forge-snapshots` hook](../.pre-commit-config.yaml) uses these commands from
the repository root; the manifest records the results for the reviewed inputs:

The current tree includes dedicated gas paths, public curator-exit coverage,
the zero-release shortcut in `MerkleAdapter.deallocatable()`, packed recipe
encoding and the four measured hot-path optimizations below. Its PR-profile suite passed 1,481 tests with two skips; the dedicated
factory size-limit run passed both tests. Coverage of the 16 scoped implementations
is 494/494 lines, 93/93 functions and 112/112 branches. Coverage instrumentation is separate from
optimized gas and bytecode measurements and does not prove exhaustive behavior.
The regenerated gas snapshots passed a read-only reproduction check, including
a byte-identical aggregate report. Exact inputs and commands are in the manifest.

Recipe operands use the low 28 bytes of a uint256: one source byte and 27 bytes
for a literal or index. Inputs and results remain full uint256 values. Each binding
is one uint256, with a four-byte offset above the packed operand. Steps use one
operation byte followed by the ABI payload in `bytes[]`. Public selectors are
unchanged; rebuild recipes, masks and leaf commitments using the updated
[builders and schema](RECIPE-EXECUTOR.md#instruction-schema). Both recipe wrappers
compile without IR. The manifest records the encoding comparison and measured gas
and bytecode reductions.

The enum cleanup uses file-level `uint8` constants (`SRC_*` and `OP_*`) and names
the packed operand `srcAndValue`. Unknown source and operation bytes are rejected
explicitly. The later binding change reduces each binding from two words to one
and moves the source byte to bit 216. Old operands must be re-encoded even in recipes
without bindings: old source bytes in the highest four bytes are now ignored and
may be interpreted as literals rather than rejected.

The earlier binding-packing benchmarks saved 1,142 gas for one binding and 115,225 gas for 100
bindings, including outer calldata and its full-length mask. Source extraction adds
six gas per resolved operand; a 100-step recipe containing mostly additions costs
1,172 more gas in that comparison. These fixture-specific results are retained in
the manifest's historical encoding evidence.

The subsequent four optimizations cache the executor operation, return after a
computed zero deallocation payout, cache the push asset, and reuse authenticated
connector callers for swap transfers. The staged revision retains the original
rate-limit consumption implementation; its earlier gas comparison is historical.
They preserve the packed encoding, public ABIs and storage layouts. The zero-payout
return permits an authorized direct EVM `STATICCALL` to succeed without no-op
storage writes; cash/NAV reads with positive release and the public delegator's
validation remain intact. Runtime sizes are now 3,296 bytes for RecipeCapability,
8,413 for RecipeExecutor and 9,281 for MerkleAdapter. The
[gas comparison](MERKLE-GAS-SNAPSHOTS.md#applied-hot-path-optimizations) records both
savings and the 44-gas increase on a released public deallocation with its sweep.

```sh
set -euo pipefail
mkdir -p snapshots
forge build
forge build --sizes | tee snapshots/sizes.txt >/dev/null
FOUNDRY_PROFILE=snapshots forge test --isolate --no-match-contract ".*(Mainnet|Benchmark|Invariant).*" --gas-report --threads 1 --fuzz-seed 0 | sed -n "/^╭/,/^╰/p" | tee snapshots/gas.txt >/dev/null
FOUNDRY_PROFILE=snapshots forge test --isolate --match-contract ".*Invariant.*" --threads 1 --fuzz-seed 0
```

Retain full test output separately: `gas.txt` contains only extracted tables.
Mainnet/benchmark tests are excluded from this gas run; invariants run separately.
Gas tables also include attempted reverted calls: the `allowlistRequest` row comes
from the [absent-selector regression](../test/adapters/merkle-adapter/oracle/CREWorkflowRegistryInitialization.t.sol#L79),
not an exposed registry method. Check the ABI and test together before declaring
a row stale. Snapshot files and commands alone do not prove passing checks.
