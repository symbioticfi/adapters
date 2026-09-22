# Deploying and operating the Merkle stack

The Solidity stack can be deployed and exercised locally. Production activation is
still blocked by the NAV integration: `../chainlink-nav` uses an in-memory
submission client, has unresolved discovery-completeness gates, and has not
successfully delivered a live CRE report for a MerkleAdapter epoch. Do not allocate
vault funds until the exact deployed workflow completes that path.

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

| Variable                             | Value                                                                                        |
| ------------------------------------ | -------------------------------------------------------------------------------------------- |
| `MERKLE_VAULT_FACTORY`               | Symbiotic vault registry containing the vault                                                |
| `MERKLE_VAULT`                       | Registered vault to connect                                                                  |
| `MERKLE_PROVIDER`                    | Provider governance address; owns registries and factories                                   |
| `MERKLE_CURATOR`                     | Initial owner of adapter, account and CREOracle                                              |
| `MERKLE_ADMIN`                       | Initial account `DEFAULT_ADMIN_ROLE` holder                                                  |
| `MERKLE_ORACLE_ADMIN`                | Initial CREOracle `DEFAULT_ADMIN_ROLE` holder                                                |
| `MERKLE_ORACLE_GUARD`                | Initial CREOracle `ORACLE_GUARD_ROLE` holder                                                 |
| `MERKLE_ORACLE_LIMITS`               | Initial CREOracle `ORACLE_LIMITS_ROLE` holder                                                |
| `MERKLE_MAX_ORACLE_GROWTH_BPS`       | Initial maximum NAV increase per accepted report, 0–10,000 bps                               |
| `MERKLE_MAX_ORACLE_LOSS_BPS`         | Initial maximum NAV decrease per accepted report, 0–10,000 bps                               |
| `MERKLE_CHAINLINK_WORKFLOW_REGISTRY` | Chainlink WorkflowRegistry 2.0.0 on the target chain                                         |
| `MERKLE_FORWARDER`                   | Verified production KeystoneForwarder for this chain                                         |
| `MERKLE_MAX_REPORT_AGE`              | Immutable maximum delivery age, in seconds                                                   |
| `MERKLE_MAX_ORACLE_AGE`              | Immutable maximum accepted NAV age, in seconds                                               |
| `MERKLE_REPORT_INTERVAL`             | Immutable report interval, in seconds; nonzero `uint48`                                      |
| `MERKLE_REPORT_BUFFER`               | Immutable cutoff offset before each interval boundary, in seconds; smaller than the interval |

Both age limits and both schedule values are required explicitly; the script supplies no production
defaults. They become `MAX_REPORT_AGE`, `MAX_ORACLE_AGE`, `REPORT_INTERVAL` and
`REPORT_BUFFER` on the CREOracle implementation, shared by its proxies. Size the schedule for the target chain's
finality, workflow execution and delivery, and the strategy's liquidity return
process. The buffer shifts the batch cutoff before an interval boundary; it does
not guarantee finality, schedule report delivery, or extend either age limit.

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
simulation addresses alone are not deployment evidence. The build is pinned to Solidity 0.8.37, optimizer 200, `via_ir=false`,
`bytecode_hash=none`, EVM Osaka. Use a chain supporting that EVM target; the code
also uses transient storage.

Deployment leaves the account root empty and the workflow unset. The script encodes
CREOracle's role holders and movement limits in `oracleData`, and the account's admin
in `merkleAccountData`. The adapter wraps each payload with its own address before
creating that child. Each nonzero CREOracle role holder receives its configured role;
zero leaves it unassigned. The account checks adapter registration in its immutable
`MERKLE_ADAPTER_FACTORY` before approving the adapter for the underlying asset;
the adapter approves the vault. No protocol allowance or signed order is created.

## Activation

1. Verify `adapter.account()`, `adapter.oracle()`, the account's `adapter()`,
   factory registrations, implementation versions, owners and each contract's default admin.
   Verify `oracle.WORKFLOW_REGISTRY()`, the workflow registry owner and its
   `CHAINLINK_WORKFLOW_REGISTRY()` dependency. Verify CREOracle's `MAX_REPORT_AGE`, `MAX_ORACLE_AGE`, `REPORT_INTERVAL` and
   `REPORT_BUFFER` against the reviewed configuration; `cutoff()` is initially zero.
2. Verify CREOracle's initial role grants and movement limits against the configuration.
   CREOracle's default admin (`MERKLE_ORACLE_ADMIN`) can update grants using
   `oracle.grantRole` and `oracle.revokeRole`. Owner and default admin do not
   implicitly hold operational roles. The limits operator can change the movement
   limits; the freshness limit is fixed in the implementation.
3. Link the deployed `CREWorkflowRegistry` once as the CRE workflow owner, then prepare
   the exact NAV artifacts with `cre workflow deploy nav --target production-settings --unsigned`.
   Use the Oracle address as the lowercase workflow name and `default` as its tag.
   Successful linking permanently sets `initialized`; a failed link can be retried.
   Symbiotic and the curator can rotate the registry and Oracle owner addresses at
   any time. Their proposal and acceptance permissions follow the current owners,
   while the registry's CRE organization link and accepted workflows stay unchanged.
   The registry owner proposes the ID and registration fields; `CREOracle.owner()`
   accepts through `registry.acceptWorkflow(oracle, id, params)`. That transaction
   registers the workflow on Chainlink and updates the receiver atomically. See
   [registration preparation](MERKLE-ORACLE.md#preparing-on-chain-registration).
   Verify an initial accepted `OnReport`, advancing nonce and fresh snapshot.
   A successful forwarder delivery alone does not prove CREOracle acceptance.
   The signed asset field must use `oracleUpdate.preReleaseAssets`, before the
   newly matured withdrawal release; `oracleUpdate.oracleAssets` is the resulting
   stored NAV. Older workflows using that net value as the signed input are
   incompatible. Upgrade adapter, CREOracle and workflow together.
   The workflow must read the stored cutoff and choose a finalized snapshot at or
   after it. After bootstrap, check that the accepted report schedules a future
   cutoff. A late report settles only the closed batch, with later requests kept
   for the following report; it does not advance once per missed wall-clock interval.
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
`policyFactory.create(version, curator, abi.encode(account))`, using the reviewed
implementation version. Configure `setMinYieldPerRequest(asset, minimum)` and
`setMaxAssetsPerDuration(asset, maxAssets, duration)` as the curator. The guarded
mint leaf must include `consume` and request-factory validation. Its call originates
from the account, so `ThreeFExecuting` requires the account as the policy's sole
consumer. Direct managers and other executors using that leaf share the same budget.
Stopping one executor does not stop those paths; `setConsumer(address(0))` stops
policy consumption across them.

Liquid Lane uses a separate migratable factory for
`LiquidLaneConnector(factory, merkleAccountFactory, oracleRegistry)`. Use the
Merkle adapter's `ACCOUNT_FACTORY()` as `merkleAccountFactory`; initialization
requires that factory's `isEntity(account)` to return true. Create a connector for the account
with `abi.encode(account, inputAsset, new address[](0))`; then let the provider
register the approved token oracles against the connector address. Add tokens and
budgets through approved account actions. The connector owner sets signer and
minimum discounts. Adding a token requires its current registry approval; registry
changes alone do not replace an already saved oracle. Remove and re-add in the
same `account.manage` batch to accept a replacement. Existing spending survives
this reconfiguration.

## Stop, recover and hand over

- Stop a recipe with `setCaller(address(0))` or revoke its account leaf roles.
- Before clearing the root or removing cancellation permissions, revoke outstanding
  EIP-1271 digests and clear unwanted token allowances through their approved
  account leaves. Root or role changes do not invalidate existing signatures or
  allowances. Keep cancellation leaves and an emergency operator in every root.
- `freezeOracle()` stops NAV-dependent vault operations; it does not stop account
  management, protocol allowances or signed-order settlement. Recovery still uses
  approved account actions and can return underlying via `adapter.pull(amount)`.
- Review the cause of a rejected report before unfreezing. For a verified report,
  pass its full encoded payload to `unfreezeOracle`; its hash must match
  `rejectedReportHash`. The call accepts it immediately with freshness and reserve
  checks. Empty bytes only clear the freeze and cache, preserving the old NAV and
  snapshot age. See
  [CREOracle recovery](MERKLE-ORACLE.md#recovery).
- Transfer account, CREOracle and adapter ownership separately. Grant the successor
  the necessary admin and operational roles, verify them, then revoke predecessor
  roles. Transfer executor, policy and connector ownership and update callers and
  signers separately. Account ownership alone does not complete a handover.

Monitor accepted report nonce, age and cutoff, `RejectReport`/`FreezeOracle`, reserve
coverage, recipe failures, outstanding orders and issuer claim readiness. Enabling
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
