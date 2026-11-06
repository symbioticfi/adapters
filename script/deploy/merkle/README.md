# Mainnet Merkle deployment

`DeployMerkleMainnetScript` deploys the adapter/account/oracle factories and
registries, RecipeCapability, RecipeExecutor factory, health/liquidity
helpers, a 3F policy factory, and a Liquid Lane connector implementation.
It binds to the existing mainnet vault factory and official CRE/3F deployments.
It creates no vault, adapter, account, oracle instance, position or workflow.
Individual adapters and their accounts/oracles are created later through Curator.

Official dependencies:

| Dependency                      | Mainnet address                              |
| ------------------------------- | -------------------------------------------- |
| Symbiotic vault factory         | `0xAEb6bdd95c502390db8f52c8909F703E9Af6a346` |
| CRE deployed-workflow forwarder | `0x0b93082D9b3C7C97fAcd250082899BAcf3af3885` |
| CRE production WorkflowRegistry | `0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5` |
| 3F RequestFactory               | `0xDE293185e96a42F4c7d1C6479407920b19012Ca5` |
| 3F Facility                     | `0x4e013ca8fF612a58F53C822904cDD0eC538a4A4F` |
| 3F RequestWhitelist             | `0x3FcD87948cBF46605D6ded0ed56d3daCcd9daf9e` |

Sources: [CRE forwarders](https://docs.chain.link/cre/guides/workflow/using-evm-client/forwarder-directory-go),
[CRE registry environments](https://github.com/smartcontractkit/cre-cli/blob/main/internal/environments/environments.yaml),
[3F deployments](https://docs.3f.xyz/protocol/deployments/?chain=mainnet).
Preflight checks the chain, CRE addresses and contract versions, the official
vault factory, and deployed 3F/LL dependencies before broadcasting.

## Confirmed mainnet deployment

[mainnet.json](mainnet.json) records the deployment broadcast on 6 November 2026
from source commit `9fb87aae`, starting at block `26355543`. All 29 saved receipts
succeeded. The 21 created contracts were verified on Etherscan and Sourcify with
Solidity 0.8.38, optimizer 200, via IR and Osaka. This is the infrastructure basis;
per-vault instances and configuration are created separately. The registry owner is
`0xAD9424354889639710DE17c2E5FbFC26bAbA047f`.

The manifest does not include NAV collectors or `ClaimReadiness`. Deploy and
configure those separately before enabling NAV reporting or recipes that require
claim discovery.

The manifest distinguishes our `workflowRegistry` wrapper from the upstream
`chainlinkRegistry`. `connectorRegistration` is the LL factory owner's whitelist
call, not a connector instance or evidence that registration is complete.

## Plan and broadcast

Set two owners: `MERKLE_FACTORIES_OWNER` for the deployed migratable factories
and `MERKLE_REGISTRIES_OWNER` for RootRegistry, CREWorkflowRegistry, OracleRegistry
and CapabilitiesRegistry. Both are required; the manifest records them alongside
the deployed addresses. Select the
existing Liquid Lane factory, reactor and protocol signer. The signer can be an
EOA or an ERC-1271 contract; it is the RFQ backend's countersigning identity.
No vault address, curator, per-vault roles or oracle limits are required.

```sh
export MERKLE_FACTORIES_OWNER=0x...
export MERKLE_REGISTRIES_OWNER=0x...
export MERKLE_LL_ADAPTER_FACTORY=0x...
export MERKLE_LL_REACTOR=0x...
export MERKLE_LL_PROTOCOL=0x...
export MERKLE_MANIFEST=deployments/merkle-mainnet.json
mkdir -p deployments

# Plan only. This writes a provisional manifest; use a different path for the broadcast.
forge script script/deploy/merkle/DeployMerkleMainnet.s.sol:DeployMerkleMainnetScript \
  --rpc-url "$ETH_RPC_URL" --account mainnet-deployer

export MERKLE_MANIFEST=deployments/merkle-mainnet-broadcast.json
forge script script/deploy/merkle/DeployMerkleMainnet.s.sol:DeployMerkleMainnetScript \
  --rpc-url "$ETH_RPC_URL" --account mainnet-deployer --broadcast
```

The script refuses to overwrite a manifest. Resume an interrupted broadcast
using Foundry's `--resume` against the same broadcast plan and wallet; do not
regenerate deployment addresses. Verify every receipt and deployed binding
before using the manifest. A successful simulation is not a deployment.

## Registries and factories

| Contract                                                         | Purpose                                                                               | Owner for a new deployment                             |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| RootRegistry                                                     | Publishes strategy roots for accounts.                                                | `MERKLE_REGISTRIES_OWNER`                              |
| CREWorkflowRegistry                                              | Proposes NAV workflows and links the registry to CRE. Oracle owners accept proposals. | `MERKLE_REGISTRIES_OWNER`                              |
| OracleRegistry                                                   | Approves an oracle for each Liquid Lane connector/token pair.                         | `MERKLE_REGISTRIES_OWNER`                              |
| CapabilitiesRegistry                                             | Approves capability selectors for individual accounts.                                | `MERKLE_REGISTRIES_OWNER`                              |
| MerkleAdapter factory (`AdapterFactory`)                         | Registers implementations and creates Merkle adapters.                                | `MERKLE_FACTORIES_OWNER`                               |
| MerkleAccount factory (`MigratablesFactory`)                     | Registers implementations and creates strategy accounts.                              | `MERKLE_FACTORIES_OWNER`                               |
| CREOracle factory (`MigratablesFactory`)                         | Registers implementations and creates NAV oracles.                                    | `MERKLE_FACTORIES_OWNER`                               |
| ThreeFPolicy factory (`MigratablesFactory`)                      | Registers implementations and creates account policies.                               | `MERKLE_FACTORIES_OWNER`                               |
| RecipeExecutor factory (`ImmutableFactory`)                      | Creates and registers executors from fixed creation code.                             | No owner; permissionless creation.                     |
| Liquid Lane connector factory (existing LL `MigratablesFactory`) | Registers the connector implementation and creates connectors.                        | Existing factory owner; not reassigned by this script. |

The protocol's existing VaultFactory and AdapterRegistry, Chainlink's upstream
WorkflowRegistry, and 3F's RequestFactory and RequestWhitelist are external
dependencies. This script does not deploy them or change their administration.
The native Liquid Lane AccountRegistry is not used by Merkle connectors.

These settings apply to new deployments. They do not transfer ownership of the
contracts recorded in `mainnet.json`. Factory ownership controls implementation
admission; the owners of created accounts, adapters, oracles, policies and
executors are selected separately when those instances are created.

## Complete setup

1. The existing LL factory owner executes the exported `connectorRegistration`
   call to whitelist the connector implementation. Register the new Merkle adapter
   factory in the protocol's adapter registry.
2. Create a vault/adapter through Curator, then whitelist RecipeCapability for
   that account in the capabilities registry and install it. Configure the
   strategy root, 3F/LL limits and executor roles through Curator. These are
   per-account actions, so the infrastructure script does not preconfigure them.
3. Link the shared `workflowRegistry` contract to the CRE organization using
   its issued ownership proof. Prepare the WASM and per-adapter configuration in
   `merkle-adapter-nav`. The workflow owner is the wrapper registry; the workflow
   name is the lowercase oracle address. The workflow-registry owner proposes the exact issued
   workflow ID/parameters and the oracle owner accepts them. Do not register the
   workflow under the deployer EOA or fabricate an ownership proof.
4. Wait for an accepted `CREOracle.OnReport(..., false)` and a later block before
   funding/allocating. Transaction success alone does not establish acceptance.

CRE activation requires an enabled organization and its on-chain registration
proof. 3F's bridge-facilitator/API enrollment and any issuer onboarding are also
external prerequisites; deploying these contracts cannot grant them.

## Consumers

Curator stores the manifest's `deployment` object in
`deployments/mainnet/merkle.json` and its adapter factory in
`deployments/mainnet/addresses.json`. Backend factory admission lives in
`src/config/deployments.ts`. Curator indexer factory and workflow discovery lives
in `config/addresses.ts`; RFQ executor discovery lives in
`config/recipe-executors.ts`. Use the manifest's `fromBlock` for these new sources
without changing the earlier start block for existing core contracts.

Publish each adapter's inventory in `metadata-mainnet` and pin that commit in
NAV. Mainnet NAV uses its canonical protocol/price catalogue. Its collectors
are a separate deployment: `lens/script/DeployCollectors.s.sol:DeployCollectorsScript`
exports the matching `readLens`/`snapshotLenses` configuration. Set the created
oracle as `submission.receiver`, with `submission.mode=cre`.

`merkle-executor` and vault-solver's Merkle host read executor/recipe/account
bindings from chain and Curator. Configure chain 1, the same Curator backend,
independent durable state directories, and the correct RFQ/3F production API
origins. Populate executors only after their factory registration and permissions
are confirmed. The infrastructure deployment does not start those services.

Consumer setup after receipt verification:

| Consumer                       | Mainnet configuration                                                                                                                                                                                                                               |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Curator UI                     | Chain 1 and the checked-in mainnet deployment files. Its canonical Aave, Morpho, Euler, CoW and issuer catalogues stay in use.                                                                                                                      |
| Curator backend                | `CURATOR_CHAIN_ID=1`, mainnet `RPC_URL`, and the confirmed factory in `src/config/deployments.ts`. Apply its Merkle database migrations.                                                                                                            |
| Curator indexer                | Set the confirmed adapter/account/oracle factories and workflow registry in `config/addresses.ts`, starting at the deployment block. Its mainnet 3F request source already uses the official factory.                                               |
| NAV                            | Deploy matching collectors, prepare the exact `metadata-mainnet` commit with `CHAIN_ID=1`, and activate official CRE delivery to this oracle. Use the mainnet collector deployment profile.                                                         |
| APR service                    | Use mainnet RPC/indexer data, register the adapter as `MERKLE`, and set `MERKLE_METADATA_COMMIT` to the published inventory commit. Missing source/yield evidence remains unavailable.                                                              |
| Merkle executor / vault-solver | Mainnet `chainId: 1`, the same Curator API, confirmed recipe executor addresses and durable state. Enable sends after simulation.                                                                                                                   |
| RFQ backend / indexer          | Use the mainnet deployment. Configure the connector/recipe-executor solver binding and the new `recipeExecutorFactory` plus `fromBlock` in the recipe indexer's deployment configuration. Apply connector/recipe migrations before enabling quotes. |

The exported `deployment` object is consumed by Curator's `deploymentSchema`
and `deploymentFor(1)`. Mainnet runtime/source support
does not prove a funded end-to-end deployment: registry activation, registrations,
metadata publication, permissions, API enrollment and accepted reports must be
verified against the actual deployed addresses before live operation.
