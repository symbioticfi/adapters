# Deploying and operating the Merkle stack

The Solidity stack can be deployed and exercised locally. Production activation
requires a separate NAV integration review and actual deployment validation.
The sibling `chainlink-nav` is excluded from the scoped contract review: its
current reader/reconciliation still uses removed batch/nonce/cutoff semantics,
and its submission client is an in-memory mock. The
[audit handoff](MERKLE-AUDIT-HANDOFF.md) defines the exact boundary, matching-producer
fixture and closure evidence. Do not allocate vault funds until the reviewed
workflow completes the real delivery, acceptance and liquidity-release path.

## Core deployment

`script/deploy/adapters/DeployMerkleAdapter.s.sol` deploys the root and capability
registries, an immutable CRE workflow registry, three versioned factories, their initial implementations, and one
adapter with its account and CREOracle. It checks configuration before broadcasting
and verifies ownership and the initial account allowance during simulation. Additional
adapters can reuse these factories.

Set these environment variables locally. All addresses refer to the target chain.
The available Chainlink on-chain registry is on Ethereum mainnet at
`0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5`; verify its `typeAndVersion()`
is `WorkflowRegistry 2.0.0`. The workflow registry and Oracles must share its chain:

| Variable                             | Value                                                                                     |
| ------------------------------------ | ----------------------------------------------------------------------------------------- |
| `MERKLE_VAULT_FACTORY`               | Symbiotic vault registry containing the vault                                             |
| `MERKLE_VAULT`                       | Registered vault to connect                                                               |
| `MERKLE_PROVIDER`                    | Provider governance address; owns registries and factories                                |
| `MERKLE_CURATOR`                     | Initial owner of adapter, account and CREOracle                                           |
| `MERKLE_ADMIN`                       | Initial account `DEFAULT_ADMIN_ROLE` holder                                               |
| `MERKLE_ORACLE_ADMIN`                | Initial CREOracle `DEFAULT_ADMIN_ROLE` holder                                             |
| `MERKLE_ORACLE_GUARD`                | Initial CREOracle `ORACLE_GUARD_ROLE` holder                                              |
| `MERKLE_ORACLE_LIMITS`               | Initial CREOracle `ORACLE_LIMITS_ROLE` holder                                             |
| `MERKLE_MAX_ORACLE_GROWTH`           | Initial maximum NAV increase per accepted report, 0–100,000,000; 10,000,000 means 10%     |
| `MERKLE_MAX_ORACLE_LOSS`             | Initial maximum NAV decrease per accepted report, 0–100,000,000; 10,000,000 means 10%     |
| `MERKLE_ORACLE_TOLERANCE`            | Initial absolute NAV change, in vault-asset base units, accepted regardless of the limits |
| `MERKLE_CHAINLINK_WORKFLOW_REGISTRY` | Chainlink WorkflowRegistry 2.0.0 on the target chain                                      |
| `MERKLE_FORWARDER`                   | Verified production KeystoneForwarder for this chain, stored per CREOracle proxy          |
| `MERKLE_MAX_REPORT_AGE`              | Immutable maximum delivery age, in seconds                                                |
| `MERKLE_MAX_ORACLE_AGE`              | Immutable maximum accepted NAV age, in seconds                                            |
| `MERKLE_REPORT_INTERVAL`             | Immutable report interval, in seconds; nonzero `uint48`                                   |

Movement limits use `ORACLE_LIMIT_PRECISION = 100_000_000`, where `100_000_000` means
100% and one unit means 0.000001%. The tolerance is an absolute amount that always
passes; see [curator controls](MERKLE-ORACLE.md#curator-controls) for sizing.

Both age limits and the report interval are required explicitly; the script supplies
no production defaults. They become `MAX_REPORT_AGE`, `MAX_ORACLE_AGE` and
`REPORT_INTERVAL` on the implementation. All are nonzero `uint48` values. Size them
for chain finality, workflow execution and delivery. There is no report buffer or
cutoff. One snapshot per Unix-aligned report interval can be accepted, independent
of allocation timing; a withdrawal's staged cash must be covered by the accepted snapshot. See [time fields and encoding](MERKLE-ORACLE.md#time-fields-and-encoding).

Use governance multisigs for production authorities. The script does not assume
the broadcaster is any of those authorities. Resolve the forwarder through
Chainlink's [forwarder directory](https://docs.chain.link/cre/guides/workflow/using-evm-client/forwarder-directory-go)
and verify deployed code and the configured chain. A nonzero address with code is
only a deployment preflight, not authentication of the correct forwarder.

Run a dry run first, using a configured encrypted Foundry keystore:

```sh
forge script script/deploy/adapters/DeployMerkleAdapter.s.sol:DeployMerkleAdapterScript \
  --rpc-url "$ETH_RPC_URL" --account deployer
```

After reviewing the addresses, transactions and gas estimates, add `--broadcast`
to the same command to deploy. The script prints all deployed addresses; retain
Foundry's broadcast artifact and publish verified sources for implementations and
proxies. Resolve the adapter from the actual factory `AddEntity` receipt, then
read its account and CREOracle and recheck pairing, authorities and allowances onchain.
The factory creation counter can change between simulation and broadcast; printed
simulation addresses alone are not deployment evidence. The build is pinned to Solidity 0.8.37, optimizer 200, global `via_ir=true`,
`bytecode_hash=none`, EVM Osaka. Use a chain supporting that EVM target; the code
also uses transient storage.

For CREATE2 address predictions, use the proxy creation bytecode from the exact
build of the deployed factory. Switching compiler pipelines changes this bytecode
in new factory builds; existing factories retain their embedded creation code.

Deployment leaves the account root empty and the workflow unset. The script encodes
CREOracle's forwarder, role holders, movement limits and dust tolerance in `oracleData`, and the account's admin
in `merkleAccountData`. The adapter wraps each payload with its own address before
creating that child. Each nonzero CREOracle role holder receives its configured role;
zero leaves it unassigned. The account checks adapter registration in its immutable
`MERKLE_ADAPTER_FACTORY` before approving the adapter for the underlying asset;
the adapter approves the vault. No protocol allowance or signed order is created.

## Activation

1. Verify `adapter.account()`, `adapter.oracle()`, the account's `adapter()`,
   factory registrations, implementation versions, owners and each contract's default admin.
   Verify `oracle.WORKFLOW_REGISTRY()`, the workflow registry owner and its
   `CHAINLINK_WORKFLOW_REGISTRY()` dependency. Verify CREOracle's `MAX_REPORT_AGE`,
   `MAX_ORACLE_AGE` and `REPORT_INTERVAL` against the reviewed configuration.
   Accepted snapshot fields initially equal zero.
2. Verify CREOracle's initial role grants and movement limits against the configuration.
   CREOracle's default admin (`MERKLE_ORACLE_ADMIN`) can update grants using
   `oracle.grantRole` and `oracle.revokeRole`. Owner and default admin do not
   implicitly hold operational roles. The limits operator can change the movement
   limits; the freshness limit is fixed in the implementation.
3. Link the deployed `CREWorkflowRegistry` once as the CRE workflow owner, then prepare
   the exact NAV artifacts with `cre workflow deploy nav --target production-settings --unsigned`.
   Use the Oracle address as the lowercase workflow name and `default` as its tag.
   Chainlink allows one active link per owner; a failed link can be retried, and after
   an upstream unlink the owner relinks with a fresh proof. Verify the current link
   through Chainlink's `isOwnerLinked(registry)`.
   Symbiotic and the curator can rotate the registry and Oracle owner addresses at
   any time. Their proposal and acceptance permissions follow the current owners,
   while the registry's CRE organization link and accepted workflows stay unchanged.
   The registry owner proposes the ID and registration fields; `CREOracle.owner()`
   accepts through `registry.acceptWorkflow(oracle, id, params)`. That transaction
   registers the workflow on Chainlink and updates the receiver atomically. See
   [registration preparation](MERKLE-ORACLE.md#preparing-on-chain-registration).
   Verify an initial accepted `OnReport` and fresh advancing snapshot.
   A successful forwarder delivery alone does not prove acceptance. The five-word
   signed report encodes chain ID, adapter, full portfolio NAV, snapshot block and
   snapshot timestamp. Snapshot blocks must be completed and finalized, and later
   reports must advance to a new Unix-aligned interval. The oracle reconciles
   contract-owned flow checkpoints; the producer must not subtract reserves or
   pending withdrawals. Update report and event encoders before activation.
   Verify the liquidity path: request deallocation, return and stage cash, accept
   a report whose snapshot covers `stagedBlock`, then deallocate released cash.
   Direct protocol payouts require `stageLiquidity()` before that snapshot;
   ordinary `pull` stages automatically while there is outstanding demand.
4. The provider proposes the account's root and whitelists any capability selectors.
   The account owner accepts the root and adds each capability. The account's default admin
   grants each approved leaf role to the intended manager or executor.
5. Simulate the complete strategy and recovery path with those actual roles,
   balances, issuer allowlists and protocol markets before enabling allocations.
   An approved action does not establish issuer KYC or available protocol liquidity.

The account includes OpenZeppelin's ERC-721 receiver, allowing Ether.fi and Makina
native redemption receipts to be safely minted to it. Receipt acceptance grants
no execution role. RecipeExecutor handles issuer calls through approved leaves;
claims that become available later need a separate execution.

## Automation and connector deployment

Deploy `ImmutableFactory(type(RecipeExecutor).creationCode)` once for the reviewed
executor build. `factory.create(abi.encode(curator, account))` creates an executor.
The curator saves its recipe and caller, then the role admin grants only that
recipe's leaf roles to its address. Store the complete configuration event and
verify its hash when recovering the recipe. The factory must use the same creation
bytecode hash pinned in the frontend; every code change can change that hash.

Deploy `MigratablesFactory(factoryOwner)` for the 3F policy implementations. The
factory owner deploys and whitelists `ThreeFPolicy(policyFactory)`. Create the policy with
`policyFactory.create(version, curator, abi.encode(consumer))`, using the reviewed
implementation version. Configure `setMinYieldPerRequest(asset, minimum)` and
`setMaxAssetsPerDuration(asset, maxAssets, duration)` as the curator. Select the sole
consumer to match `ThreeFExecuting.Config.guardedMint`:

- With `guardedMint: true`, use the account as consumer. The guarded mint leaf
  includes `consume` and request-factory validation; the policy call originates
  from the account. Direct managers and other executors using that leaf share the
  same budget. Stopping one executor does not stop those paths.
- With `guardedMint: false`, use the executor as consumer. Its committed recipe
  consumes the policy through a `Call` and checks factory membership and the mint's
  cash, principal and yield movements. Grant the native mint and funding leaf
  roles only to that executor so those actions cannot bypass the recipe's policy
  and checks.

`setConsumer(address(0))` stops policy consumption. Changing the consumer preserves
period usage and disables the previous consumer; use separate policy instances
when both modes need concurrent independent budgets. See [3F recipes](RECIPE-EXECUTOR.md#3f).

Liquid Lane uses a separate migratable factory for
`LiquidLaneConnector(factory, merkleAccountFactory, oracleRegistry)`. Use the
Merkle adapter's `ACCOUNT_FACTORY()` as `merkleAccountFactory`; initialization
requires that factory's `isEntity(account)` to return true. Create a connector for the account
with `abi.encode(account, inputAsset)`; then let the provider
register the approved token oracles against the connector address. Add tokens and
budgets through approved account actions. The connector owner sets signer and
minimum discounts. Adding a token requires its current registry approval; registry
changes alone do not replace an already saved oracle. Remove and re-add in the
same `account.manage` batch to accept a replacement. Existing spending survives
this reconfiguration.

## Stop, recover and hand over

- Stop the executor with `setCaller(address(0))`. Revoking its account leaf roles
  removes those account permissions; executor-originated `Call` instructions can
  still run while its caller remains enabled.
- The account owner calls `account.revokeSignature(digest)` directly to cancel an
  EIP-1271 approval, even after clearing the root or leaf roles. Root or role changes
  alone preserve saved approvals. Clear unwanted token allowances and perform
  protocol nonce cancellation through their approved account leaves; keep those
  recovery permissions available.
- The workflow registry exposes proposal, acceptance and owner linking. It has
  no per-workflow removal or pause method. Upstream unlinking deletes all of the
  wrapper's registrations without clearing Oracle state or pending proposals;
  relinking requires a fresh Chainlink proof. Ordinary workflow rotation requires
  a fresh ID on the same DON and an existing ACTIVE record.
- `freezeOracle()` stops NAV-dependent vault operations; it does not stop account
  management, protocol allowances or signed-order settlement. Recovery still uses
  approved account actions and can return underlying via `adapter.pull(amount)`.
- Review the cause of a rejected report before unfreezing. For a verified report,
  pass its full encoded payload to `unfreezeOracle`; its hash must match
  `rejectedReportHash`. The call accepts it immediately with freshness, cadence and arithmetic
  checks. Empty bytes only clear the freeze and cache, preserving the old NAV and
  snapshot age. See
  [CREOracle recovery](MERKLE-ORACLE.md#recovery).
- Transfer account, CREOracle and adapter ownership separately. Grant the successor
  the necessary admin and operational roles, verify them, then revoke predecessor
  roles. Transfer executor, policy and connector ownership and update callers and
  signers separately. Account ownership alone does not complete a handover.

To remove an adapter, call the delegator's `forceDeallocate`, return strategy cash
through approved account actions, wait for a covering report, and call
`sweepPending` before `removeAdapter`. Check actual outstanding demand after each
sweep: concurrent withdrawal-queue demand can replace the curator's larger exit
request. After the queue is filled, call `forceDeallocate` again for any remaining
adapter assets and wait for their covering report before the final sweep and
removal. The force call lowers the absolute allocation limit, preventing new
allocations during this exit.

Monitor accepted snapshot block and age, `RejectReport`/`FreezeOracle`, outstanding
withdrawal demand, staged cash/block, released liquidity, recipe failures,
outstanding orders and issuer claim readiness. Enabling
an executor does not schedule transactions; an external operator must submit them.

## Verification boundary

`test/deploy/DeployMerkleAdapter.t.sol` executes the deployment script's core path,
checks separated authorities, delivers a signed report through the vendored
KeystoneForwarder, freezes/unfreezes, and exercises root/role-gated push/pull.
These tests use a test vault, the pinned upstream Chainlink v2 registry and local
report/link-proof signers. They do not run a deployed CRE workflow.
The broadcast regression also exercises the unmodified script's broadcaster and
checks that the transaction origin retains no unintended authority.

`CREWorkflowRegistryMainnet.t.sol` exercises registration, replacement and rollback
against the deployed Chainlink registry at Ethereum block 26,032,120. It impersonates
registry governance only to authorize a test link-proof signer and DON. Report
routing uses the local forwarder fixture; no artifacts are uploaded or live CRE
workflow executions tested by this fork suite.

Pinned mainnet tests exercise native issuer calls, CoW settlement, Aave, Morpho and
Euler. Some issuer cases enroll addresses through issuer-admin calls, unpause
redemptions or adjust time; they establish call compatibility under those stated
conditions, not permissionless access for a newly deployed account. The Aave liquidity regression includes the older V3.3 weighted-threshold
rounding calculation. Morpho nested-wrapper and gated-exit variants still have
mock coverage rather than verified live fork coverage; configure only supported,
simulated routes. Fork success at a fixed block does not establish current issuer
permissions or current market liquidity.

The automated Slither pass has partial IR-generation gaps in the current compiler
and OpenZeppelin combination, including the connector's EIP-712 base. Its detector
output is supplementary evidence, not a complete static-analysis signoff.

Before activation, finish and validate the production NAV path, review the exact
root masks and recipe commitments, run the target-chain deployment dry run, verify
issuer onboarding, and freeze the release for independent security review. This
repository does not claim a production deployment.
