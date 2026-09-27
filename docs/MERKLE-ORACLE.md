# MerkleAdapter NAV oracle

The oracle values the entire adapter portfolio at one finalized block: underlying
held by the adapter and its account, investment positions and pending claims,
minus external liabilities. Vault cash is outside that scope. Requests for cash
and transfers between the adapter, account and its positions do not change NAV.

The adapter records one signed cumulative capital-flow history:

```text
F = completed vault allocations - completed returns to the vault
valuationOffset = report.totalAssets - F(report.snapshotBlock)
currentAssets = valuationOffset + F(now)
```

The report does not supply flow counters. `netFlowAt(snapshotBlock)` reads the
adapter's own end-of-block checkpoint, and rejects the current block and future
blocks. Updates within one block share one checkpoint. Each checkpoint packs a
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
   `pull`, allocation and request updates stage automatically. A direct protocol
   payout into the adapter requires a permissionless `stageLiquidity()` call.
3. CRE takes a finalized whole-portfolio snapshot at or after the staging block.
   Report acceptance releases that staged amount, capped by current accounted NAV.
4. The delegator can then return released cash to the vault. Only this completed
   capital transfer decreases net flow and the outstanding request.

`stageLiquidity()` locks the smaller of cash not already released and demand not
already released. An existing stage's amount and block remain fixed: another
caller cannot reset its clock. Additional cash waits until that stage is released.
After acceptance, any remaining eligible cash is staged at the delivery block and
needs a later report. Consequently later arrivals can wait one extra reporting
cycle. Report acceptance never requires the entire withdrawal to be liquid.

A pending request can shrink or disappear, but already staged or released cash
remains protected. `push(amount)` must leave at least
`max(pendingDeallocation, releasedLiquidity + stagedLiquidity)` on the adapter.
Only the paired account can call `push` and `pull` through approved actions.
These internal custody transfers neither change net flow nor recognize PnL.
A direct payout cannot be released using a snapshot taken before its staging.

`deallocatable()` is the minimum of released liquidity, adapter cash and the raw
flow-adjusted NAV. When released liquidity is zero it returns zero without reading
cash or NAV, including when those reads would fail. The delegator still validates
NAV before completing a nonzero deallocation attempt. Deallocation debits release
capacity and records the capital outflow before the delegator takes the cash; the
complete transaction commits or reverts together. A computed zero payout returns
without writing unchanged balances or flow history. Positive released liquidity
still requires cash and raw NAV reads, even when the requested amount is zero.
An authorized direct EVM `STATICCALL` can therefore succeed for a zero payout;
the public delegator's stateful path and reverting delegatecall simulation retain
their existing validation. Deallocation deliberately does not stage again while
outgoing cash is still physically present. Later `stageLiquidity`, request/allocation/pull or
accepted-report calls can stage genuinely remaining cash.

UniversalDelegator's permissionless sweep can collect released liquidity, but
cannot collect unreported staged cash or unrestricted new allocations. There are
no cutoff-based allocation batches or report buffer. Staging identifies the cash
that a report covers; the signed flow history independently reconciles all actual
vault transfers. Neither staged nor released amounts are added to NAV: they are
already part of the whole-portfolio valuation.

The oracle's `totalAssets()` returns raw flow-adjusted NAV. `validate()` additionally
checks freeze and freshness; adapter `totalAssets()` and `allocatable()` use it.
UniversalDelegator validates NAV at the end of allocation and deallocation, so a
stale or frozen oracle still rolls back those operations. A frozen adapter can
halt the whole vault because accrual sums every adapter's NAV. Approved account
management, including recovery of cash into the adapter, remains available.

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

`REPORT_INTERVAL` permits at most one accepted snapshot in each Unix-aligned
interval. An accepted snapshot must fall in a later interval than the previous
one. The comparison uses snapshot time, not delivery or guard-review time.
Reviewing an old report therefore does not move a cutoff or consume a later
report's interval. A rejected report does not consume an interval. Missed slots
need no empty reports. The workflow should continue producing finalized snapshots
on its normal schedule during a freeze.

`MAX_REPORT_AGE` limits delivery age. `MAX_ORACLE_AGE` limits the age of accepted
NAV for validation and acceptance. These values and `REPORT_INTERVAL` are `uint48`
constructor immutables; the deployment script requires nonzero values. The
contracts provide no production timing defaults. Choose timings compatible with
chain finality and actual workflow execution and delivery.

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
stored proposal. It atomically clears that proposal, upserts the ACTIVE workflow
and updates the receiver's accepted ID.
A registration failure preserves the old registration and pending proposal. Only the
registry can call `CREOracle.setWorkflowId`; the receiver has no proposal,
acceptance role or curator-acceptance entry point.

Each registration is owned by the `CREWorkflowRegistry` contract. Its name is the
Oracle's lowercase, 0x-prefixed address and its tag is `default`. These distinct
names prevent Chainlink's replacement behavior from pausing another Oracle's
workflow. Chainlink stores the registration metadata; the Oracle stores its
accepted workflow ID. The wrapper stores the full pending proposal.

Acceptance preserves NAV, flow accounting, snapshots, limits and any freeze, and
clears the cached rejected report. Reports carrying the old ID stop being accepted
immediately. Chainlink retains its upstream administration: its trusted signers
can authorize unlinking that deletes the owner's registrations. After an upstream
unlink the owner relinks with a fresh Chainlink proof and re-accepts workflows.
Acceptance tolerates registrations Chainlink has already deleted.
Normal acceptance directly upserts a fresh ID into the existing ACTIVE record on
the same DON. It does not delete the old record or recheck creation quotas, so a
quota reduction does not block ordinary rotation. Upsert cannot change the DON
or reactivate an existing paused record, and already registered IDs are rejected.
The wrapper exposes no deletion, pause or activation method. Creation quotas
remain controlled by Chainlink and are shared by this wrapper within each DON.

Use `freezeOracle()` when NAV-dependent operations must stop. Freezing preserves
the upstream registration and accepted workflow ID; authenticated reports can
still update the cached rejected report. Upstream unlinking deletes every
registration owned by the wrapper, but does not clear Oracle state or pending
proposals. Accept the replacement workflow or freeze the Oracle during migration:
changing registries alone preserves the previously accepted ID but changes the
required workflow owner, so reports from the old registry are rejected.

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

Guard calls target CREOracle, which stores and checks its own enumerable roles.
Its initializer decodes the forwarder, the default admin, guard and limits role
holders, the movement limits and the dust tolerance from `ICREOracle.InitParams`. Nonzero holders receive their configured
roles; zero addresses leave those roles unassigned. The default admin can later
change grants through `oracle.grantRole` and `oracle.revokeRole`. The owner and
default admin do not implicitly hold operational roles. Account role grants and revocations do not affect CREOracle;
CREOracle role grants and revocations take effect immediately within that instance.

| CREOracle role       | Initial holder field     | CREOracle calls                                  |
| -------------------- | ------------------------ | ------------------------------------------------ |
| `ORACLE_GUARD_ROLE`  | `oracleGuardRoleHolder`  | `freezeOracle()`, `unfreezeOracle(report)`       |
| `ORACLE_LIMITS_ROLE` | `oracleLimitsRoleHolder` | `setOracleLimits(maxGrowth, maxLoss, tolerance)` |

`maxOracleGrowth` and `maxOracleLoss` set the initial movement limits.
These limits are independent, per accepted report, and inclusive. Valid limits
are 0–100,000,000, scaled by `ORACLE_LIMIT_PRECISION = 100_000_000`: `100_000_000`
is 100%, `10_000_000` is 10%, and one unit is 0.000001%. A report passes when its
change is within `oracleTolerance` or its exact ratio to the reconciled baseline is
within the limit; the ratio comparison has no rounding loss. Zero forbids movement
in that direction beyond the tolerance. They do not bound cumulative drawdown or
annualized returns. Changing movement limits does not clear a freeze or refresh the
accepted snapshot.

`oracleTolerance` is an absolute amount in vault-asset base units that is always
accepted. It lets a zero or tiny baseline pass dust, rounding residue and small
donations without a guard review, and it is the only way a positive report can pass
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
`uint256`, report delivery reverts without freezing or changing the accepted
snapshot. The absolute-tolerance check runs first and skips this multiplication
when the delta is small enough.

CREOracle's owner remains the authority for factory-approved implementation
migrations and workflow acceptance. Transferring CREOracle ownership changes who
can accept pending and future proposals immediately; account and adapter ownership
transfers do not. CREOracle ownership, CREOracle roles and account roles
are independent; transfer those separately when handing over the complete strategy.

## Report acceptance

`CREOracleBase` authenticates the forwarder and workflow, and owns
`setOracleLimits`, enumerable roles and packed limit state. CREOracle initializes
those fields directly and checks movement limits inside report acceptance, alongside
its adapter binding, freshness, guard role and NAV logic.

`CREOracle` also requires the workflow owner at `metadata[42:62]` to equal its
immutable `WORKFLOW_REGISTRY`. This field is covered by the DON signatures checked
by the forwarder. A matching workflow ID under another owner is rejected before
NAV processing, without freezing the oracle or caching the payload. The production
metadata layout is `bytes32 workflowId`, `bytes10 workflowName`, `address workflowOwner`,
and `bytes2 reportId` (64 bytes total).

After destination and snapshot checks, movement limits compare:

```text
baseline = previous valuationOffset + adapter.netFlowAt(snapshotBlock)
observed = report.totalAssets
```

Thus capital transfers do not masquerade as investment performance. Acceptance
stores `valuationOffset = observed - netFlowAt(snapshotBlock)` after verifying
that both the historical baseline and resulting current assets are valid signed
values. It then calls `adapter.settleReport(snapshotBlock, currentAssets)` to
release only staged liquidity covered by the accepted snapshot and cap released
liquidity to current NAV. Insufficient cash for the full request does not reject
NAV. Acceptance also caps outstanding demand to current NAV after losses.
`OnReport` contains the reported snapshot value and snapshot identifiers;
the live getter may differ because of later capital flows.

An authenticated movement or accounting rejection sets `oracleFrozen`, stores
`keccak256(report)` and emits `RejectReport`, preserving accepted accounting.
Malformed, unauthenticated, wrong-destination or stale reports revert instead.
An authenticated fresh report received while frozen may replace the cached
payload. Successful forwarder delivery alone is not acceptance: monitor
`OnReport`, `RejectReport` and advancing accepted snapshots.

## Recovery

An `ORACLE_GUARD_ROLE` holder can call `unfreezeOracle(abi.encode(report))` with
exactly the latest cached authenticated payload. Review accepts it and unfreezes
atomically, bypassing only movement limits. Destination, snapshot ordering,
cadence, freshness and arithmetic constraints remain. The same snapshot-coverage
rule controls liquidity release during review. Failed review preserves all state. The guard cannot invent an unreceived NAV. An expired cached report must
first be replaced by a fresh authenticated report.

`unfreezeOracle("")` clears the freeze and cache without changing NAV or snapshot
age. Workflow rotation and manual freezing also clear cached rejections. Neither
rotation nor empty unfreeze refreshes an old valuation. Existing account
permissions, allowances and signed orders remain independently active.

## Bootstrap

1. Deploy `CREWorkflowRegistry(provider, chainlinkWorkflowRegistry)` and whitelist
   `CREOracle(factory, workflowRegistry, maxReportAge, maxOracleAge, reportInterval)`.
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
