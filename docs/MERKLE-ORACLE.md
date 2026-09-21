# MerkleAdapter NAV oracle

Each adapter has its own Oracle proxy. Oracle authenticates CRE reports and owns
NAV validation, limits and freeze state. MerkleAdapter calls `oracle.validate()`
before NAV-dependent operations; it keeps the portfolio's allocation and withdrawal
accounting. Raw oracle getters remain readable during a freeze for inspection and
recovery.

The workflow reads `adapter.account()` and values account positions, account
underlying and adapter underlying at one snapshot. It subtracts reserves for the
next epoch's pending allocations and the current epoch's matured withdrawals.
The resulting signed NAV still includes withdrawals about to mature. Only the
adapter underlying balance may satisfy reserves. Transfers across this custody
boundary leave total NAV unchanged.

## Batch cutoffs

The Oracle implementation fixes `REPORT_INTERVAL` and `REPORT_BUFFER`, both in
seconds. The interval must be nonzero and the buffer smaller than the interval.
Each Oracle proxy tracks its own `cutoff()`. Allocations and withdrawal requests
enter `currentBatch` while `block.timestamp < cutoff`; at the cutoff and afterward
they enter `nextBatch`. Allocation matching and withdrawal
cancellation affect only that open batch. The closed batch cannot be changed by
subsequent vault operations while its report is being prepared or delivered.

A report settles `currentBatch`, adds its surviving withdrawal to `deallocatable`,
promotes `nextBatch` to `currentBatch`, and clears `nextBatch`. No later
synchronization is needed. Oracle advances its report nonce; the adapter stores
no historical epochs. The finalized snapshot must
have `snapshotTimestamp >= cutoff`. On acceptance, the next cutoff is computed
from the transaction timestamp:

```text
nextCutoff = now + REPORT_INTERVAL - (now + REPORT_BUFFER) % REPORT_INTERVAL
```

This is the first strictly future cutoff on the interval grid shifted earlier by
the buffer. For example only, with an interval of 60 seconds and a buffer of 10
seconds, cutoffs lie at timestamps 50, 110, 170, and so on. Acceptance at timestamp
110 schedules 170. These values illustrate the calculation, not production settings.

A delayed report still settles only the closed batch. Requests received after its
cutoff stay together in `nextBatch`; acceptance makes that batch current and
schedules its cutoff in the future. Missed wall-clock intervals do not cause
separate empty reports or consume those later requests. A rejected report keeps
both nonce and cutoff unchanged.
The future cutoff also ensures every subsequent snapshot timestamp is newer than
the previously accepted snapshot.

The initial cutoff is zero so an empty bootstrap report can establish the first
schedule before allocations are enabled. The buffer is a schedule offset, not an
onchain finality proof or an extra delivery-age allowance. The workflow must wait
for an eligible finalized snapshot, and surviving withdrawal assets must be
returned to the adapter before its report can be accepted. Configure the interval
and buffer for those operational requirements; the contracts supply no schedule
defaults or keeper.

## Workflow proposals and curator acceptance

The same implementation serves different adapters and curators:

```text
Provider (oracle-factory owner)   Curator (current account owner)
            |                                |
   oracleA.proposeWorkflow(idA)     oracleA.acceptWorkflow(idA)
   oracleB.proposeWorkflow(idB)     oracleB.acceptWorkflow(idB)
```

`proposeWorkflow(id)` saves a proposal only in the called Oracle. The current owner
of its `FACTORY` can replace the proposal or cancel it with zero. The accepted
workflow keeps running. `acceptWorkflow(id)` requires the bound account's current
owner and the exact, nonzero proposed ID, then consumes the proposal. If a proposal
changes while a curator's transaction is pending, acceptance of the old ID reverts.

Acceptance updates the stored `workflowId` without deploying or migrating a
contract. It preserves NAV, nonce, snapshots, limits and any freeze, and clears the
cached rejected-report hash. Reports from the previous workflow stop being
accepted immediately. Updating Oracle A changes neither Oracle B's proposal nor
its accepted workflow or accounting.

The workflow ID commits the compiled code, configuration and workflow owner. The
provider must present those exact artifacts for curator review. Calculate the ID
before deployment:

```sh
cre workflow hash nav --public_key 0xWORKFLOW_OWNER --target production-settings
```

### Chainlink registry

Oracle deliberately validates the accepted ID rather than following a mutable
"latest workflow" entry. Chainlink's public registry is on Ethereum mainnet, while
its private registry is offchain; neither is a universal synchronous dependency
for receivers on other chains. Registry metadata can be fetched offchain for
review and deployment checks. Automatically adopting its latest ID would bypass
curator acceptance of changed valuation code.

For independent adoption, deploy workflows with separate names/configurations per
adapter and version. Keep the previously accepted deployment active until its
curator switches. Redeploying under the same name replaces that deployment; doing
so before acceptance would stop usable reports from the old workflow.

## Curator controls

Guard calls target Oracle. Their permissions remain enumerable roles on the bound
account, administered by its `DEFAULT_ADMIN_ROLE`. The owner and default admin do
not implicitly hold them. Grants and revocations take effect immediately because
Oracle queries the account on each guarded call.

| Account role         | Oracle calls                                | Initial policy                |
| -------------------- | ------------------------------------------- | ----------------------------- |
| `ORACLE_GUARD_ROLE`  | `freezeOracle()`, `unfreezeOracle(report)`  | Unfrozen                      |
| `ORACLE_LIMITS_ROLE` | `setOracleLimits(maxGrowthBps, maxLossBps)` | 1,000 bps up / 1,000 bps down |
| `ORACLE_AGE_ROLE`    | `setMaxOracleAge(seconds)`                  | 1 day                         |

Movement limits are independent, per accepted report, and inclusive. Valid limits
are 0–10,000 bps; zero forbids movement in that direction. They do not bound
cumulative drawdown or annualized returns. The age limit must be nonzero. Changing
policy does not clear a freeze or refresh the accepted snapshot.

Oracle's owner remains the authority for factory-approved implementation
migrations. Transferring account ownership changes workflow acceptance authority
immediately, but does not transfer Oracle ownership or the account's role grants;
transfer those separately when handing over the complete strategy.

## Report acceptance

Oracle verifies the forwarder, accepted workflow, destination chain/oracle/adapter,
next nonce and advancing past-block snapshot at or after the stored cutoff. The
reviewed workflow establishes snapshot finality. `MAX_REPORT_AGE` is the immutable
report-delivery age bound; `maxOracleAge` is the curator's freshness policy for
report acceptance and subsequent NAV-dependent calls.

The movement guard and settlement use:

```text
baseline = acceptedOracleAssets + adapter.currentBatch.allocation
observed = report.totalAssets = oracleUpdate.preReleaseAssets
requested = adapter.currentBatch.deallocation
released = min(requested, observed)
storedOracleAssets = observed - released
nextReserves = adapter.nextBatch.allocation + adapter.deallocatable + released
```

Allocations entering NAV do not look like yield, and withdrawals becoming reserved
do not look like losses. Pending allocations still outside NAV cannot dilute the
percentage limit. Overflow in the stored baseline or reserves reverts. Oracle
checks snapshot freshness; its `settleReport(observed)` call asks the adapter to
check report NAV plus reserves and idle backing, reserve the withdrawal and rotate
the batches. The adapter returns the remaining NAV, or rejects without changing
any accounting. Oracle freezes on
either a movement failure or a settlement rejection.

A loss caps newly matured withdrawals to the authenticated surviving NAV, as
AppAdapter bounds withdrawal availability by surviving assets. Already matured
reserves and pending allocations retain full backing. Temporary illiquidity cannot
write down a withdrawal: if surviving assets have not been returned to the adapter,
the idle-reserve check still rejects the report. On acceptance, the adapter adds
the surviving withdrawal to `deallocatable` immediately. Rejected reports leave
withdrawal accounting unchanged.

For example, a 1,000-unit withdrawal with 400 units surviving releases 400 and
stores zero unreserved NAV. The 60% loss still needs direct curator review
under the default 10% policy, and the adapter must hold the 400 units. Stored
`totalAssets()` and `OnReport` expose NAV after this release; the signed report
exposes NAV before it.

The report remains seven ABI words, but its asset field now has this pre-release
meaning. Deploy or upgrade the adapter, Oracle and workflow together; a workflow
using the previous net-of-withdrawals meaning is incompatible. Review and accept
the matching workflow ID before resuming reports.

A guard rejection sets `oracleFrozen`, caches `keccak256(report)` in
`rejectedReportHash`, emits `RejectReport`, and returns
successfully without changing the accepted NAV, nonce, cutoff or snapshot. A
revert would undo the freeze. Monitor `OnReport` and the stored nonce; successful
forwarder delivery alone is not NAV acceptance. Malformed or unauthenticated
reports revert before reaching the guard and cannot freeze the oracle.
Manual freezing emits `FreezeOracle()`; report rejection uses only `RejectReport`.
An authenticated report received while frozen also replaces the cached hash after
the same destination, nonce and snapshot checks. `RejectReport` contains the
report fields needed to reconstruct its exact ABI-encoded payload.

While frozen, the adapter's `totalAssets`, `allocatable`, nonzero allocation,
deallocation and withdrawal-request paths revert through Oracle validation.
`manage` remains available under its existing proofs, roles and reserve
checks for recovery. Existing allowances and signature approvals are not revoked.

An expired accepted snapshot also makes NAV-dependent calls revert. That read
failure cannot persist a freeze; a fresh accepted report restores freshness. An
already latched freeze still requires `ORACLE_GUARD_ROLE`, including after a
workflow change.

## Recovery

For a verified report, reconstruct `abi.encode(IOracle.Report)` from its
`RejectReport` event and check that its hash equals `rejectedReportHash()`. Call
`unfreezeOracle(encodedReport)` as an `ORACLE_GUARD_ROLE` holder. The call settles
the report and unfreezes atomically, without a second CRE delivery. It bypasses
only the growth/loss limits: destination, nonce, cutoff, snapshot freshness,
overflow and reserve checks still apply. If any check fails, the call reverts and
preserves the freeze, cached hash and all accounting.

Only the latest cached authenticated report can be accepted this way. A newer
report received while frozen replaces it; an expired report must be replaced by
a fresh authenticated report before review. Successful acceptance, workflow
acceptance and manual `freezeOracle()` clear the cache. The curator cannot supply
an arbitrary NAV or approve a report that has not reached Oracle.

For an erroneous report, repair the source or propose and accept the corrected
workflow. `unfreezeOracle("")` clears the freeze and cache without accepting a
report or changing NAV, nonce, cutoff or snapshot age. NAV-dependent operations
resume only if the previously accepted snapshot remains fresh. A subsequent
authenticated report must satisfy the ordinary limits and use `oracle.nonce()+1`.

A top-level transaction revert rolls back all changes, including when a later
call in the same batch reverts.

## Bootstrap without migration

1. The provider whitelists
   `Oracle(factory, productionForwarder, maxReportAge, reportInterval, reportBuffer)` and
   `MerkleAccount(accountFactory, rootRegistry, capabilitiesRegistry)` in their factories.
2. Create the adapter. It creates the latest account version with
   `abi.encode(IMerkleAccount.InitParams({adapter: adapter, defaultAdminRoleHolder: admin}))`
   and its Oracle proxy with `abi.encode(adapter)`. Both are initially owned by the adapter owner.
   All three addresses now exist. The accepted workflow and snapshot start unset
   and cutoff is zero, so NAV-dependent adapter operations are unavailable.
3. Build the workflow configuration using these addresses; finalize the code,
   configuration and owner, calculate the ID, and present the artifacts for review.
4. The oracle-factory owner calls `oracle.proposeWorkflow(id)`. The account's
   current owner calls `oracle.acceptWorkflow(id)`.
5. Activate that exact workflow and verify the initial finalized zero-NAV report
   is accepted and schedules the first future cutoff. Grant the desired account
   roles, configure limits, and enable the strategy. A positive initial NAV requires explicit authenticated-report review;
   there is no unlimited first-report exception.

The existing Keystone forwarder can be discovered before workflow creation with
`cre workflow supported-chains --output json`. No temporary disabled implementation,
address prediction or workflow-specific migration is needed. The shared factory's
`lastVersion()` selects implementation code, not any adapter's workflow.

Sources checked 2026-09-20:
[Workflow hash](https://docs.chain.link/cre/reference/cli/workflow#cre-workflow-hash),
[Registry commands](https://docs.chain.link/cre/reference/cli/registry),
[Workflow updates](https://docs.chain.link/cre/guides/operations/updating-deployed-workflows),
[Consumer contracts](https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts),
[Forwarder directory](https://docs.chain.link/cre/guides/workflow/using-evm-client/forwarder-directory-go).

## Integration boundary

The local NAV repository is `chainlink-nav` (the project referred to as
`merkle-adapter-nav`). Its submission client remains an in-memory mock. Production
wiring still needs signed CRE report generation/delivery and must align its fixed
10% offchain deviation policy with Oracle's configured limits. Its reconciliation
uses the same cash-flow-adjusted baseline and pre-release NAV, but it does not yet
read the onchain policy. The producer currently withholds outliers before
delivery; direct curator review requires an authenticated report to reach Oracle
and populate `rejectedReportHash` first.
The NAV client reads the stored cutoff and report interval at its chosen block,
and valuation rejects snapshots before that cutoff. The current hourly CRE
workflow also checks that `REPORT_INTERVAL` is 3600 seconds before submission.
After a delayed delivery, it follows the stored nonce and cutoff rather than
inferring them from elapsed intervals. Keep the chosen snapshot finalized and
within both delivery and curator age limits while preparing the closed batch's
liquidity.

Tests exercise actual adapter/Oracle factories and signed delivery through the
vendored KeystoneForwarder, including independent curator approvals, workflow
replacement, guard failures, recovery and bootstrap. They do not claim a deployed
CRE workflow or live end-to-end NAV submission.
