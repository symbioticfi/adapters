# MerkleAdapter NAV oracle

Each adapter has its own CREOracle proxy. CREOracle authenticates CRE reports and owns
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

VaultV2 issues deposit shares immediately using the last accepted NAV. A depositor
entering before an upward report can therefore participate in gains earned before
entry. Batch cutoffs keep allocation accounting consistent, but do not defer share
issuance. Fair entry pricing for delayed valuations requires coordination at the
vault's deposit layer, such as queued settlement or an exclusive deposit gateway;
`adapter.allocate(amount)` receives neither the depositor nor the issued shares.

## Batch cutoffs

The CREOracle implementation fixes `REPORT_INTERVAL` and `REPORT_BUFFER`, both in
seconds. The interval must be nonzero and the buffer smaller than the interval.
Each CREOracle proxy tracks its own `cutoff()`. Allocations and withdrawal requests
enter `currentBatch` while `block.timestamp < cutoff`; at the cutoff and afterward
they enter `nextBatch`. Allocation matching and withdrawal
cancellation affect only that open batch. The closed batch cannot be changed by
subsequent vault operations while its report is being prepared or delivered.

A report settles `currentBatch`, adds its surviving withdrawal to `deallocatable`,
promotes `nextBatch` to `currentBatch`, and clears `nextBatch`. No later
synchronization is needed. CREOracle advances its report nonce; the adapter stores
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

Symbiotic links the registry to CRE once with `linkOwner`. A successful link sets
`initialized` permanently; failed linking can be retried. Afterwards, workflow
changes use only proposal and curator acceptance. Ownership remains standard
`Ownable`, and further Oracles can join through the same approval flow.

Symbiotic calls `registry.proposeWorkflow(oracle, id, params)`, where `params`
contains `donFamily`, `binaryUrl`, `configUrl` and `attributes`. The proposal stores
one hash, `keccak256(abi.encode(id, params))`, and emits the ID and fields for review. A zero ID
cancels it. Proposing leaves the accepted workflow and Chainlink registration active.

The current `CREOracle.owner()` calls `registry.acceptWorkflow(oracle, id, params)`.
Acceptance requires the proposed nonzero ID and unchanged registration data. It
atomically deletes the previous Chainlink registration, registers the new ACTIVE
workflow, and updates the receiver's accepted ID. A registration failure rolls
back the entire transaction, including deletion of the previous workflow. Only the
registry can call `CREOracle.setWorkflowId`; the receiver has no proposal,
acceptance role or curator-acceptance entry point.

Each registration is owned by the `CREWorkflowRegistry` contract. Its name is the
Oracle's lowercase, 0x-prefixed address and its tag is `default`. These distinct
names prevent Chainlink's replacement behavior from pausing another Oracle's
workflow. The wrapper tracks its own registered IDs rather than trusting a
migratable receiver's claim about its previous registration.

Acceptance preserves NAV, nonce, snapshots, cutoff, limits and any freeze, and
clears the cached rejected report. Reports carrying the old ID stop being accepted
immediately. Chainlink retains its upstream administration: its trusted signers
can authorize unlinking that deletes the owner's registrations. An upstream unlink
cannot reset `initialized` or enable relinking through this wrapper; recovery then
requires a new registry.

### Preparing on-chain registration

Use `deployment-registry: "onchain:ethereum-mainnet"`. The available Chainlink
registry is `0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5`, reporting
`WorkflowRegistry 2.0.0` when checked on 22 September 2026. This synchronous design
requires the registry, receiver and its adapter on the registry's chain. It does
not relay approval from an Oracle on another chain.

Set `workflow-owner-address` to the deployed `CREWorkflowRegistry`, and
`workflow-name` to `registry.workflowName(oracle)`. The provider links the wrapper
using its `linkOwner(expiry, proof, signature)` with a Chainlink-issued ownership
proof for that wrapper address. This is a one-time operation independent of
curator acceptance. The current NAV workflow does not consume CRE secrets, and
this registry exposes no off-chain request authorization method.

Prepare the reviewed artifacts and unsigned registration transaction:

```sh
cre workflow deploy nav --target production-settings --unsigned
```

Decode the Chainlink `upsertWorkflow` payload and use its ID, DON family, URLs and
attributes in the proposal. Check the target registry, workflow owner, canonical
name, `default` tag and ACTIVE status. The provider proposes these fields; the
Oracle owner reviews the artifacts and accepts through `CREWorkflowRegistry`.
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
Its initializer decodes the default admin, guard and limits
role holders from `ICREOracle.InitParams`. Nonzero holders receive their configured
roles; zero addresses leave those roles unassigned. The default admin can later
change grants through `oracle.grantRole` and `oracle.revokeRole`. The owner and
default admin do not implicitly hold operational roles. Account role grants and revocations do not affect CREOracle;
CREOracle role grants and revocations take effect immediately within that instance.

| CREOracle role       | Initial holder field     | CREOracle calls                            |
| -------------------- | ------------------------ | ------------------------------------------ |
| `ORACLE_GUARD_ROLE`  | `oracleGuardRoleHolder`  | `freezeOracle()`, `unfreezeOracle(report)` |
| `ORACLE_LIMITS_ROLE` | `oracleLimitsRoleHolder` | `setOracleLimits(maxGrowth, maxLoss)`      |

`maxOracleGrowth` and `maxOracleLoss` set the initial movement limits.
These limits are independent, per accepted report, and inclusive. Valid limits
are 0–1,000,000, scaled by `ORACLE_LIMIT_PRECISION = 1_000_000`: `1_000_000` is
100%, `100_000` is 10%, and one unit is 0.0001%. Zero forbids movement in that
direction. They do not bound cumulative drawdown or annualized returns. Changing
movement limits does not clear a freeze or refresh the accepted snapshot.

CREOracle's owner remains the authority for factory-approved implementation
migrations and workflow acceptance. Transferring CREOracle ownership changes who
can accept pending and future proposals immediately; account and adapter ownership
transfers do not. CREOracle ownership, CREOracle roles and account roles
are independent; transfer those separately when handing over the complete strategy.

## Report acceptance

CREOracle verifies the forwarder, accepted workflow, destination chain/oracle/adapter,
next nonce and advancing past-block snapshot at or after the stored cutoff. The
reviewed workflow establishes snapshot finality. `MAX_REPORT_AGE` is the immutable
report-delivery age bound; `MAX_ORACLE_AGE` is the immutable freshness bound for
report acceptance, review and subsequent NAV-dependent calls. Both are constructor
parameters shared by proxies using that implementation. Changing either requires
migration to a factory-approved implementation.

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
percentage limit. Overflow in the stored baseline or reserves reverts. CREOracle
checks snapshot freshness; its `settleReport(observed)` call asks the adapter to
check report NAV plus reserves and idle backing, reserve the withdrawal and rotate
the batches. The adapter returns the remaining NAV, or rejects without changing
any accounting. CREOracle freezes on
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
meaning. Deploy or upgrade the adapter, CREOracle and workflow together; a workflow
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
deallocation and withdrawal-request paths revert through CREOracle validation.
`manage` remains available under its existing proofs, roles and reserve
checks for recovery. Existing allowances and signature approvals are not revoked.

An expired accepted snapshot also makes NAV-dependent calls revert. That read
failure cannot persist a freeze; a fresh accepted report restores freshness. An
already latched freeze still requires `ORACLE_GUARD_ROLE`, including after a
workflow change.

## Recovery

For a verified report, reconstruct `abi.encode(ICREOracle.Report)` from its
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
an arbitrary NAV or approve a report that has not reached CREOracle.

For an erroneous report, repair the source or propose and accept the corrected
workflow. `unfreezeOracle("")` clears the freeze and cache without accepting a
report or changing NAV, nonce, cutoff or snapshot age. NAV-dependent operations
resume only if the previously accepted snapshot remains fresh. A subsequent
authenticated report must satisfy the ordinary limits and use `oracle.nonce()+1`.

A top-level transaction revert rolls back all changes, including when a later
call in the same batch reverts.

## Bootstrap without migration

1. Deploy `CREWorkflowRegistry(provider, chainlinkWorkflowRegistry)`. The provider whitelists
   `CREOracle(factory, workflowRegistry, productionForwarder, maxReportAge, maxOracleAge, reportInterval, reportBuffer)` and
   `MerkleAccount(accountFactory, merkleAdapterFactory, rootRegistry, capabilitiesRegistry)` in their factories.
2. Create the adapter with `IMerkleAdapter.InitParams({oracleData: oracleData, merkleAccountData: merkleAccountData})`.
   Encode `oracleData` as `ICREOracle.InitParams` with `defaultAdminRoleHolder`,
   `oracleGuardRoleHolder`, `oracleLimitsRoleHolder`,
   `maxOracleGrowth` and `maxOracleLoss`. Encode `merkleAccountData` as
   `IMerkleAccount.InitParams({defaultAdminRoleHolder: accountAdmin})`.
   The adapter creates each latest child version with `abi.encode(address(this), childData)`;
   each child decodes its own settings. Both are initially owned by the adapter owner,
   and the account checks that its adapter is registered in `MERKLE_ADAPTER_FACTORY`
   before approving it for the vault's underlying asset.
   All three addresses now exist. The accepted workflow and snapshot start unset
   and cutoff is zero, so NAV-dependent adapter operations are unavailable.
3. Build the workflow configuration using these addresses; finalize the code,
   configuration and owner, calculate the ID, and present the artifacts for review.
4. Link the registry with CRE once and prepare unsigned deployment metadata. Its owner
   calls `registry.proposeWorkflow(oracle, id, params)`; `CREOracle.owner()` calls
   `registry.acceptWorkflow(oracle, id, params)` to register and authorize it.
   Failed registration or receiver updates preserve the proposal and existing registration.
5. Verify the initial finalized zero-NAV report from that active workflow
   is accepted and schedules the first future cutoff. Verify the initialized CREOracle
   roles and limits, adjust them through the configured operators as needed, grant account leaf roles
   through the account's default admin, and enable the strategy. A positive initial NAV requires explicit authenticated-report review;
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
10% offchain deviation policy with CREOracle's configured limits. Its reconciliation
uses the same cash-flow-adjusted baseline and pre-release NAV, but it does not yet
read the onchain policy. The producer currently withholds outliers before
delivery; direct curator review requires an authenticated report to reach CREOracle
and populate `rejectedReportHash` first.
The NAV client reads the stored cutoff and report interval at its chosen block,
and valuation rejects snapshots before that cutoff. The current hourly CRE
workflow also checks that `REPORT_INTERVAL` is 3600 seconds before submission.
After a delayed delivery, it follows the stored nonce and cutoff rather than
inferring them from elapsed intervals. Keep the chosen snapshot finalized and
within both delivery and curator age limits while preparing the closed batch's
liquidity.

Tests exercise actual adapter/CREOracle factories and signed delivery through the
vendored KeystoneForwarder, including independent curator approvals, workflow
replacement, guard failures, recovery and bootstrap. They do not claim a deployed
CRE workflow or live end-to-end NAV submission.
