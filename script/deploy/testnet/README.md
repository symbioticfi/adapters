# Standalone testnet environments

This suite extends the bundled core deployment scripts and the current
`DeployMerkleAdapterScript`. It creates the full adapter environment from zero on
local Anvil (chain 31337), or binds a fresh environment to official CRE and 3F
infrastructure on Ethereum Sepolia (chain 11155111). Other chain IDs are rejected
before broadcasting.

**Sepolia replica of the upstream Workflow Registry**

Sepolia deploys a copy of the pinned upstream registry for local acceptance.
Hosted CRE registration stays on mainnet; reports use the official Sepolia
forwarder. The replica is stand-owner-controlled test infrastructure.

The catalog contains **all 49 token account integrations** in
`src/contracts/ll-adapter/tokens-to-redeem`, plus Asseto,
OpenEden and daily Securitize accounts. The actual configurable account
implementations are deployed with local dependencies. The mainnet wrappers
contain fixed mainnet addresses and therefore are represented by their current
base account implementation. Issuer dependencies remain controlled fixtures. Lending uses unmodified, pinned
upstream Aave V3/V4, Euler EVC/EVK, Morpho Blue/Vault V2 and Midnight deployments. Source cooldowns, Midas bounds, the mGLOBAL monthly
cutoff and the native redemption asset are retained. Catalog fixture prices are
explicit synthetic values, not current market quotes.

Seven asset markets cover USDC (6), aUSD (18), tBTC (18), WBTC (8), cbBTC (8), WETH
(18) and USDT (6). USD budgets are converted into native units using fixed testnet
quotes of $3,000/ETH and $60,000/BTC. WETH and both ETH staking models require actual
native ETH backing. Local assets are issuer-controlled testnet assets. On Sepolia,
the USDC market uses the official 3F six-decimal testnet token; the other six market
assets remain fixtures.

Standalone generic ERC-4626 venues, adapters and catalog entries are excluded.
The ERC-4626 base contracts remain available to the named integrations.
Current full-stand and basis manifests use schema version 1. Historical manifests
remain deployment records; existing on-chain fixture bytecode is unaffected.

## Infrastructure-only Sepolia basis

`DeploySepoliaBasisScript` deploys fresh core V2 factories and implementations,
shared Merkle registries/factories, recipe capability and executor factory,
health/liquidity/readiness helpers, Liquid Lane infrastructure and the 3F policy
factory bound to the official Sepolia facility. It reuses the upstream Aave,
Euler and Morpho builders for seven empty denomination venues and deploys all 52
issuer fixture profiles with account factories and pricing routes.

Euler EVaults and Morpho Vault V2s are lending venue primitives. This entrypoint
creates no Symbiotic curator vault, portfolio adapter/account, CRE oracle
instance, account-bound connector/policy, recipe executor, 3F request, workflow,
position, approval or funded token balance. Network/operator registries start
empty. The upstream venues and issuer fixtures retain synthetic test prices.

Use a new manifest path and the same pinned Foundry/compiler as the mainnet
registration helper:

```sh
python3 script/deploy/testnet/upstream/prepare.py
export TESTNET_MANIFEST=script/deploy/testnet/manifests/sepolia-basis.json
forge script script/deploy/testnet/DeploySepoliaBasis.s.sol:DeploySepoliaBasisScript \
  --rpc-url "$TESTNET_RPC_URL" --sender "$TESTNET_OWNER" --isolate \
  --account testnet-deployer --password-file "$HOME/.foundry/testnet-password" \
  --broadcast
```

Keep isolated simulation enabled: each top-level call needs its own transaction
context for gas accounting, including nested Euler and Morpho configuration calls.

The manifest exposes shared factories and registries at the top level, including
`workflowRegistry` for the separate mainnet registration helper. `venues` holds
the seven denomination assets, pricing feeds and protocol market addresses;
`rwas` holds issuer tokens, pricing routes, redemption venues and empty account
factories. `threeFFirstRequest` is captured at `threeFBaselineBlock` before
infrastructure deployment. `vaults` is empty. The full stand's activation,
seeding, syncing and portfolio-export phases require created portfolios and do
not consume this basis manifest.

## Deploy with Foundry

Use Foundry **1.8.5**. `run.sh` selects the installed pinned toolchain and forwards
all remaining arguments directly to `forge script`. It does not sign, submit or
replay transactions itself. Normal Foundry broadcasting submits dependent
transactions in batches; no per-transaction `--slow` wait is added.

Use an encrypted Foundry wallet. Choose a unique manifest and keep the same path,
owner and chain throughout deployment and recovery:

```sh
export TESTNET_RPC_URL="$ETH_RPC_URL_SEPOLIA"
export TESTNET_OWNER="$(cast wallet address --account testnet-deployer --password-file "$HOME/.foundry/testnet-password")"
export TESTNET_MANIFEST=script/deploy/testnet/manifests/sepolia-foundry.json
export TESTNET_SEED_ASSETS=2000
# Match the current Sepolia runtime while keeping the pinned compiler target.
export FOUNDRY_HARDFORK=amsterdam

bash script/deploy/testnet/run.sh deploy \
  --account testnet-deployer --password-file "$HOME/.foundry/testnet-password"
# Complete mainnet registration as described below before activation.
export TESTNET_CRE_ACTIVATION=script/deploy/testnet/manifests/cre-activation.json
export CRE_MAINNET_RPC_URL="$ETH_RPC_URL"
bash script/deploy/testnet/run.sh activate \
  --account testnet-deployer --password-file "$HOME/.foundry/testnet-password"
```

Deploy prepares upstream projects with their pinned compiler settings before
invoking `DeployRealisticTestnetScript`. Solidity checks official infrastructure,
writes the provisional manifest and refuses to overwrite an existing manifest.
The replica uses the stand owner as its local proof signer. Activation verifies
the real mainnet registration records before preparing Sepolia transactions,
then uses the loaded Foundry wallet to sign a separate Sepolia-domain proof.
Official organization signatures are used only for actual mainnet registration.

The default $2,000 seed budget per market requires about **2.68 ETH** of actual
WETH/staking backing, plus deployment gas. Lending anti-inflation deposits scale
with that budget. Seed checks accepted initial workflows/reports and the backing budget before
creating any funding transactions, and rejects an already seeded vault.

For Anvil use `TESTNET_RPC_URL=http://127.0.0.1:8545` and start it with
`anvil --hardfork osaka --enable-tx-gas-limit --gas-limit 60000000`. Keep normal
contract-size and transaction gas limits. Protocol deployments support local
chain 31337 and Sepolia 11155111.

## Publish NAV, seed and validate

Export public consumer configuration with an exact metadata commit:

```sh
python3 script/deploy/testnet/export_config.py "$TESTNET_MANIFEST" \
  --metadata-commit "$METADATA_COMMIT" --out /srv/merkle-portfolios
```

Each adapter folder contains the frontend `deployment.json`, ordinary-reader
`portfolio.json` and independent `metadata.json`. Publish inventory folders at the
specified commit in `metadata-sepolia` before using the UI; an export is not a
metadata publication. Update the frontend's checked-in chain deployment configuration
from the generated public profile.
Exports are strict JSON. In the NAV portfolio, `aaveV3` maps metadata deployment
IDs such as `core` to `{pool, provider}`, `aaveV4` lists spoke addresses, price
feeds contain `{proxy, heartbeat}`, and `rwa.products` maps product IDs to issuer
configuration (empty for this export). Display labels stay in the frontend
`suggestions` section. Human-edited NAV profiles can use JSONC address comments.
The configured `threeF.firstRequest` comes from the captured `threeFFirstRequest`
and always starts the factory scan there; frontend `fromBlock` remains the event
discovery block. The portfolio has no block-dependent scan baseline or request cap.

Deploy the normal NAV collectors. With official CRE, embed the exported
`portfolio.json` as `deployment` and the independent `metadata.json` as `metadata`
in each workflow config, set `submission.mode=cre` and its oracle receiver, and
use the hosted Sepolia workflow described in `merkle-adapter-nav/docs/receiver-integration.md`.
No deployment script calculates or fabricates a NAV report.

Wait for all seven initial reports to be accepted and visible in a later block.
Then run these independent Foundry phases with the same wallet arguments:

```sh
bash script/deploy/testnet/run.sh sync --account testnet-deployer --password-file "$HOME/.foundry/testnet-password"
bash script/deploy/testnet/run.sh seed --account testnet-deployer --password-file "$HOME/.foundry/testnet-password"
# Wait for a new accepted report after funding.
bash script/deploy/testnet/run.sh sync --account testnet-deployer --password-file "$HOME/.foundry/testnet-password"
bash script/deploy/testnet/run.sh validate
```

Sync verifies every accepted workflow/report before settling liquidity. Later
phases validate manifest chain, owner and upstream pin identity. Validation is
read-only. The signed native broadcast files remain the transaction authority.

## Interrupted broadcasts

Stop the previous process before resuming. Repeat the **same phase**, manifest,
wallet and RPC with Foundry's native `--resume`:

```sh
bash script/deploy/testnet/run.sh deploy --resume \
  --account testnet-deployer --password-file "$HOME/.foundry/testnet-password"
```

Resume first checks the unchanged manifest against its saved digest, current
upstream pins, wallet and chain through a read-only Foundry entry point. It then
uses the persisted transaction plan instead of generating new CREATE addresses. The launcher skips upstream preparation on resume. It isolates native
broadcast/cache recovery files by the manifest path and reuses compiler metadata.
Keep both `broadcast/testnet/` and `cache/testnet/`, including `manifest.keccak256`
and sensitive native recovery files. They can contain RPC credentials; do not publish them. Do not
change the spelling of the manifest path or use the wallet for other transactions
while a phase is incomplete. A mined revert requires inspection, not a fresh run
of the non-idempotent deployment or seed. The manifest written during simulation
is provisional until every planned receipt and deployed address is verified.

There is one broadcast mode: native Foundry. No separate fast mode, custom
fork-replay planner, artifact conversion or Python broadcast engine exists.

## Official CRE and 3F

`SepoliaInfrastructure` checks the official forwarder, official 3F bundle and
exact pinned upstream bytecode of the registry replica.

`CREOracle.onReport` requires the report owner to equal its local
`CREWorkflowRegistry`. The scripts give that Sepolia wrapper and a test-only
mainnet registration helper the same address: an identical CREATE2 constructor
creates its first child with chain-specific code. Its salt includes the stand
owner and replica address, isolating fresh stands and production. Both chains
need the standard deterministic deployer at
`0x4e59b44847b379578588920cA78FbF26c0B4956C`.

The helper forwards owner-authorized calldata only to the official mainnet
registry and owns no vault or portfolio. All added support code lives under
`script/`; `src/` stays unchanged. Deploying this helper costs real mainnet ETH
and is an explicit, separate step; `run.sh deploy` only broadcasts on Sepolia.
After confirming the Sepolia deployment, use the identical revision/compiler:

```sh
export CRE_MAINNET_RPC_URL="$ETH_RPC_URL"
export CRE_SEPOLIA_RPC_URL="$TESTNET_RPC_URL"
export WORKFLOW_OWNER="$(jq -r '.workflowRegistry // .markets[0].workflowRegistry' "$TESTNET_MANIFEST")"

forge script script/deploy/testnet/DeploySepoliaCRERegistration.s.sol:DeploySepoliaCRERegistrationScript \
  --rpc-url "$CRE_MAINNET_RPC_URL" --sender "$TESTNET_OWNER" \
  --account testnet-deployer --password-file "$HOME/.foundry/testnet-password" \
  --broadcast
```

The script reads `TESTNET_MANIFEST` and requires its resulting owner to match
the top-level `workflowRegistry` (or `markets[0].workflowRegistry` for a full stand).
It does not link or register anything. Set that
shared address as `account.workflow-owner-address` in the stand's CRE
`project.yaml`. Configure both `ethereum-mainnet` / `${CRE_MAINNET_RPC_URL}`
and `ethereum-testnet-sepolia` / `${CRE_SEPOLIA_RPC_URL}` RPCs. Each workflow uses
`deployment-registry: "onchain:ethereum-mainnet"` and the lowercase Sepolia oracle
address as `workflow-name`. Keep chain 11155111 and its receiver in the NAV
configuration. Keep the production mainnet stand's owner and files separate.
See [CRE deployment](https://docs.chain.link/cre/guides/operations/deploying-workflows).

From the authenticated CRE project, obtain the official unsigned transactions:

```sh
cre account link-key --target sepolia-settings --unsigned
cre workflow deploy ./nav --target sepolia-settings --unsigned
```

For each CLI-generated transaction, verify that its destination is the official
mainnet registry `0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5`. Forward its calldata
through the helper using the stand owner's encrypted wallet, linking first,
then registering each workflow:

```sh
cast send "$WORKFLOW_OWNER" 'execute(bytes)' "$CRE_UNSIGNED_CALLDATA" \
  --rpc-url "$CRE_MAINNET_RPC_URL" \
  --account testnet-deployer --password-file "$HOME/.foundry/testnet-password"
```

`cre account unlink-key --unsigned` provides cleanup calldata for the same
helper. Unlinking deletes that owner's registered workflows. Keep the helper
exclusive to this stand.

Set `TESTNET_CRE_ACTIVATION` to this JSON, with one entry per manifest market
in order. Copy the real mainnet registration IDs and metadata. No organization
link proof or signature belongs in this file:

```json
{
  "chainId": 11155111,
  "chainlinkRegistry": "0x<Sepolia replica address>",
  "owner": "0x<manifest owner>",
  "workflowRegistry": "0x<shared wrapper/helper address>",
  "entries": [
    {
      "oracle": "0x<market creOracle>",
      "workflowId": "0x<registered bytes32 workflow ID>",
      "tag": "default",
      "status": 0,
      "donFamily": "<registered DON family>",
      "binaryUrl": "<registered workflow binary URL>",
      "configUrl": "<registered configuration URL>",
      "attributes": "0x"
    }
  ]
}
```

Store the file inside the repository for Foundry access. `run.sh activate`
reads the official mainnet registry through `CRE_MAINNET_RPC_URL`, rejects
mismatched IDs/owners/metadata, then performs the unchanged Sepolia
proposal/acceptance flow. Exact completed acceptance can resume. The replica is
not a cross-chain light client: this mainnet comparison is a script check.
Replica acceptance does not establish CRE delivery; wait for actual accepted
reports and a following block before seeding.

Official 3F enrollment, auctions and settlement require the actual Bridge
Facilitator authorization/API. `PrepareSepoliaThreeFOfferScript` prepares the
factory-checked native EIP-712 payload for an actual request; it does not fabricate
authorization or settlement. `SeedThreeFTestnetScript` is local fixture tooling.

## Manual action batches

Deployment finishes after validation. Run one finite action batch afterward:

```sh
python3 script/deploy/testnet/actions.py \
  --rpc-url http://127.0.0.1:8545 \
  --account local-testnet \
  --password-file /absolute/path/to/password-file \
  --manifest script/deploy/testnet/manifests/local.json \
  --seed 20261008
```

Repeat the same command to execute the next independently shuffled batch. Each
invocation exits when its requested work finishes; `--batches 2` explicitly runs
two batches. The journal advances its batch number, so repeating the command
varies action order, amounts and bounded fixture prices with a reproducible seed.

All 52 profiles and seven markets are visited. Investor actions use actual Merkle
account custody: ERC1271-signed CoW RWA purchases with real solver inventory,
LL token transfers and swaps returning cash to the account, funded lending
deposits, collateral, borrows, bounded leverage loops,
repayments and withdrawals, and 3F PT/YT investments and matured burns. Production
RecipeExecutor programs read balances and debt during atomic execution and bind
those actual values into subsequent actions. The curator publishes exact action
permissions and programs, then restores the deployment root and base recipe.
Native issuer administration and funded reward delivery use their actual owner
or solver roles; their investor protocol calls originate from the account.

Lending loops skip an account's occupied Aave V3, Euler/Morpho credit-vault,
Morpho Blue or Midnight debt market. The corresponding `families` count is zero
and `occupiedDebt` is true at the same index; other families continue. The order
is core vault, Aave V3, Euler, Morpho vault, Blue, Midnight and Aave V4.
Occupied positions retain their debt, shares, collateral and existing approvals;
Midnight skips before replacing its lender offer, including after the original
market matures. Fresh collateral funding covers only available families. Atomic
zero-debt checks remain in every selected borrowing program.

Each batch refreshes all native prices and existing LL redemption queues before
reading aggregate capacity. Queues rotate batches of at most eight, and protocols
with a single outstanding request receive new inventory after that request clears.
Some actions wait for actual cooldowns, cutoffs, cash or collateral. ACRED buys
pause after its source-defined final cutoff, preserving existing liabilities.
Owner collateral left by the seed phase funds subsequent account strategies.
WETH and staking positions continue to require actual native ETH backing.

On Anvil, add `--advance-local-time 86400` to advance one day before each batch,
or `604800` to exercise seven-day maturities. Public chains use real timestamps.
The default `local-actions.json` journal beside the manifest records cursors,
account-owned 3F request history, waiting reasons and canonical successful RPC
receipts for every broadcast owner nonce. NAV reports include the added 3F
positions. An interrupted task or partial broadcast requires receipt reconciliation
before repeating the command. Sources, dependencies, catalog and compiler
settings are pinned in the journal to prevent resuming with different programs.
Broadcasts use a 200% gas estimate for ordinary calls. Portfolio recipes,
Liquid Lane capacity reads and core reward/conversion calls use explicit
16,000,000 gas budgets below Osaka's transaction cap. These avoid an estimate's
margin exceeding the cap; fees still use the gas actually consumed.
The market batch funds owner services and fills its CoW order within the production
converter's 30-minute expiry cap before broadcasting the longer lending recipe programs.

Sepolia action batches require completed official CRE activation and real accepted
reports. They synchronize official reports and finalize genuinely withdrawable
3F positions; new official investment requires the native auction authorization.
Local issuer authorization and synthetic report delivery are limited to chain 31337.
Issuer endpoints remain controlled fixtures; lending endpoints use the pinned
upstream implementations listed below.

After completing the Sepolia activation, funding and report phases below, use
the same finite command with the Sepolia RPC and saved manifest:

```sh
python3 script/deploy/testnet/actions.py \
  --rpc-url "$ETH_RPC_URL_SEPOLIA" \
  --account sepolia-testnet \
  --password-file /absolute/path/to/password-file \
  --manifest script/deploy/testnet/manifests/sepolia.json \
  --seed 20261008
```

To invest from market zero's Merkle account in a genuinely authorized official
3F request, set the request and its exact native principal/yield authorization
before invoking that command. Other markets continue their own actions:

```sh
export TESTNET_MERKLE_THREEF_REQUEST_0="$OFFICIAL_THREE_F_REQUEST"
export TESTNET_MERKLE_THREEF_AMOUNT_0=2000000
export TESTNET_MERKLE_THREEF_YIELD_0=20000
```

Clear these variables after the authorization has been consumed. A later batch
tracks the account's recorded position and burns it when the official request
permits withdrawal. Indices match the manifest's `markets` array.

Action scripts require current issuer queue counters and the ERC1271 settlement
fixture. Deploy a fresh current environment for older fixtures. Older metadata
can be exported separately with compact market parameters and authorized recipe
bytes; preserve the non-idempotent funding phase.

## Interrupted Merkle programs

A Merkle activity publishes and accepts a temporary root, grants exact action
roles, installs a temporary recipe, executes it, then restores the manifest's
base root and recipe. Each broadcast call is a separate transaction. An
interruption can therefore leave authorization partly changed even when the
account's economic recipe never executed.

Stop other processes using this owner. Preserve the manifest, action journal,
phase log and Foundry `broadcast/` artifacts. Reconcile every owner nonce since
that phase's `startNonce` against canonical RPC receipts, including failed
receipts and any pending transaction. Check the receipt's transaction hash,
sender, nonce, block hash and status against the current chain. A simulation
result or `run-latest.json` receipt alone does not establish canonical execution.
Wait for or explicitly resolve pending transactions before publishing repair
transactions. Separate successful economic calls from failed or unsubmitted
calls; do not replay a purchase, mint, withdrawal, borrow or funding transfer
merely because the script did not finish. Keep the phase marked
`needs-reconciliation` until its actual position, approvals, signatures and
request history are accounted for. Record the repaired authorization's receipts
separately and preserve the failed phase's evidence. This helper neither edits
the action journal nor changes its source-identity checkpoint.

After reconciliation, restore market zero's base root and recipe from the
**existing** manifest. Omit `--broadcast --skip-simulation` for a read-only simulation first:

```sh
TESTNET_MANIFEST=script/deploy/testnet/manifests/sepolia.json \
TESTNET_ACTIVITY_MARKET=0 \
/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.5/forge script \
  script/deploy/testnet/RecoverMerkleProgram.s.sol:RecoverMerkleProgramScript \
  --rpc-url "$TESTNET_RPC_URL" \
  --account testnet-deployer \
  --password-file "$HOME/.foundry/testnet-password" \
  --broadcast --slow --skip-simulation --no-isolate
```

These commands use the `testnet-deployer` owner keystore and Sepolia manifest.
`--skip-simulation --slow` estimates each broadcast transaction through the RPC
under Sepolia's active gas schedule, matching the deployment helper.
For local chain 31337, select its existing manifest and owner account instead.
Indices match the manifest's `markets` array. The script supports only local
31337 and Sepolia, validates account/registry/executor ownership, executor caller
and account binding, and the account's registry binding before repair. It does
not require the current root or recipe to match the base configuration. It
publishes the base root, accepts it and restores the exact base recipe only when
each field differs; repeating it safely performs the remaining writes. Check
canonical repair receipts and the account's `root()`, registry `roots(account)`
and executor `recipeHash()` before resuming activity.

Authorization restoration does not undo economic state or revoke token approvals
and signed orders. Before reusing the account, inspect any successful approval
or signing calls from the interrupted program. CoW activity may leave an ERC1271
order digest approved and an account-to-relayer allowance. Revoke the exact digest
before clearing its associated allowance. Use the digest and UID from the saved
program/logs, and reconcile the settlement's `filledAmount(orderUid)` and actual
balances before deciding whether the order filled.

Cleanup entrypoints read the same manifest and market variables as `run()`,
validate the same authority, and finish with the base root and recipe restored.
They operate only on the permission explicitly selected by the operator:

```sh
export TESTNET_MANIFEST=script/deploy/testnet/manifests/sepolia.json
export TESTNET_ACTIVITY_MARKET=0
TESTNET_RECOVERY_FORGE=/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.5/forge

# Revoke one exact account ERC1271 digest through its owner; repeating is safe.
"$TESTNET_RECOVERY_FORGE" script \
  script/deploy/testnet/RecoverMerkleProgram.s.sol:RecoverMerkleProgramScript \
  --sig 'revokeSignature(bytes32)' "$ORDER_DIGEST" \
  --rpc-url "$TESTNET_RPC_URL" --account testnet-deployer \
  --password-file "$HOME/.foundry/testnet-password" --broadcast --slow --skip-simulation --no-isolate

# Clear one exact account-to-spender token allowance, with an atomic allowance==0 check.
"$TESTNET_RECOVERY_FORGE" script \
  script/deploy/testnet/RecoverMerkleProgram.s.sol:RecoverMerkleProgramScript \
  --sig 'clearApproval(address,address)' "$TOKEN" "$SPENDER" \
  --rpc-url "$TESTNET_RPC_URL" --account testnet-deployer \
  --password-file "$HOME/.foundry/testnet-password" --broadcast --slow --skip-simulation --no-isolate

# Disable the manifest market's testnet Midnight lender offer and its loan-token allowance.
"$TESTNET_RECOVERY_FORGE" script \
  script/deploy/testnet/RecoverMerkleProgram.s.sol:RecoverMerkleProgramScript \
  --sig 'clearMidnightOffer()' \
  --rpc-url "$TESTNET_RPC_URL" --account testnet-deployer \
  --password-file "$HOME/.foundry/testnet-password" --broadcast --slow --skip-simulation --no-isolate
```

Omit `--broadcast --skip-simulation` to simulate each selected cleanup before sending it. Approval
cleanup installs a temporary exact `approve(spender, 0)` program, executes it from
account custody, verifies the resulting allowance is zero, and restores base
authorization. A repeated call skips an already-zero allowance. It neither spends
funds nor clears any other spender. Inspect both asset and collateral allowances;
invoke it separately for each proven residual pair. An owner EOA's own `approve`
does not clear the account's allowance. Owner-to-settlement inventory approvals
belong to the owner and can be cleared by its direct token `approve(settlement, 0)`.

Signature cleanup calls the account's owner-only `revokeSignature(digest)` and
skips an already-revoked digest. That revocation can also be sent directly with
`cast send "$MERKLE_ACCOUNT" 'revokeSignature(bytes32)' "$ORDER_DIGEST"` and the
same RPC/keystore options. It does not change another signed order's state.

Midnight cleanup validates the manifest lender's ownership and market binding,
then calls its existing owner-only `approveOffer` with a disabled offer: zero
taker, zero expiry and zero asset/unit limits. It replaces the old ratifier hash
and clears the lender-to-Midnight loan-token allowance, verifying both changes.
Existing lender credit/cash and borrower debt/collateral remain intact. Use it
only after reconciling the exact interrupted offer and stopping pending takers.
The account's ERC20 permissions are cleared separately with `clearApproval`.

Every cleanup broadcast can itself be interrupted between transactions. Preserve
its receipts, run the base authorization repair again, then repeat only the
selected idempotent cleanup. Temporary leaf roles remain installed but cannot
authorize an action absent from the restored base root. Keep 3F request history
and existing positions intact; permission cleanup does not repay or withdraw them.
The journal's final disposition remains an explicit operator action. There is
no automatic recovery runner.

## Verification

```sh
forge test --threads 1 --no-match-contract '.*(Mainnet|Benchmark).*'
python3 -m unittest discover -s script/deploy/testnet -p 'test_*.py'
python3 -m unittest discover -s script/deploy/testnet/upstream -p 'test_*.py'
TESTNET_FOUNDRY_INTEGRATION=1 python3 -m unittest discover \
  -s script/deploy/testnet -p test_foundry_broadcast.py
forge fmt --check
```

The native integration test uses temporary encrypted wallets and disposable local
nodes. It checks batched dependent transactions, successful receipts, CREATE
identity and interrupted native resume. The randomized `actions.py` harness keeps
its own coverage/receipt journal; it is test activity tooling, not deployment.

## Fidelity and assumptions

The table distinguishes actual upstream contracts from controlled fixture services.
Official Sepolia CRE relies on its external organization and forwarder; explicit
self-hosting uses owner-authorized report delivery.

| Component                                               | Behavior exercised                                                                                                   | Limits                                                                                                            |
| ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Symbiotic core, adapters and Merkle infrastructure      | Current repository contracts, real factories/proxies, roles, roots, capability recipes, policy and report accounting | No production deployment claim                                                                                    |
| Chainlink registry / forwarder                          | Source-pinned contracts, ownership signatures, workflow proposal/acceptance and routing                              | Owner routing simulates delivery; no DON consensus, CRE worker or real offchain workflow is run                   |
| Morpho Blue / Midnight                                  | Pinned upstream engines, native shares, debt, interest, liquidation and offer/ratifier semantics                     | Local fixed-rate IRM, prices and a contract lender                                                                |
| Euler                                                   | Upstream EVC, EVault factory/modules, XOR accounts, collateral/controllers and accruing debt                         | Controlled prices and owner-configured risk parameters                                                            |
| Morpho Vault V2                                         | Upstream vault/factory, Blue allocation adapter, real caps and allocation accounting                                 | Supply/redemption only; borrowing belongs to Blue; `maxWithdraw`/`maxDeposit` return zero by upstream design      |
| Aave V3                                                 | Upstream multi-reserve pool, configurator, ACL, data provider, aTokens and variable debt                             | Synthetic prices and owner-configured reserve risk parameters                                                     |
| Aave V4                                                 | Upstream Hub/Spoke, reserve shares, debt, interest and access manager                                                | Owner-configured reserves and risk parameters                                                                     |
| Midas                                                   | Native request tuples, fees, token custody, locked rates, issuer approval/rejection, monthly account cutoff          | Owner issuer settlement replaces live offchain valuation                                                          |
| Centrifuge / ERC7540                                    | Pending and claimable requests, real backing, delayed fulfillment and claims                                         | One aggregated pending request per controller                                                                     |
| Figure, GAIB, 3Jane, Theo, Noon                         | Native layered tokens, queues, loss-aware NAV, cooldown/window and pending-slot semantics                            | Explicit synthetic credit/cash administration                                                                     |
| Makina / Pareto / InfiniFi                              | Receipt NFTs, epoch queues, claims, losses and liquidity retries through actual accounts                             | Synthetic administrators and fixed fixture parameters                                                             |
| Securitize, Superstate, DigiFT, Asseto, OpenEden, Spiko | Native token/manager interfaces, issuer receipts, pricing cutoffs, fees/statuses/cancellation and funded payouts     | Owner-operated issuer backend; no fiat transfer/KYC vendor                                                        |
| Lido / EtherFi                                          | ETH-backed denominations, real wrapped shares, delayed queues, NFT/checkpoint claims, loss and instant-path limits   | Operator custody replaces validators/proofs; no underlying rebase; EtherFi pool/NFT share an endpoint             |
| CoW                                                     | Canonical GPv2 EIP712 domain, presignature and ERC1271 UIDs, bounded partial fills and real relayer transfers        | ERC20 sell orders only; no auction, Balancer balances or EOA signing schemes                                      |
| Merkl                                                   | Cumulative root-based funded reward transfers and replay accounting                                                  | Local owner-published roots and owner/user authorization; no dispute window or custom recipient/operator registry |

The NAV producer reads a pinned completed block and adds the adapter's
`lockedLiquidity()` to the configured Merkle account's net cash, supplied shares,
known collateral/debt, 3F position and held RWA inventory. Untracked adapter cash,
including direct donations and any NAV-cap surplus, is excluded and remains
inaccessible; `pull(0)` does not register it. Native issuer redemptions belong in the deployed Liquid Lane accounts;
those accounts' own production logic values their pending receivables. If adding
new direct redemption actions to the Merkle account, extend the NAV producer to
include their pending claims before publishing reports.

Upstream source, recursive dependency identities and native build commands are pinned in
`upstream/pins.json`. `upstream/prepare.py` builds unmodified repositories and records
creation-artifact hashes; the script loader rejects changed pins, artifacts or unresolved
library links. `upstreamPins` binds fresh manifests to that descriptor.

The ordinary Merkle NAV profile admits Aave V3/V4, Euler, Blue/Vault V2, explicit
wallet assets and official factory-verified Sepolia 3F. Midnight and the controlled
issuer/reward fixtures lack normal NAV admission; they remain explicit separate
activity coverage. The exporter rejects synthetic 3F request inventory. A test
fixture's matching token name or selector does not establish production valuation.

Run these phases promptly on a fresh chain. Timestamped prices intentionally become
stale; synthetic Midas/issuer feeds need owner publication when testing later dates.
The seed refreshes DUSD accounting and both InfiniFi NAV rounds after funding.

### Liquid Lane factory versions

The same Liquid Lane `AdapterFactory` registers both implementations: version 1 is
`LiquidLaneAdapter`, version 2 is `LiquidLaneConnector`. The deployment whitelists
them in that order and creates connectors with `create(2, owner, abi.encode(account,
outputAsset))`. `connectorFactory` in the deployment manifest is this shared
factory, also used by the RFQ Reactor. The connector's EIP-712 domain remains
`LiquidLaneConnector`, version `1`; domain versions and factory versions are
independent.

## Production compatibility boundary

| Integration     | Contracts and consumer path                                                                                                                           |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| Aave V3 / V4    | Pinned upstream shared multi-reserve pools/spokes; ordinary supply, collateral, debt and interest getters.                                            |
| Euler           | Pinned EVC, factory, EVault modules and IRM; actual controller/collateral checks and owned XOR subaccounts.                                           |
| Morpho Blue     | Pinned upstream deployment, real market parameters, interest and liquidity constraints.                                                               |
| Morpho Vault V2 | Pinned factory, actual Blue allocation adapter and caps. The vault supports deposit/withdrawal; debt belongs to Blue.                                 |
| Midnight        | Pinned upstream lending engine and real activity. Held Midnight positions have no ordinary NAV reader and are not admitted by the exported inventory. |
| 3F on Sepolia   | Official request factory, facility, whitelist and funding token. Real enrollment/settlement still requires 3F authorization.                          |
| Tokens / prices | Controlled fixture assets and standard-interface feeds with synthetic prices.                                                                         |
| Issuer catalog  | Funded fixtures for Liquid Lane account exercises. They are not advertised as production NAV issuer routes.                                           |

The Merkle seed uses the account/recipe execution path. Standalone adapter and
issuer catalog positions are held by their respective accounts, not implicitly
inventoried as Merkle holdings. Adding issuer or Midnight exposure to a Merkle
strategy requires admitting its real reader before publishing complete NAV.
A profile cannot hide synthetic 3F request rights: the exporter rejects that
combination. Fresh Anvil deployments can omit synthetic requests or use an
explicit Sepolia fork with the official bundle.

Native upstream build configuration is recorded in `upstream/pins.json`;
`upstream/prepare.py` verifies source and recursive submodule identities. No
compiler substitution, edited engine source or relaxed contract-size limit is
part of the deployment.

### Populated ordinary-reader acceptance

On a disposable Sepolia fork, after seed, run
`test/deploy/testnet/acceptance/OpenPositions.s.sol:OpenPositions` with the same
manifest and owner. This test fixture leaves USDC debt and 18-decimal collateral
in Aave V3/V4, Euler XOR subaccount 1 and Morpho Blue, plus Vault V2 shares.
It restores the account’s original permission root and executor recipe.
Include Euler offset 1 in that account’s independent inventory metadata after
opening it. Copy `cache/production-acceptance/witness.json` alongside the NAV
daemon config; its test-only Blue witness uses the upstream periphery math.
Advance finality, then stop mining while comparing Go and frontend reports.
The opt-in NAV acceptance test requires these nonzero families and compares
native quantities against upstream getters at the pinned block. The frontend
acceptance test compares those native quantities and aggregate NAV at that same
block. Neither acceptance probe publishes an oracle report.
