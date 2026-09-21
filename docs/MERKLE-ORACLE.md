# MerkleAdapter NAV oracle

Each adapter has its own Oracle proxy. Oracle authenticates CRE reports and owns
NAV validation, limits and freeze state. MerkleAdapter calls `oracle.validate()`
before NAV-dependent operations; it keeps the portfolio's allocation and withdrawal
accounting. Raw oracle getters remain readable during a freeze for inspection and
recovery.

The workflow reads `adapter.account()` and values account positions, account
underlying and adapter underlying at one snapshot. It subtracts reserves for the
proposed epoch once; only the adapter underlying balance may satisfy those
reserves. Transfers across this custody boundary leave total NAV unchanged.

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
contract. It preserves NAV, nonce, snapshots, limits and any freeze, and clears an
outstanding exact-report exception. Reports from the previous workflow stop being
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

| Account role         | Oracle calls                                       | Initial policy                |
| -------------------- | -------------------------------------------------- | ----------------------------- |
| `ORACLE_GUARD_ROLE`  | `freezeOracle()`, `unfreezeOracle(approvedReport)` | Unfrozen                      |
| `ORACLE_LIMITS_ROLE` | `setOracleLimits(maxGrowthBps, maxLossBps)`        | 1,000 bps up / 1,000 bps down |
| `ORACLE_AGE_ROLE`    | `setMaxOracleAge(seconds)`                         | 1 day                         |

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
next nonce and advancing past-block snapshot. The reviewed workflow establishes
snapshot finality. `MAX_REPORT_AGE` is the immutable
report-delivery age bound; `maxOracleAge` is the curator's freshness policy for
report acceptance and subsequent NAV-dependent calls.

For current nonce `n`, the movement guard compares:

```text
baseline = acceptedOracleAssets + adapter.pendingAllocation[n]
observed = proposedOracleAssets + adapter.deallocatableAt(n+1) - adapter.deallocatableAt(n)
```

Allocations entering NAV do not look like yield, and withdrawals becoming reserved
do not look like losses. Pending allocations still outside NAV cannot dilute the
percentage limit. Oracle also checks addition overflow, snapshot freshness and
whether idle assets cover `adapter.reservedAssetsAt(n+1)`.

A guard rejection sets `oracleFrozen`, emits `FreezeOracle` and `RejectReport`, and
returns successfully without changing the accepted NAV, nonce or snapshot. A
revert would undo the freeze. Monitor `OnReport` and the stored nonce; successful
forwarder delivery alone is not NAV acceptance. Malformed or unauthenticated
reports revert before reaching the guard and cannot freeze the oracle.

While frozen, the adapter's `totalAssets`, `allocatable`, nonzero allocation,
deallocation and withdrawal-request paths revert through Oracle validation.
`manage` remains available under its existing proofs, roles and reserve
checks for recovery. Existing allowances and signature approvals are not revoked.

An expired accepted snapshot also makes NAV-dependent calls revert. That read
failure cannot persist a freeze; a fresh accepted report restores freshness. An
already latched freeze still requires `ORACLE_GUARD_ROLE`, including after a
workflow change.

## Recovery

For an erroneous report, repair the source or propose and accept the corrected
workflow, then call `unfreezeOracle(bytes32(0))`. Submit a fresh authenticated report
within the limits. The accepted epoch has not advanced: use `oracle.nonce()+1`.

For a verified real movement beyond policy, call
`unfreezeOracle(keccak256(abi.encode(report)))`. It allows that exact authenticated
report to exceed percentage limits once; it cannot write NAV or bypass workflow,
destination, nonce, snapshot, age or reserve checks. Any accepted report or workflow
acceptance clears the exception. Review a fresh report if the old one expired.

Use a new CRE execution to deliver a retry when the forwarder recorded the rejected
report's delivery as successful. Its execution ID cannot be reused. A top-level
transaction revert always rolls back a freeze, including if a later batched call
reverts.

## Bootstrap without migration

1. The provider whitelists `Oracle(factory, productionForwarder, maxReportAge)` and
   `MerkleAccount(accountFactory, rootRegistry, capabilitiesRegistry)` in their factories.
2. Create the adapter. It creates the latest account version with
   `abi.encode(IMerkleAccount.InitParams({adapter: adapter, defaultAdminRoleHolder: admin}))`
   and its Oracle proxy with `abi.encode(adapter)`. Both are initially owned by the adapter owner.
   All three addresses now exist. The accepted workflow and snapshot start unset, so
   NAV-dependent adapter operations are unavailable.
3. Build the workflow configuration using these addresses; finalize the code,
   configuration and owner, calculate the ID, and present the artifacts for review.
4. The oracle-factory owner calls `oracle.proposeWorkflow(id)`. The account's
   current owner calls `oracle.acceptWorkflow(id)`.
5. Activate that exact workflow and verify the initial finalized zero-NAV report
   is accepted. Grant the desired account roles, configure limits, and enable the
   strategy. A positive initial NAV requires explicit authenticated-report review;
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
wiring still needs signed CRE report generation/delivery and must align its raw
10% offchain deviation check with Oracle's configured, cash-flow-adjusted policy.

Tests exercise actual adapter/Oracle factories and signed delivery through the
vendored KeystoneForwarder, including independent curator approvals, workflow
replacement, guard failures, recovery and bootstrap. They do not claim a deployed
CRE workflow or live end-to-end NAV submission.
