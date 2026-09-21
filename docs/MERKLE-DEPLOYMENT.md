# Deploying and operating the Merkle stack

The Solidity stack can be deployed and exercised locally. Production activation is
still blocked by the NAV integration: `../chainlink-nav` uses an in-memory
submission client, has unresolved discovery-completeness gates, and has not
successfully delivered a live CRE report for a MerkleAdapter epoch. Do not allocate
vault funds until the exact deployed workflow completes that path.

## Core deployment

`script/deploy/adapters/DeployMerkleAdapter.s.sol` deploys the root and capability
registries, three versioned factories, their initial implementations, and one
adapter with its account and Oracle. It checks configuration before broadcasting
and verifies ownership and the initial account allowance during simulation. Additional
adapters can reuse these factories.

Set these environment variables locally. All addresses refer to the target chain:

| Variable                 | Value                                                                                        |
| ------------------------ | -------------------------------------------------------------------------------------------- |
| `MERKLE_VAULT_FACTORY`   | Symbiotic vault registry containing the vault                                                |
| `MERKLE_VAULT`           | Registered vault to connect                                                                  |
| `MERKLE_PROVIDER`        | Provider governance address; owns registries and factories                                   |
| `MERKLE_CURATOR`         | Initial owner of adapter, account and Oracle                                                 |
| `MERKLE_ADMIN`           | Initial account `DEFAULT_ADMIN_ROLE` holder                                                  |
| `MERKLE_FORWARDER`       | Verified production KeystoneForwarder for this chain                                         |
| `MERKLE_MAX_REPORT_AGE`  | Immutable maximum delivery age, in seconds                                                   |
| `MERKLE_REPORT_INTERVAL` | Immutable report interval, in seconds; nonzero `uint48`                                      |
| `MERKLE_REPORT_BUFFER`   | Immutable cutoff offset before each interval boundary, in seconds; smaller than the interval |

Both schedule values are required explicitly; the script supplies no production
defaults. They become `REPORT_INTERVAL` and `REPORT_BUFFER` on the Oracle
implementation, shared by its proxies. Size the schedule for the target chain's
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
read its account and Oracle and recheck pairing, authorities and allowances onchain.
The factory creation counter can change between simulation and broadcast; printed
simulation addresses alone are not deployment evidence. The build is pinned to Solidity 0.8.37, optimizer 200, `via_ir=false`,
`bytecode_hash=none`, EVM Osaka. Use a chain supporting that EVM target; the code
also uses transient storage.

Deployment leaves the account root empty, the workflow unset and operational roles
ungranted. The account approves only its paired adapter for the underlying asset;
the adapter approves the vault. No protocol allowance or signed order is created.

## Activation

1. Verify `adapter.account()`, `adapter.oracle()`, the account's `adapter()`,
   factory registrations, implementation versions, owners and default admin.
   Verify Oracle's `REPORT_INTERVAL` and `REPORT_BUFFER` against the reviewed
   workflow schedule; `cutoff()` is initially zero.
2. The default admin grants the selected guard operator `ORACLE_GUARD_ROLE`, and
   grants `ORACLE_LIMITS_ROLE` and `ORACLE_AGE_ROLE` to their intended operators.
   Owner and default admin do not implicitly hold these roles. Configure Oracle's
   movement limits and freshness policy using those operators.
3. Deploy the exact reviewed NAV workflow with adapter/account/Oracle addresses.
   The Oracle factory owner proposes its workflow ID; the account owner accepts
   it. Verify an initial accepted `OnReport`, advancing nonce and fresh snapshot.
   A successful forwarder delivery alone does not prove Oracle acceptance.
   The signed asset field must use `oracleUpdate.preReleaseAssets`, before the
   newly matured withdrawal release; `oracleUpdate.oracleAssets` is the resulting
   stored NAV. Older workflows using that net value as the signed input are
   incompatible. Upgrade adapter, Oracle and workflow together.
   The workflow must read the stored cutoff and choose a finalized snapshot at or
   after it. After bootstrap, check that the accepted report schedules a future
   cutoff. A late report settles only the closed batch, with later requests kept
   for the following report; it does not advance once per missed wall-clock interval.
4. The provider proposes the account's root and whitelists any capability selectors.
   The account owner accepts the root and adds each capability. The default admin
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
`LiquidLaneConnector(factory, oracleRegistry)`. Create a connector for the account
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
  [Oracle recovery](MERKLE-ORACLE.md#recovery).
- Transfer account, Oracle and adapter ownership separately. Grant the successor
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
These tests use a test vault and local report signers, not a deployed CRE workflow.
The broadcast regression also exercises the unmodified script's broadcaster and
checks that the transaction origin retains no unintended authority.

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
