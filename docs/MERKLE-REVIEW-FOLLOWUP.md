# Merkle review follow-up

This follow-up applies the requested changes to the current RecipeCapability
baseline. The attached review described an older GuardedCallsCapability tree;
its claims are reassessed below against the current code. No legacy deployment
or storage-compatibility requirement is assumed.

## Capital-flow accounting

The final design separates snapshot-covered liquidity release from one signed
capital-flow checkpoint history. Whole-portfolio NAV includes adapter cash, account
balances, positions and pending claims minus liabilities. The oracle stores raw
reported NAV in public `totalAssets`.
Its `latestSnapshot()` getter returns `(0, 0)` before the first accepted report, then
`(uint48 snapshotBlock, uint256 assets)` without calling the adapter. Adapter
`totalAssets()` computes `assets - netFlowAt(snapshotBlock) + netFlow()` with
checked signed arithmetic, reverting on overflow. Oracle
delivery and review still read adapter flows to validate deviation limits and NAV.
There is no elapsed-age bound for delivery, review or `latestSnapshot()`.
Only full vault allocations and completed returns change that counter.

Allocations are usable immediately and do not cancel requests. Withdrawal cash
must be staged before an accepted snapshot covers it. One immutable-in-place
staged amount/block is promoted to released liquidity when `syncReport()` applies
a covering accepted report; allocation and deallocation call it automatically,
and anyone can call it directly. Later cash can require one extra report. Pending
demand and staged/released cash protect the adapter balance from reinvestment. Anyone can call `stageLiquidity()` after a direct protocol payout;
the next request update, allocation or deallocation attempt also stages it. `pull`
stages automatically while demand exists. Both `pull` and `stageLiquidity()` remain
available without an accepted NAV and can stage cash against existing demand.
Creating or updating requests through the production delegator requires accepted NAV.
Only released liquidity can return to the vault, capped by current NAV. Released
and staged liquidity remain cash-backed.
There is no cutoff, report buffer, excluded-assets field or report nonce.
Accepted snapshot blocks and timestamps must strictly advance. Blocks must be
completed and timestamps cannot be in the future. The workflow chooses its cadence.

The report is now five ABI words: chain ID, adapter, whole-portfolio NAV, snapshot
block and snapshot timestamp. Contract-owned checkpoints reconcile intervening
capital transfers. A 1,000 snapshot followed by a 150 return yields 850, without
adding remaining cash again. The producer and event encoders require coordinated
updates; they were not changed in this repository. See [current oracle design](MERKLE-ORACLE.md).

## Oracle limits and receiver

`ORACLE_LIMIT_PRECISION` is `1e8`. Movement is accepted when either its absolute
delta is within `oracleTolerance` or its exact relative change is within the
growth/loss limit. These allowances are not added. Initialization, the limits
setter, its event and the deployment script all include the tolerance.

Multiplication on both sides does not solve zero-baseline rejection: any positive
delta still exceeds zero. The implementation uses the mathematically equivalent
`delta <= floor(baseline * limit / precision)` with checked `uint256`
multiplication. If the intermediate product overflows, report delivery reverts
without freezing or changing the accepted snapshot. The absolute allowance
addresses dust and is checked first, skipping multiplication when it applies.

There is no asset-independent optimal tolerance. For a six-decimal USDC vault,
100 base units (`0.0001 USDC`) is a conservative starting point if measured
aggregate rounding is smaller. A tolerance of 1,000 (`0.001 USDC`) permits ten
times more absolute movement. At 24 accepted reports per day those allowances
sum to `0.0024` and `0.024 USDC` when the percentage limit is smaller. These are
engineering sizing examples, not measurements of this strategy. Choose a value
above measured rounding and below the per-report valuation-error budget. The
deployment script requires an explicit `MERKLE_ORACLE_TOLERANCE`; zero disables
the exception. A sufficiently large donation can still require review, and
neither allowance limits cumulative drift.

`CREOracle` combines forwarder/workflow authentication, `setOracleLimits`, limit
state, enumerable role control and NAV handling. `ICREOracle` defines their API,
role identifiers and `ORACLE_LIMIT_PRECISION`. Factory initialization decodes
the flat `ICREOracle.InitParams` directly. Growth and loss limits use `uint32` in
the struct, `setOracleLimits` and `SetOracleLimits`; tolerance uses `uint128`.
It configures the adapter,
forwarder and admin/limits/curator role grants, and applies initial limits through
`_setOracleLimits`. It retains migrations and validates NAV movement in
`_acceptReport`. Report authentication reads the accepted workflow ID from
`CREWorkflowRegistry.workflowId(oracle)`.
Signature validation remains without an explicit zero-discount-signer check.

## Workflow rotation and rejected reports

The pinned [Chainlink WorkflowRegistry 2.0.0 source](https://github.com/smartcontractkit/chainlink-evm/blob/2a2b38e8b74479054db92ab911521d60278c3d78/contracts/cre/src/v2/WorkflowRegistry.sol)
confirms that unlinking deletes all of an owner's registrations. The wrapper now
allows relinking with a fresh signed proof. Normal rotation directly upserts a
fresh ID on the same DON, preserving its active quota slot even after quota
reductions. Existing paused records, DON changes and already registered IDs are
rejected upstream. The wrapper exposes proposal, acceptance and owner linking,
and stores accepted IDs in `workflowId(oracle)`. Acceptance verifies the current
oracle owner and exact proposal before registration. Registration failures preserve
the prior accepted ID and proposal. Per-DON quotas and CRE organization linking
remain Chainlink-controlled.

The NAV receiver also checks that the signed metadata's workflow owner equals its
immutable `WORKFLOW_REGISTRY`. A report with the accepted ID and another owner
reverts before changing NAV or the rejected report hash. After checking the
metadata length, owner and nonzero supplied ID, the receiver compares the ID with
the pinned registry's `workflowId(oracle)`.

Movement-limit rejection preserves the active valuation and leaves it usable until expiry,
subject to valid flow reconciliation. The oracle stores the latest rejected delivery's
hash and emits `OnReport(Report report, bool isRejected)` with the full five-field
report and `true`. Accepted reports use the same event with `false`; both parameters
are unindexed.
Later reports within limits can be accepted normally, including
after a limits update, without clearing that hash. Curator review through
`acceptReport(report)` requires the exact payload to be strictly newer
than the active snapshot. `ORACLE_GUARD_ROLE` grants this acceptance permission;
its existing identifier and `oracleGuardRoleHolder` initialization field remain.
Successful review emits `AcceptReport(bytes report)` with the full encoded payload
and clears the hash. Workflow changes
preserve the rejected candidate, which remains reviewable under the same checks.
Only successful review clears the hash; a later deviation rejection replaces it.
Empty report acceptance is invalid.
Other invalid reports, including arithmetic failures and invalid NAV,
revert without changing the active valuation, rejected candidate or liquidity reserves.
Acceptance and curator review use the same snapshot ordering checks.
The [earlier research](research/cre-schedule-registry/README.md)
is historical; its cutoff prototype is superseded. The sibling producer still
needs the new report ABI, whole-portfolio valuation and live submission wiring.
No off-chain workflow was deployed or changed.

## Permissions and documentation

- Liquid Lane docs impose no requirement to pin `recipient`, `discount.protocol`
  or fixed-swap `amountOut`. Discount signatures still bind the protocol signer;
  computed discount pricing and the fixed-swap upper price bound remain enforced.
- RecipeCapability already replaces GuardedCallsCapability and requires a self-call
  through authorized account management. Its external-call rejection tests pass.
- The recipe wrappers are named `RecipeExecutor` and `RecipeCapability` throughout
  contracts, interfaces, tooling, tests and docs. Management and approval payloads
  decode directly into local variables, without payload structs. Short scopes limit
  temporary variable lifetimes during management decoding; approval actions reuse
  their allocated array elements. Recipe encoding, authorization and atomic resets
  are unchanged.
- A masked field without a binding retains the caller's runtime value. A binding
  replaces it with a committed literal, input or earlier result. The docs and a
  runtime test demonstrate this distinction; binding every masked word is not a
  protocol requirement.
- Account fallback remains open to installed protocol callbacks. A universal
  self-call check would break them. Execution functions must self-gate, as
  RecipeCapability does; callback implementations must validate their protocol
  caller and active context. The trust boundary is now explicit in the docs.

The separate deposit-pricing finding remains at the vault layer and was outside
the requested contract changes.

## Verification

The counts below record the earlier implementation run. For the refreshed audit
inputs, snapshot hashes, commands and current check results, use the
[audit handoff](MERKLE-AUDIT-HANDOFF.md) and its linked manifest.

The release policy and recipe cleanup passed the full local suite: 1,419
tests passed, none failed and 69 were skipped. The capital-flow invariants also
passed 128 runs of 256 calls (32,768 calls per invariant), with no reverts.
Regressions cover delayed snapshots, partial funding, cancelled demand, direct
payouts, allocation refunds, NAV-validation rollback and losses before release.
The real vault/queue test applies a 20% loss before a half-share withdrawal: the
withdrawal and remaining shares each receive approximately 4,000 of the surviving
8,000, with the existing queue's one-wei rounding residue asserted separately.
Gas and contract-size snapshots were regenerated, and `pre-commit run --all-files`
passed on the final run.
RPC-dependent suites require a configured endpoint; local tests do not establish
deployed workflow operation.
