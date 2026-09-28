# MerkleAdapter NAV oracle

The oracle values the entire adapter portfolio at one finalized block: underlying
held by the adapter and its account, investment positions and pending claims,
minus external liabilities. Vault cash is outside that scope. Requests for cash
and transfers between the adapter, account and its positions do not change NAV.

The adapter records one signed cumulative capital-flow history:

```text
F = completed vault allocations - completed returns to the vault
currentAssets = report.totalAssets - F(report.snapshotBlock) + F(now)
```

The report does not supply flow counters. `netFlowAt(snapshotBlock)` reads the
adapter's latest checkpoint at or before the requested block. Current and future
block queries return the latest recorded flow; the oracle validates that reports
refer to completed blocks. Updates within one block share one checkpoint. Each
checkpoint packs a
`uint48` block number and signed `int208` flow into one slot; checked casts reject
values outside those ranges. Negative lifetime net flows are valid after profits
have been withdrawn. Arithmetic never silently clamps a negative NAV to zero.

A snapshot of 1,000 assets followed by a 150 return to the vault yields 850
adapter assets, whether the report arrives before or after that return. A later
snapshot after the withdrawal reports the remaining 850. Cash awaiting a
withdrawal is already inside this value and is never added a second time.

## Allocation and withdrawal

Allocations increase the capital ledger by the full received amount and become
usable immediately when they are not needed for withdrawals. They do not cancel
withdrawal requests or refund matching amounts. `requestDeallocate` overwrites the
delegator's cumulative outstanding demand without changing NAV or net flow.

Returned liquidity follows this sequence:

1. The delegator requests deallocation. The strategy unwinds positions into cash
   on the adapter, normally through account-authorized `pull(amount)` calls.
2. Cash backing the request is locked in one staged amount at its block number.
   `pull`, allocation and request updates stage automatically. Anyone can call
   `stageLiquidity()` after a direct protocol payout; the next request update,
   allocation or deallocation attempt also stages it.
3. CRE takes a finalized whole-portfolio snapshot at or after the staging block.
4. Anyone can call `syncReport()` to apply the accepted snapshot, releasing the
   covered staged amount and capping demand by current NAV. Allocation and
   deallocation also call it automatically.
   Report acceptance itself never writes adapter state.
5. The delegator can return the released cash to the vault in that same deallocation. Only this completed
   capital transfer decreases net flow and the outstanding request.

`stageLiquidity()` locks the smaller of cash not already released and demand not
already released. An existing stage's amount and block remain fixed: another
caller cannot reset its clock. Additional cash waits until that stage is released.
After synchronization, any remaining eligible cash is staged at the synchronization block and
needs a later report. Consequently later arrivals can wait one extra reporting
cycle. Report acceptance never requires the entire withdrawal to be liquid.

A pending request can shrink or disappear, but already staged or released cash
remains protected. `push(amount)` must leave at least
`max(pendingDeallocation, releasedLiquidity + stagedLiquidity)` on the adapter.
Only the paired account can call `push` and `pull` through approved actions.
These internal custody transfers neither change net flow nor recognize PnL.
A direct payout cannot be released using a snapshot taken before its staging.

`deallocate(amount)` synchronizes the latest accepted report and returns the
minimum of the requested amount, released liquidity and fresh flow-adjusted NAV.
Released and staged liquidity remain cash-backed, so the payout needs no additional
balance cap. If synchronization leaves no released liquidity, it returns
zero; the delegator still validates NAV before completing the attempt.
Deallocation debits release capacity and records the capital outflow before the
delegator takes the cash; the complete transaction commits or reverts together.
A computed zero payout does not change release balances or flow history.
Positive released liquidity requires a fresh NAV read, even when the
requested amount is zero. The delegator's reverting delegatecall simulation runs
this same deallocation path. Deallocation deliberately does not stage again while
outgoing cash is still physically present. Later request updates, allocations,
pulls, deallocation attempts or direct `stageLiquidity()` calls can stage genuinely remaining cash.

UniversalDelegator's permissionless sweep can collect released liquidity, but
cannot collect unreported staged cash or unrestricted new allocations. There are
no cutoff-based allocation batches or report buffer. Staging identifies the cash
that a report covers; the signed flow history independently reconciles all actual
vault transfers. Neither staged nor released amounts are added to NAV: they are
already part of the whole-portfolio valuation.

Oracle `latestSnapshot()` returns `(uint48 snapshotBlock, uint256 assets)` from the
accepted report, where `assets` is its raw snapshot NAV. It checks the accepted
timestamp against `MAX_REPORT_AGE` and reverts with
`IMerkleAdapterOracle.OracleStale` when the valuation is missing or stale. This
getter only reads oracle state and never calls the adapter. Adapter `totalAssets()`
computes `assets - netFlowAt(snapshotBlock) + netFlow()` using checked signed
arithmetic and relies on the oracle's report validation for the casts. Adapter
`allocatable()` returns `type(uint256).max` without reading NAV. The oracle's scalar `totalAssets()` getter
returns raw accepted NAV without checking expiry. Separate getters still expose
the accepted snapshot block, timestamp and maximum age.
UniversalDelegator validates NAV at the end of allocation and deallocation, so a
stale or invalid oracle valuation rolls back those operations. An invalid adapter NAV can
halt the whole vault because accrual sums every adapter's NAV. Approved account
management, including recovery of cash through `pull`, remains available. With
existing withdrawal demand, `pull` also stages the returned cash. The adapter's
request hook does not read NAV, but UniversalDelegator reads NAV before
`forceDeallocate` or calculating withdrawal requests. Those request paths require
a fresh valuation.

Collateral must be an exact-transfer ERC-20 without transfer fees, rebases or
transfer callbacks. The ledger records the delegator amount. Direct transfers of
managed assets to the vault bypass it and must not be used. External protocol
unbonding and redemption restrictions continue to determine when cash is available.

A fresh report covering returned cash recognizes exit losses before that cash is
released. This gate applies to the adapter's liquidity only. It does not stop
withdrawals funded by vault idle cash or new deposits against an older accepted
valuation. VaultV2 also issues deposit shares before the next NAV report, so new
deposits may capture earlier gains. Fair pricing across every vault entry and exit
requires coordination at the vault layer.

## Time fields and encoding

The report is `abi.encode(ICREOracle.Report)`: five ABI words, exactly 160 bytes.

| Field                      | Meaning                                                                      |
| -------------------------- | ---------------------------------------------------------------------------- |
| `uint256 chainId`          | Destination chain; prevents cross-chain replay                               |
| `address adapter`          | Portfolio being valued; must equal this oracle's adapter                     |
| `uint256 totalAssets`      | Whole portfolio value in vault-asset base units, net of external liabilities |
| `uint48 snapshotBlock`     | Completed finalized block used for valuation and flow lookup                 |
| `uint48 snapshotTimestamp` | Timestamp of the same snapshot, used for freshness                           |

There is no report nonce, oracle address, exclusion amount, version or block hash.
Strictly advancing snapshot blocks prevent replay. The reviewed CRE workflow
establishes canonical finality and the correspondence of valuation, block and
timestamp; the contract does not independently prove those facts. Signed asset
math rejects NAV outside its supported signed range. Oversized time fields and
other payload lengths revert. Report producers and event consumers must use this
ABI; prior seven/eight-word payloads are incompatible.

Accepted snapshots must have a strictly newer block and timestamp than the
previous accepted snapshot. Blocks must be completed and timestamps cannot be
in the future. The workflow chooses its reporting cadence; the contract imposes
no interval or one-report-per-epoch limit. Continue producing finalized snapshots
on the workflow's schedule while a rejected report awaits review.

`MAX_REPORT_AGE` is the single age bound for delivery, curator review and accepted
NAV reads through `latestSnapshot()`. Age is measured from the snapshot timestamp;
`age <= MAX_REPORT_AGE` is valid. This `uint48` constructor immutable must be
nonzero in the deployment script, which supplies no production default.
Choose the reporting schedule within this shared
freshness bound, allowing for chain finality, workflow execution and delivery.

## Workflow proposals and curator acceptance

Symbiotic owns the CRE organization and controls the non-upgradeable
`CREWorkflowRegistry` through its current owner address. The curator controls
`CREOracle` through its current owner address. These addresses can rotate
independently at any time using `transferOwnership`. Symbiotic's current address
proposes workflow code and configuration; the curator's current address approves
activation. Old addresses lose their respective authority immediately, including
over pending proposals. Pending proposals and active workflows survive rotation.

CRE links the registry contract address to Symbiotic's organization. That address
stays fixed when either owner rotates, so rotation requires no CRE relinking or
workflow re-registration. The registry pins a
Chainlink `WorkflowRegistry 2.0.0` address in `CHAINLINK_WORKFLOW_REGISTRY`.
Each `CREOracle` implementation pins its governance registry in `WORKFLOW_REGISTRY`.

Symbiotic links the registry to CRE with the owner-only `linkOwner`. Chainlink allows
one active link per owner and rejects reused proofs; failed linking can be retried.
Afterwards, workflow activation uses proposal and curator acceptance. Ownership remains standard
`Ownable`, and further Oracles can join through the same approval flow.

Symbiotic calls `registry.proposeWorkflow(oracle, id, params)`, where `params`
contains `donFamily`, `binaryUrl`, `configUrl` and `attributes`. The proposal stores
the exact ID in `proposedWorkflowId` and all fields in `proposedWorkflowParams`,
and emits them for review. A zero ID clears the stored proposal. Proposing leaves
the accepted workflow and Chainlink registration active.

The current `CREOracle.owner()` calls `registry.acceptWorkflow(oracle, id, params)`.
Acceptance compares the supplied nonzero ID and all registration fields with the
stored proposal and verifies the caller is the current oracle owner.
It atomically clears that proposal, upserts the ACTIVE workflow and records its ID
in `registry.workflowId(oracle)`. A registration failure preserves the old
registration, accepted ID and pending proposal. The receiver reads the accepted
ID from its pinned registry when authenticating each report.

Each registration is owned by the `CREWorkflowRegistry` contract. Its name is the
Oracle's lowercase, 0x-prefixed address and its tag is `default`. These distinct
names prevent Chainlink's replacement behavior from pausing another Oracle's
workflow. Chainlink stores the registration metadata; the wrapper stores each
Oracle's accepted workflow ID and full pending proposal.

Workflow acceptance preserves NAV, flow accounting, snapshots, limits and the
rejected report hash. A previously rejected report remains available for curator
review if it still matches the latest rejected hash, advances the active snapshot
and meets freshness and accounting checks. New deliveries carrying the old ID stop
being accepted immediately. Chainlink retains its upstream administration: its trusted signers
can authorize unlinking that deletes the owner's registrations. After an upstream
unlink the owner relinks with a fresh Chainlink proof and re-accepts workflows.
Acceptance tolerates registrations Chainlink has already deleted.
Normal acceptance directly upserts a fresh ID into the existing ACTIVE record on
the same DON. It does not delete the old record or recheck creation quotas, so a
quota reduction does not block ordinary rotation. Upsert cannot change the DON
or reactivate an existing paused record, and already registered IDs are rejected.
The wrapper exposes no deletion, pause or activation method. Creation quotas
remain controlled by Chainlink and are shared by this wrapper within each DON.

Upstream unlinking deletes every registration owned by the wrapper, but does not
clear Oracle state, the wrapper's accepted IDs or pending proposals. A migration
to a different governance registry requires an accepted workflow in that registry.
The receiver then reads its ID there and requires the new registry as workflow
owner, so reports from the old registry are rejected.

### Preparing on-chain registration

Use `deployment-registry: "onchain:ethereum-mainnet"`. The available Chainlink
registry is `0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5`, reporting
`WorkflowRegistry 2.0.0` when checked on 22 September 2026. This synchronous design
requires the registry, receiver and its adapter on the registry's chain. It does
not relay approval from an Oracle on another chain.

Set `workflow-owner-address` to the deployed `CREWorkflowRegistry`, and
`workflow-name` to the Oracle's lowercase, 0x-prefixed address. The provider links the wrapper
using its `linkOwner(expiry, proof, signature)` with a Chainlink-issued ownership
proof for that wrapper address. Linking is independent of curator acceptance;
after an upstream unlink, repeat it with a fresh proof. The current NAV workflow
does not consume CRE secrets. CLI artifact uploads use CRE organization
authentication and do not need an off-chain request authorization method on this
wrapper.

Prepare the reviewed artifacts and unsigned registration transaction:

```sh
cre workflow deploy nav --target production-settings --unsigned
```

Decode the Chainlink `upsertWorkflow` payload and use its ID, DON family, URLs and
attributes in the proposal. Check the target registry, workflow owner, canonical
name and `default` tag. The wrapper always registers ACTIVE. CLI v1.32.0 preserves
an existing PAUSED status in raw update calldata; this wrapper cannot reactivate
that record. The CLI skips unchanged-ID redeployments, and Chainlink rejects IDs
that remain registered. The provider proposes the prepared fields; the Oracle
owner reviews the artifacts and accepts through `CREWorkflowRegistry`.
Submitting the raw Chainlink transaction from the provider's wallet would use the
wrong workflow owner. The wrapper makes the actual registration call on acceptance.
The checked-in NAV workflow still has mock report submission; registration alone
does not establish a functioning NAV delivery path.

The CLI's [unsigned transaction flow](https://docs.chain.link/cre/guides/operations/using-multisig-wallets)
and Chainlink's [v2 registry source](https://github.com/smartcontractkit/chainlink-evm/blob/2a2b38e8b74479054db92ab911521d60278c3d78/contracts/cre/src/v2/WorkflowRegistry.sol)
describe the external registration API. No CRE deployment or wallet linking is
performed by the Solidity deployment script.

## Curator controls

Curator calls target CREOracle, which stores and checks its own enumerable roles.
Its initializer decodes the forwarder, the default admin, curator and limits role
holders, the movement limits and the dust tolerance from `ICREOracle.InitParams`. Nonzero holders receive their configured
roles; zero addresses leave those roles unassigned. The default admin can later
change grants through `oracle.grantRole` and `oracle.revokeRole`. The owner and
default admin do not implicitly hold operational roles. Account role grants and revocations do not affect CREOracle;
CREOracle role grants and revocations take effect immediately within that instance.

| CREOracle role       | Initial holder field     | CREOracle calls                                  |
| -------------------- | ------------------------ | ------------------------------------------------ |
| `ORACLE_GUARD_ROLE`  | `oracleGuardRoleHolder`  | `acceptReport(report)`                           |
| `ORACLE_LIMITS_ROLE` | `oracleLimitsRoleHolder` | `setOracleLimits(maxGrowth, maxLoss, tolerance)` |

`ORACLE_GUARD_ROLE` and `oracleGuardRoleHolder` retain their existing names and
authorize curator acceptance of the latest rejected report.

`uint32 maxOracleGrowth` and `uint32 maxOracleLoss` set the initial movement limits.
The public setter is `setOracleLimits(uint32, uint32, uint128)`;
`SetOracleLimits(uint32, uint32, uint128)` emits the updated limits and tolerance.
These limits are independent, per accepted report, and inclusive. Valid limits
are 0–100,000,000, scaled by `ORACLE_LIMIT_PRECISION = 100_000_000`: `100_000_000`
is 100%, `10_000_000` is 10%, and one unit is 0.000001%. A report passes when its
change is within `oracleTolerance` or its exact ratio to the reconciled baseline is
within the limit; the ratio comparison has no rounding loss. Zero forbids movement
in that direction beyond the tolerance. They do not bound cumulative drawdown or
annualized returns. Changing movement limits does not apply the rejected report,
clear its hash or refresh the accepted snapshot. Subsequent reports within the
updated limits can be accepted normally.

`oracleTolerance` is an absolute amount in vault-asset base units that is always
accepted. It lets a zero or tiny baseline pass dust, rounding residue and small
donations without curator review, and it is the only way a positive report can pass
a zero baseline. No constant fits every asset, so it is configured per oracle:
choose an amount negligible against one report's expected yield yet larger than the
measured rounding error of the portfolio. For a six-decimal USDC vault, 100 base
units (`0.0001 USDC`) is a conservative starting point when aggregate rounding is
below that amount. A larger operational allowance of 1,000 base units
(`0.001 USDC`) should be justified by measured valuation noise. These are sizing
examples, not contract defaults or equivalent values for other assets.

Choose `tolerance >= measured absolute rounding error`, while keeping
`reportsPerDay * tolerance` below the acceptable daily valuation-error budget.
At 24 accepted reports per day, the examples allow `0.0024` or `0.024 USDC` of
additional daily movement when the percentage allowance is smaller. Tolerance is
used instead of the percentage allowance when larger; the two are not added.
Neither threshold bounds cumulative drift, and donations above both thresholds
still require review. Zero disables the dust exception.

The comparison `delta <= floor(baseline * limit / 1e8)` is exactly equivalent to
`delta * 1e8 <= baseline * limit` for integer token amounts. The implementation
uses checked `baseline * limit / 1e8`. If the intermediate product exceeds
`uint256`, report delivery reverts without changing the accepted
snapshot. The absolute-tolerance check runs first and skips this multiplication
when the delta is small enough.

CREOracle's owner remains the authority for factory-approved implementation
migrations and workflow acceptance. Transferring CREOracle ownership changes who
can accept pending and future proposals immediately; account and adapter ownership
transfers do not. CREOracle ownership, CREOracle roles and account roles
are independent; transfer those separately when handing over the complete strategy.

## Report acceptance

`CREOracle` authenticates the forwarder and workflow, and owns
`setOracleLimits`, enumerable roles and packed limit state. Its `onReport` combines
authentication with NAV handling, including adapter binding, freshness,
accounting bounds and movement-limit checks. `ICREOracle` defines the receiver and
accepted-report API. The oracle enforces freshness in its `latestSnapshot()` tuple
getter; the adapter reconciles the raw report NAV with its own flow history.

`CREOracle` also requires the workflow owner at `metadata[42:62]` to equal its
immutable `WORKFLOW_REGISTRY`. After checking the metadata length, owner and
nonzero supplied ID, it compares the ID with `workflowId(address(this))` in that
registry. These fields are covered by the DON signatures checked
by the forwarder. A matching workflow ID under another owner is rejected before
NAV processing, without changing the active valuation or rejected hash. The production
metadata layout is `bytes32 workflowId`, `bytes10 workflowName`, `address workflowOwner`,
and `bytes2 reportId` (64 bytes total).

After destination and snapshot checks, movement limits compare:

```text
baseline = previous report.totalAssets
         - adapter.netFlowAt(previous report.snapshotBlock)
         + adapter.netFlowAt(report.snapshotBlock)
observed = report.totalAssets
```

Thus capital transfers do not masquerade as investment performance. During
delivery and curator review, the oracle reads adapter flow history and current
net flow to validate the historical baseline and resulting current NAV. Acceptance
stores the raw reported NAV and snapshot metadata. The oracle never calls the
adapter to settle liquidity, and its tuple getter makes no adapter calls.
Insufficient cash for the full request does not reject NAV.
The adapter calls public `syncReport()` at the start of allocation and deallocation,
releasing covered staged cash and capping released liquidity and outstanding demand
by current NAV before the operation changes capital flows. Anyone can also call
`syncReport()` directly.
`OnReport(Report report, bool isRejected)` contains the full five-field report and
rejection status. Both parameters are unindexed.
Accepted reports set `isRejected = false`; adapter `totalAssets()` may differ
because of later capital flows.

For an otherwise valid authenticated report outside the movement limits, the oracle
stores `keccak256(abi.encode(report))` in `rejectedReportHash` and emits `OnReport` with
`isRejected = true`, preserving accepted accounting. The last accepted NAV remains usable until expiry, subject to valid
flow reconciliation. Rejection does not refresh that NAV or release staged liquidity.
All other invalid reports revert instead, including malformed or unauthenticated
payloads, wrong destinations, expired or misordered snapshots, arithmetic overflow
or underflow, signed-range violations and invalid historical or current NAV. These
failures preserve the active valuation, rejected candidate and liquidity reserves.
The stored hash identifies the latest authenticated delivery rejected for deviation,
in delivery order. Subsequent reports within the movement limits can become active,
including after a limits update. Normal acceptance retains the rejected hash;
the associated report can only be reviewed if it still advances
the active snapshot. A nonzero hash alone does not mean its report is still eligible.
Successful forwarder delivery alone is not acceptance: monitor
`OnReport` with `isRejected = false` and advancing accepted snapshots.

## Synchronizing accepted reports

`syncReport()` and `stageLiquidity()` are public and permissionless. Allocation
and deallocation call `syncReport()` before changing capital flows. It reads the
accepted snapshot and, when that snapshot is new, validates fresh NAV, applies
its caps and emits `SyncReport`. `syncedSnapshotBlock()` identifies the last
applied snapshot. It then calls `stageLiquidity()` to lock any eligible cash.
The oracle only reads adapter flow history and never writes adapter state.

Repeating synchronization without a newer snapshot does not restore paid liquidity
or reapply report caps to a new request. Account pulls and direct `stageLiquidity()`
calls can stage cash against existing demand while NAV is stale. Request updates
also stage cash, but the production delegator's request paths require fresh NAV.
After a direct protocol payout, anyone can call `stageLiquidity()`; the next request
update, allocation or deallocation attempt also stages it. The cash requires a
subsequent covering report.

If multiple reports arrive between synchronization calls, the next call applies
only the latest accepted report; intermediate loss caps are not replayed.
Deallocation releases covered staged cash before bounding the payout by fresh
NAV and released liquidity. Allocation applies report caps before recording the new inflow.
Any synchronization failure rolls back the capital operation without undoing an
already accepted oracle report. NAV updates themselves do not wait for an adapter
operation.

## Recovery

An `ORACLE_GUARD_ROLE` holder can call `acceptReport(abi.encode(report))` with
the exact payload matching `rejectedReportHash`. Review bypasses movement limits,
accepts it, clears the hash and emits `AcceptReport(bytes report)` atomically.
The event contains the full encoded payload in an unindexed bytes parameter.
Its block and timestamp must be strictly newer than the active snapshot. Destination, freshness
and arithmetic constraints remain. The same snapshot-coverage rule controls
liquidity release when the adapter synchronizes the reviewed report. Failed review preserves all state. The curator
cannot invent an unreceived NAV or apply an expired or superseded snapshot.

`acceptReport` requires the full rejected payload; empty bytes are invalid.
Encode the rejected `OnReport` event's complete `report` struct with
`abi.encode(report)` and check its hash against `rejectedReportHash`. All five
report fields are included in the event.
Only successful curator acceptance clears the hash; another deviation rejection
replaces it. Workflow changes preserve the rejected candidate and do not refresh
an old valuation. Existing account
permissions, allowances and signed orders remain independently active.

## Bootstrap

1. Deploy `CREWorkflowRegistry(provider, chainlinkWorkflowRegistry)` and whitelist
   `CREOracle(factory, workflowRegistry, maxReportAge)`.
   Deploy and whitelist the account and adapter implementations.
2. Create the adapter with `IMerkleAdapter.InitParams`. Encode oracle settings as
   `ICREOracle.InitParams` and account settings as `IMerkleAccount.InitParams`.
   The adapter binds both child proxies to itself and creates their owners and
   initial roles. NAV is unavailable until an initial report is accepted.
3. Link the workflow registry to the CRE organization. The provider proposes the
   reviewed workflow ID and complete registration parameters; the oracle owner
   accepts through `CREWorkflowRegistry`.
4. Verify a finalized zero-NAV report is accepted, initial roles and limits match
   the intended configuration, and recovery works. Positive initial value above
   tolerance requires review; there is no unlimited first-report exception.
5. Configure approved account leaves, roles and capabilities before allocating.

## Integration boundary

The sibling `chainlink-nav` producer is explicitly excluded from the scoped
contract review and was not changed here. Inspection on 27 September 2026 still
found removed batch/nonce/cutoff reads, reserve-subtracting reconciliation and
`submission.NewMock`. The [audit handoff](MERKLE-AUDIT-HANDOFF.md) records the exact
source boundary and mandatory follow-up integration review.

That follow-up must demonstrate the five-field whole-portfolio report from the
actual producer against this receiver, then separately validate real CRE delivery
and deployed operation. The producer must not subtract withdrawal requests or
reserves, withhold reports for insufficient withdrawal liquidity, or wait for a
removed cutoff. Operators must stage direct protocol payouts before the snapshot
intended to release them. Contract tests, matching producer fixtures, pinned forks
and actual deployment evidence are separate gates; production validation remains open.
