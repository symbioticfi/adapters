# Merkle contract audit handoff

The coverage counts and manifest identities below describe the recorded audit checkpoint.
They have not been regenerated for the account-bound policy refactor.

This handoff scopes the Solidity review and explicitly excludes the NAV producer. Recording that exclusion closes the documentation task; producer/receiver
integration and production validation still require the follow-up gates below.

## Reviewed inputs and scope

The [audit manifest](../snapshots/merkle-audit-manifest.json) identifies the scoped
contract/interface contents, compiler configuration, dependencies, toolchain and
regenerated snapshots by hash, with the corresponding check results. Its input
digest covers the Git-indexed source, tests, scripts and listed configuration
files, including their working-tree changes; the base `HEAD` alone does not
identify those contents. Freeze the complete manifest-bound tree for independent
review; later edits require refreshed identities and affected checks.

The 28 September 2026 refresh records current checks under `verification` and
keeps earlier compiler, encoding and optimization evidence under
`historical_evidence`. Historical ABI comparisons, test counts and coverage totals
do not describe the current tree. The current scope contains 15 implementation
files and uses the global IR compiler configuration.

Raw logs and coverage outputs are retained locally under
`report/threef-policy-compact-2026-09-28/` and `coverage/merkle/`; those directories are
Git-ignored. The tracked manifest records their hashes, commands and results.
Include these local artifacts when sharing the audit bundle, or regenerate them
from the recorded commands. Coverage percentages refer to instrumented source
items, not exhaustive behavior or optimized-bytecode coverage.
The refreshed IR-minimum report records 451/464 lines (97.20%), 587/603 statements
(97.35%), 106/106 branches and 84/84 functions. The full local run passed 1,528 tests
with no failures and two skipped tests; mainnet and benchmark suites were excluded.
`ThreeFPolicy` itself records 35/35 lines, 42/42 statements, 9/9 branches and 8/8 functions.
The checked historical-baseline conversion is covered during delivery and curator
review, including rollback of accepted state, the rejected candidate and reserves.

`ThreeFPolicy.consume(request, assets, yieldAssets)` owns request validation and
resolves the funding token and collateral underlying at execution time. The
implementation pins the trusted factory and facility, validates the named intent's
request binding and position-manager target, then charges the explicitly enabled
pair. New auction requests share usage for the same pair; different funding tokens
have independent limits and share each collateral underlying's minimum yield. The guarded leaf uses one request
input for validation, authorization, approvals, minting and balance checks. Its
funding token, collateral underlying, policy and checks remain pinned. It checks
that the pinned pair's remaining budget decreases by exactly the principal, so
retargeting to a different enabled underlying reverts atomically. Regenerate
existing guarded leaves to apply this check; the policy ABI is unchanged. No
standalone variable-spender
approval permission is required. Compatible migrations preserve account binding
and pair usage. Existing single-key policy configurations and recipes must be
regenerated; old usage requires explicit reconciliation. See [3F deployment](MERKLE-DEPLOYMENT.md) and
[recipe configuration](RECIPE-EXECUTOR.md#3f).

The remaining 13 zero line counters and 16 zero statement counters are retained in
the raw report. Each has an exact no-anchor diagnostic and passing tests that assert
its effects, recorded in `diagnostics/mapping-evidence.json`. Supplemental non-IR runs use unchanged
production sources and existing tests to check assembly source mappings; their
commands, input identities and raw results are retained under `diagnostics/`.
Those runs record positive hits for all 13 additional lines. The separately recorded
source-line union is 464/464 (100%); it requires identical source hashes and line
item sets across compiler modes. This combines observations from multiple compiler
modes and does not mean that one build measured 100% line coverage. The adapter's
internal calls to `_stageLiquidity()` and `syncReport()` are measured in the non-IR
run, and their effects remain asserted in the canonical tests.
A separate statement union is 603/603 (100%), matching all 16 canonical misses to
positive non-IR `Statement` counters by source hash and exact byte range. This uses
the debug statement reports, not an inference from LCOV line hits. The two union
records are `diagnostics/line-union.json` and `diagnostics/statement-union.json`.
These measurements do not alter the global IR release configuration or overwrite
the canonical coverage report. Compiler coverage alone does not establish exhaustive
behavior or an independent audit signoff.

The implementation scope is these 15 files under `src/contracts/`:

```text
MerkleAdapter.sol
common/ImmutableFactory.sol
merkle-adapter/CapabilitiesRegistry.sol
merkle-adapter/MerkleAccount.sol
merkle-adapter/Recipes.sol
merkle-adapter/RootRegistry.sol
merkle-adapter/automations/RecipeExecutor.sol
merkle-adapter/capabilities/policies/ThreeFPolicy.sol
merkle-adapter/capabilities/RecipeCapability.sol
merkle-adapter/connectors/LiquidLaneConnector.sol
merkle-adapter/connectors/OracleRegistry.sol
merkle-adapter/libraries/AssetRateLimits.sol
merkle-adapter/libraries/ActionMasker.sol
merkle-adapter/oracle/CREOracle.sol
merkle-adapter/oracle/CREWorkflowRegistry.sol
```

The masking library is now `ActionMasker`; the September manifest retains its
original `MerkleAdapterVerifier` name and source hashes.

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
| `internal/usecase/valuation/service.go:140`       | Rejects snapshots before the old cutoff.                                                                                               | Select a finalized snapshot satisfying current ordering and freshness rules.                                    |
| `internal/usecase/valuation/epoch.go:57-76`       | Subtracts pending allocations and deallocatable reserves, derives a post-release value, and requires enough idle cash for withdrawals. | Report whole-portfolio NAV without reserve subtraction or a full-withdrawal-liquidity gate.                     |
| `internal/usecase/valuation/epoch.go:25-30,84-95` | Applies a fixed 10% producer limit and withholds breached updates.                                                                     | Review delivery policy against oracle-configured limits, tolerance and authenticated rejection/review recovery. |
| `internal/workflow/workflow.go:64,71-74`          | Calls `submission.NewMock`; requires a 3,600-second oracle interval.                                                                   | Implement reviewed CRE delivery, remove the oracle-interval requirement and choose a reporting cadence.         |
| `internal/client/submission/mock.go:20-32`        | Hashes JSON and returns a mock receipt with zero transactions sent.                                                                    | Encode the receiver payload and obtain actual acceptance evidence; a mock digest is not a submitted report.     |

The producer's discovery, claim valuation and completeness rules also require
their own review against the deployed strategy's actual holdings and liabilities.
This contract review does not certify them or treat a catalog as universal coverage.

## Receiver integration contract

The payload is `abi.encode(ICREOracle.Report)`, exactly 128 bytes, in this order:

```solidity
uint256 chainId;
address adapter;
uint256 totalAssets;
uint48 snapshotBlock;
```

`totalAssets` values adapter cash, account cash, positions and claims, net of
external liabilities, in vault-asset base units at one completed finalized block.
It excludes vault cash. Pending withdrawals and staged/released reserves remain
inside this NAV. The receiver obtains capital flows from the adapter itself:

```text
currentAssets = report.totalAssets
              - adapter.netFlowAt(report.snapshotBlock)
              + adapter.netFlow()
```

The oracle stores raw reported NAV and accepted snapshot metadata. Its
`latestSnapshot()` returns `(uint48 snapshotBlock, uint256 assets)`, or `(0, 0)`
before the first report, without calling the adapter. Adapter
`totalAssets()` reconciles that tuple with its historical and current net flow
using checked signed arithmetic. During delivery and review, the oracle still
reads adapter flows to validate deviation limits and current NAV. Its scalar
`totalAssets()` getter exposes raw accepted NAV.

The producer must not apply post-snapshot flows a second time. Internal custody
transfers do not change capital flow. Accepted snapshot blocks must
strictly advance and be completed.
Reporting cadence is a workflow choice. There is no nonce, cutoff, excluded-reserve value or block hash
in the payload. See [encoding and time rules](MERKLE-ORACLE.md#time-fields-and-encoding).

Delivery must come from the configured forwarder. Its signed metadata is exactly
64 packed bytes: `bytes32 workflowId`, `bytes10 workflowName`,
`address workflowOwner`, `bytes2 reportId`. The ID must be nonzero and match
`registry.workflowId(oracle)` in the pinned `oracle.WORKFLOW_REGISTRY()`; the
workflow owner must equal that registry. DON signature
verification belongs to the forwarder. A movement-limit deviation emits `OnReport`
with `isRejected = true` without accepting it or refreshing the active valuation;
require `OnReport` with `isRejected = false` and
advancing accepted state. Rejection leaves the last accepted NAV usable,
subject to valid flow reconciliation. Later reports within limits may become active while the
latest rejected hash remains available for review against the new active snapshot.
Workflow changes also preserve that candidate; review still requires the exact
latest rejected payload to be newer than the active snapshot and otherwise valid.
Other invalid reports revert, preserving the active valuation, rejected candidate
and liquidity reserves.

Liquidity follows request → return cash → stage → covering snapshot → acceptance
→ synchronization → released cash → deallocation to the vault.
Anyone can call `syncReport()`. Allocation and deallocation
synchronize before changing capital flows. `pull` and request updates stage cash
automatically; direct payouts can be staged explicitly or by the next request update
or capital-operation attempt before the covering snapshot.
Without accepted NAV, `pull` can recover and stage cash against existing demand;
the production delegator's request paths require accepted NAV.
The oracle only reads adapter flow history and never writes adapter state.
If multiple reports arrive between synchronization calls, the next call applies the
latest report and current NAV without replaying intermediate caps. Partial funding
does not block NAV acceptance. Later arrivals may need another
report. See [withdrawal accounting](MERKLE-ORACLE.md#allocation-and-withdrawal).

Trust assumptions include correct approved workflow valuation, canonical finality
and matching valuation block, complete strategy coverage, authenticated sources,
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
      legitimate losses can reach authenticated on-chain rejection and curator review.
- [ ] Add a fixture using actual producer reads/encoding against the scoped adapter
      and oracle, then route its four-word payload through a signed forwarder fixture.
      Compare independently calculated whole-portfolio NAV and post-snapshot flows.
- [ ] Cover bootstrap, allocations, delayed snapshots, losses, partial funding,
      direct-payout staging, release/deallocation, replay/order/freshness failures,
      wrong workflow/owner/destination, workflow rotation, rejection and recovery.
      Check actual curator approval latency against replacement reports.
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

The default build uses the IR pipeline (`via_ir = true`) for contracts, tests and
scripts, including Chainlink dependencies. Solidity remains pinned to 0.8.37 with
optimizer 200, Osaka and bytecode hash `none`. The current recipe implementation
uses `_step` to retain the operation and its calldata payload, with separate
Manage and Approve branches. Manage consumes and bounds-checks its runtime entry
before decoding or evaluating the gate. A zero gate skips action decoding and
execution, while still consuming that entry.

The manifest records completed checks for its identified inputs. Earlier non-IR
test counts, coverage totals and snapshot checks remain historical evidence;
compiler or source changes require fresh runs. Coverage instrumentation is
separate from optimized gas and bytecode measurements and does not prove
exhaustive behavior. Use `forge coverage --ir-minimum` with the manifest's test
filters; Foundry warns that this mode can produce inaccurate source mappings.
The [compiler comparison](MERKLE-GAS-SNAPSHOTS.md#compiler-comparison-before-adoption)
distinguishes an identical-source pipeline comparison from the simpler recipe
source now used with IR.

Recipe operands use the low 28 bytes of a uint256: one source byte and 27 bytes
for a literal or index. Inputs and results remain full uint256 values. Each binding
is one uint256, with a four-byte offset above the packed operand. Steps use one
operation byte followed by the ABI payload in `bytes[]`. Public selectors are
unchanged; rebuild recipes, masks and leaf commitments using the updated
[builders and schema](RECIPE-EXECUTOR.md#instruction-schema). Both recipe wrappers
use the global IR configuration. The manifest retains the historical encoding
comparisons separately from current compiler and source identities.

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

The earlier non-IR comparison measured caching the executor operation, returning
after a computed zero deallocation payout, caching the push asset and reusing
authenticated connector callers for swap transfers. Its ABI and storage-layout
comparisons apply only to that historical change. The rate-limit comparison is
also historical. That version's zero-payout return permitted an authorized direct
EVM `STATICCALL` without no-op storage writes and retained cash/NAV reads with
positive release. The current payout synchronizes accepted reports and omits the
redundant cash cap, while retaining NAV validation.
The [historical non-IR comparison](MERKLE-GAS-SNAPSHOTS.md#historical-non-ir-hot-path-optimizations)
records their earlier savings and tradeoffs. Its gas and runtime values do not
represent the current IR build; use regenerated snapshots and the matching
manifest for that revision.

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
