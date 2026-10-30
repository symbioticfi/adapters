# Mainnet Merkle deployment

`DeployMerkleMainnetScript` deploys the adapter/account/oracle factories and
registries, RecipeCapability, RecipeExecutor factory, claim/health/liquidity
helpers, a 3F policy factory, and a Liquid Lane connector implementation.
It uses the existing mainnet vault and lending/issuer deployments. It does not
deploy test tokens, markets, a replacement 3F factory, or a local CRE forwarder.

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

## Plan and broadcast

Use an existing registered VaultV2. Set the authority and oracle-limit variables
documented in `DeployMerkleAdapterScript`; limits are raw contract units, not
percentages. Select the existing Liquid Lane factory, reactor and protocol signer for
the intended deployment. The connector must be registered in that same factory
because Liquid Lane checks factory membership. The protocol signer can be an
EOA or an ERC-1271 contract; it is the RFQ backend's countersigning identity.

```sh
export MERKLE_VAULT_FACTORY=0xAEb6bdd95c502390db8f52c8909F703E9Af6a346
export MERKLE_VAULT=0x...
export MERKLE_PROVIDER=0x...
export MERKLE_CURATOR=0x...
export MERKLE_ADMIN=0x...
export MERKLE_ORACLE_ADMIN=0x...
export MERKLE_ORACLE_GUARD=0x...
export MERKLE_ORACLE_LIMITS=0x...
export MERKLE_MAX_ORACLE_GROWTH=...
export MERKLE_MAX_ORACLE_LOSS=...
export MERKLE_ORACLE_TOLERANCE=...
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

## Complete setup

1. The existing LL factory owner executes the exported `connectorRegistration`
   call. The provider executes `capabilityRegistration`; the account owner then
   installs that capability through Curator. The script deliberately does not
   impersonate either owner or grant strategy execution roles.
2. Whitelist/add the adapter in VaultV2 through the existing protocol and curator
   flows. Create and accept its strategy root, configure 3F/LL limits in Operate,
   and give each executor only its required leaf roles. The 3F factory creates
   the actual requests; there are no request-specific deployment permissions.
3. Link the deployed `workflowRegistry` contract to the CRE organization using
   its issued ownership proof. Prepare the WASM and per-adapter configuration in
   `merkle-adapter-nav`. The workflow owner is the wrapper registry; the workflow
   name is the lowercase oracle address. The provider proposes the exact issued
   workflow ID/parameters and the oracle owner accepts them. Do not register the
   workflow under the deployer EOA or fabricate an ownership proof.
4. Wait for an accepted `CREOracle.OnReport(..., false)` and a later block before
   funding/allocating. Transaction success alone does not establish acceptance.

CRE activation requires an enabled organization and its on-chain registration
proof. 3F's bridge-facilitator/API enrollment and any issuer onboarding are also
external prerequisites; deploying these contracts cannot grant them.

## Consumers

The manifest's `deployment` object is accepted directly by Curator's
`VITE_MERKLE_DEPLOYMENT_OVERRIDE`:

```sh
export VITE_MERKLE_DEPLOYMENT_OVERRIDE="$(jq -c .deployment "$MERKLE_MANIFEST")"
```

Keep frontend/indexer/backend on chain **1**, using the same RPC and confirmed
adapter factory. Set backend `MERKLE_ADAPTER_FACTORY_ADDRESS` to
`.deployment.merkleAdapterFactory`. Configure the indexer from the confirmed
deployment block, publish the adapter's inventory in `metadata-mainnet`, and pin
that exact commit in NAV. Mainnet NAV uses its canonical protocol/price catalogue;
do not pass the testnet `portfolio` override. Deploy its normal collectors and
set the oracle as `submission.receiver`, with `submission.mode=cre`.
NAV's `lens/script/DeployCollectors.s.sol:DeployCollectorsScript` deploys the
complete collector set in one Foundry plan and exports the matching
`readLens`/`snapshotLenses` configuration.

`merkle-executor` and vault-solver's Merkle host read executor/recipe/account
bindings from chain and Curator. Configure chain 1, the same Curator backend,
independent durable state directories, and the correct RFQ/3F production API
origins. Populate executors only after their factory registration and permissions
are confirmed. The adapter deployment does not start those services.

Consumer setup after receipt verification:

| Consumer                       | Mainnet configuration                                                                                                                                                                                                                               |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Curator UI                     | Chain 1 and the exported `deployment` override. Its canonical Aave, Morpho, Euler, CoW and issuer catalogues stay in use.                                                                                                                           |
| Curator backend                | `CURATOR_CHAIN_ID=1`, mainnet `RPC_URL`, and the confirmed `MERKLE_ADAPTER_FACTORY_ADDRESS`. Apply its Merkle database migrations.                                                                                                                  |
| Curator indexer                | Register the confirmed adapter, account, oracle and workflow registry emitters in `config/indexed-event-sources.json`, starting at the deployment block. Its mainnet 3F request source already uses the official factory.                           |
| NAV                            | Deploy matching collectors, prepare the exact `metadata-mainnet` commit with `CHAIN_ID=1`, and activate official CRE delivery to this oracle. No testnet deployment override.                                                                       |
| APR service                    | Use mainnet RPC/indexer data, register the adapter as `MERKLE`, and set `MERKLE_METADATA_COMMIT` to the published inventory commit. Missing source/yield evidence remains unavailable.                                                              |
| Merkle executor / vault-solver | Mainnet `chainId: 1`, the same Curator API, confirmed recipe executor addresses and durable state. Enable sends after simulation.                                                                                                                   |
| RFQ backend / indexer          | Use the mainnet deployment. Configure the connector/recipe-executor solver binding and the new `recipeExecutorFactory` plus `fromBlock` in the recipe indexer's deployment configuration. Apply connector/recipe migrations before enabling quotes. |

The exported profile was checked against Curator's strict
`deploymentOverrideSchema` and `deploymentFor(1)`. Mainnet runtime/source support
does not prove a funded end-to-end deployment: registry activation, registrations,
metadata publication, permissions, API enrollment and accepted reports must be
verified against the actual deployed addresses before live operation.
