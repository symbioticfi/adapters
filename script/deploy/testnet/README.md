# Standalone testnet environments

This suite extends the bundled core deployment scripts and the current
`DeployMerkleAdapterScript`. It creates the full adapter environment from zero on
local Anvil (chain 31337), or binds a fresh environment to official CRE and 3F
infrastructure on Ethereum Sepolia (chain 11155111). Other chain IDs are rejected
before broadcasting.

Sepolia also supports `--oracle-mode self-hosted`: a source-pinned workflow
registry and authenticated Keystone forwarder owned by the deployment owner,
with reports published by the separate `chainlink-nav` daemon. Official 3F
contracts and USDC remain the same in both oracle modes.

The catalog contains **all 49 token account integrations** in
`src/contracts/ll-adapter/tokens-to-redeem`, plus generic ERC4626, Asseto,
OpenEden and daily Securitize accounts. The actual configurable account
implementations are deployed with local dependencies. The mainnet wrappers
contain fixed mainnet addresses and therefore are represented by their current
base account implementation. Issuer and lending dependencies remain funded local
models in both profiles. Source cooldowns, Midas bounds, the mGLOBAL monthly
cutoff and the native redemption asset are retained. Catalog fixture prices are
explicit synthetic values, not current market quotes.

Seven asset markets cover USDC (6), aUSD (18), tBTC (18), WBTC (8), cbBTC (8), WETH
(18) and USDT (6). USD budgets are converted into native units using fixed testnet
quotes of $3,000/ETH and $60,000/BTC. WETH and both ETH staking models require actual
native ETH backing. Local assets are issuer-controlled testnet assets. On Sepolia,
the USDC market uses the official 3F six-decimal testnet token; the other six market
assets remain fixtures.

## Self-hosted Sepolia oracle

Use this mode to run the full environment with your own NAV publisher. The
default remains `official-cre`; select self-hosting explicitly for a new
deployment:

```sh
python3 script/deploy/testnet/bootstrap.py \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --account sepolia-owner \
  --password-file /absolute/path/to/owner-password \
  --oracle-mode self-hosted \
  --seed-assets 2000 \
  --manifest script/deploy/testnet/manifests/self-hosted-sepolia.json
```

The bootstrap deploys the complete environment, authorizes the owner as report
publisher, signs ownership proofs for the new registry on chain 11155111, and
accepts each workflow. To authorize a dedicated daemon wallet instead, supply
`--report-publisher ADDRESS`; the owner still deploys and signs ownership proofs.
The full catalog seed needs enough inventory to meet each issuer's minimum;
small budgets such as `100` produce less than OpenEden's one-share minimum.
The forwarder accepts direct `route` calls only from that publisher (and its
own authenticated `report` entry point). No CRE tenant activation file is used.

The helper then exports the manifest and stops before funding. In
`symbioticfi/merkle-adapter-nav`, deploy the native testnet snapshot collector and run
the NAV daemon against this manifest:

```sh
forge create --root lens contracts/TestnetSnapshot.sol:TestnetSnapshot \
  --rpc-url "$SEPOLIA_RPC_URL" --account sepolia-owner \
  --password-file /absolute/path/to/owner-password --broadcast
go build -o build/navd ./cmd/navd
./build/navd -config navd.json -keystore /absolute/path/to/publisher-keystore \
  -password-file /absolute/path/to/publisher-password
```

The daemon config contains `rpcURL`, the absolute path of `manifest`, the actual
deployed collector address in `snapshotLens`, `interval` (for example `1m`),
`confirmations` (for example `2`), `gasLimit` (for example `3000000`) and
`stateDir`. The adapters bootstrap does not deploy the collector. Use the
publisher's encrypted keystore for the daemon, and retain its durable state
directory across restarts. Add `-once` to publish one reporting cycle.

Wait for all seven initial four-field reports (`chainId`, `adapter`,
`totalAssets`, `snapshotBlock`) to be accepted through the saved forwarder and
visible in the next block. Then seed using the owner wallet:

```sh
python3 script/deploy/testnet/bootstrap.py \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --account sepolia-owner \
  --password-file /absolute/path/to/owner-password \
  --phase seed \
  --existing-manifest script/deploy/testnet/manifests/self-hosted-sepolia.json
```

After funding, let the daemon publish a newer completed-block report, then run
the same command with `--phase sync` and `--phase validate`. Action batches also
synchronize reports delivered by the daemon. `ReportMerkleTestnet` and synthetic
3F signatures/funding are restricted to local chain 31337. Sepolia uses the
official 3F factory, facility, whitelist and six-decimal USDC regardless of
oracle mode; offers still require the official auction API and authorization.

Schema-2 manifests explicitly store `oracleMode`, `reportPublisher`, the registry
and forwarder. Resume preserves these values and rejects conflicting overrides.
Self-hosted deployments reject registry overrides during creation and official
CRE activation artifacts in every phase. Manifests missing these fields must be
regenerated with the current deployment script.

## Local bootstrap

Use Foundry **1.8.5** with the repository's Solidity 0.8.37, IR and Osaka settings.
Do not pass plaintext private keys. Use an encrypted Foundry keystore and a
password file or interactive signing outside this helper.

For a fresh local chain, start `anvil --hardfork osaka --enable-tx-gas-limit --gas-limit 60000000`
without relaxing contract-size limits, and fund the keystore address. The default
seed budget needs about 134 ETH for genuine WETH/staking backing, plus deployment
gas; use a smaller `--seed-assets` budget on faucet-funded testnets.

1. `DeployRealisticTestnet`: fresh core/V2, adapters, protocols, the entire RWA
   catalog, per-market Merkle factories/registries/account/oracle, connector,
   executor, capability and 3F policy; accepted roots, exact proofs and roles.
2. `ActivateMerkleTestnet`: ownership links and proposed / accepted workflows in
   a locally deployed source-pinned Chainlink workflow registry. The local owner
   is the authorized ownership-proof signer.
3. `ReportMerkleTestnet`: initial completed-block NAV report, routed through the
   source-pinned Keystone forwarder. This initializes allocation capacity.
4. `SeedRealisticTestnet`: genuine vault deposits, lending allocations, borrower
   collateral/debt, nested restaking, funded issuer inventory, and an executed
   Merkle recipe that supplies Aave and consumes the 3F policy before minting PT/YT.
5. `SeedThreeFTestnet`: externally signed EIP-712 offers exercise the production
   3F adapter callback. Fixture yield funding and offer consumption are atomic.
6. `ReportMerkleTestnet`: a new completed-block snapshot reconciles funding.
7. `ValidateRealisticTestnet`: read-only checks compare the saved human-readable
   manifest with persisted accounts, native lending positions, workflows and all profiles.

`bootstrap.py` coordinates the local phases and signs ownership hashes for the
locally owned registry with `cast wallet sign`. It never records signing keys or passwords in manifests.
Report calls explicitly reserve 500,000 gas because the real Keystone forwarder
checks entry gas, which can exceed Forge's estimate of consumed gas.
The manifest contains human-readable market addresses/catalog entries and ABI
encoded phase input. Keep it with the corresponding chain. Funding exercises all 49 wrapped integrations and the three generic issuer
profiles through real Liquid Lane swaps. Pareto begins a running epoch before its
queue request. The generic ERC4626 account is funded and redeemed directly: its
production `ORACLE()` returns zero, which the legacy Liquid Lane quote API cannot
use. Its separate oracle is available through the Merkle connector registry.
Funding rejects a second run; deploy to a fresh manifest for another independent environment.

```sh
python3 script/deploy/testnet/check_catalog.py
python3 script/deploy/testnet/bootstrap.py \
  --rpc-url http://127.0.0.1:8545 \
  --account local-testnet \
  --password-file /absolute/path/to/password-file \
  --seed-assets 100000 \
  --manifest script/deploy/testnet/manifests/local.json
```

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

All 53 profiles and seven markets are visited. Investor actions use actual Merkle
account custody: ERC1271-signed CoW RWA purchases with real solver inventory,
LL token transfers and swaps returning cash to the account, ERC4626 deposits and
redemptions, funded lending deposits, collateral, borrows, bounded leverage loops,
repayments and withdrawals, and 3F PT/YT investments and matured burns. Production
RecipeExecutor programs read balances and debt during atomic execution and bind
those actual values into subsequent actions. The curator publishes exact action
permissions and programs, then restores the deployment root and base recipe.
Native issuer administration and funded reward delivery use their actual owner
or solver roles; their investor protocol calls originate from the account.

Lending loops skip an account's occupied Aave V3, Euler/Morpho credit-vault,
Morpho Blue or Midnight debt market. The corresponding `families` count is zero
and `occupiedDebt` is true at the same index; other families continue. The order
is core vault, Aave V3, Euler, Morpho vault, ERC4626, Blue, Midnight and Aave V4.
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
Local issuer authorization and report delivery are limited to chain 31337. Issuer
and lending endpoints remain the funded protocol models documented above.

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

## Official Sepolia phases

Install Foundry **1.8.5** with `foundryup -i v1.8.5`. Both helpers select 1.8.5 for
local and Sepolia work. The Solidity 0.8.37, IR and Osaka settings in `foundry.toml`
remain the compiler configuration; the helpers do not pass a hardfork override.
Add **`--fast`** for fork-prepared gas limits and Foundry broadcasts in batches
of 100. Without `--fast`, Sepolia uses
`--skip-simulation --slow`: Forge still executes the script locally to generate
its transactions, then estimates each ordinary transaction through `eth_estimateGas`
immediately before sending it, after the previous transaction succeeds. This avoids
using an Osaka replay estimate to price a live Sepolia transaction. Explicit gas
budgets in Solidity calls remain explicit.

### Fast deployment and resume

Fast mode generates the transaction plan without broadcasting, forks the original
deployment block with Anvil 1.8.5, warms its account cache, and replays the complete
saved plan in nonce order. Rebuilding contracts on the fork keeps their new storage
local and avoids repeated historical reads for each new slot. Confirmed transactions
execute only on that disposable fork; the public broadcast submits the remaining
nonce suffix. Other phases plan from the latest completed block. The helper records
gas limits with a 30% margin, then invokes
Foundry `--resume --broadcast` without `--slow` or `--skip-simulation`. Transactions
from the same deployer can be included together in a block. The planning fork uses
zero gas fees to avoid spending its copied owner balance at Anvil's default price;
the public broadcast uses normal EIP-1559 fees and checks the owner's remaining
budget against the RPC gas price. Native-value transfers remain funded by the
owner's copied balance. Compiler and hardfork settings are unchanged.
The fork uses a 2,500 compute-unit-per-second RPC budget, compared with Anvil's
default 330. Set `TESTNET_FORK_CUPS=330` for a provider that requires the lower
limit; planning will take longer. Provider limits and retries still apply.
If the RPC cannot serve the original block's state, set `TESTNET_FAST_FORK_LATEST=1`
to prepare only the remaining transactions from current state. That fallback can
take longer.

Gas plans, original-artifact backups and new Foundry recovery generations live in
ignored `broadcast/testnet-fast/` and `cache/testnet-fast/` directories. The helper
reuses compiler metadata, verifies successful canonical receipts and deployed code,
and preserves the original deployment artifacts. Its cache pointer lets the same
resume command find an interrupted fast broadcast. Keep these directories until
deployment is complete. Keystore passwords and private keys are never copied.

For a currently running sequential deployment, press **Ctrl-C** in its terminal
first. The helper rejects an active Foundry writer. Resume the existing manifest;
do not generate a new deployment or change the deployer account:

```sh
python3 script/deploy/testnet/bootstrap.py --rpc-url "$TESTNET_RPC_URL" --account testnet-deployer --password-file "$HOME/.foundry/testnet-password" --fast --resume --existing-manifest script/deploy/testnet/manifests/sepolia-retry.json
```

Use the manifest from the deployment being resumed if its filename differs. The
helper binds its vault factory, vaults and Merkle accounts to the saved plan. It
waits for existing pending transactions and resubmits an unsubmitted durable
payload using its original signature and hash. Mined failures, missing signed
payloads, foreign pending transactions and consumed nonces stop recovery instead
of changing deployment addresses. Stop other activity from the deployer while
planning and broadcasting. `--resume` is currently limited to deployment; funding
phases remain non-idempotent.

For a fresh deployment, choose an unused manifest filename:

```sh
python3 script/deploy/testnet/bootstrap.py --rpc-url "$TESTNET_RPC_URL" --account testnet-deployer --password-file "$HOME/.foundry/testnet-password" --fast --seed-assets 100 --manifest script/deploy/testnet/manifests/sepolia-fast.json
```

The target is approximately 30 minutes for contract deployment; RPC latency, gas
prices and public-chain inclusion can extend it. CRE organization activation and
report delivery are separate phases. Later `activate`, `seed` and `sync` commands
can also add `--fast`; `actions.py` retains its existing execution mode.

Verification commands (the second uses disposable local nodes and a newly generated
temporary encrypted keystore):

```sh
python3 -m unittest discover -s script/deploy/testnet -p 'test_*.py'
TESTNET_FAST_INTEGRATION=1 python3 -m unittest discover -s script/deploy/testnet -p 'test_*.py'
```

If deployment fails, the manifest written during simulation is provisional.
Inspect canonical receipts before using it. If only the first transaction failed
and no contracts were created, retry with a new manifest path; the helper regenerates
addresses from the owner's current nonce. Preserve the old manifest and broadcast
artifacts for diagnosis. Do not use Forge `--resume` after a mined failure has
consumed a nonce from the saved plan. If any deployment transactions succeeded,
reconcile those contracts before choosing a recovery path.

The Sepolia profile binds the following contracts. The bootstrap checks deployed
code at every address, `WorkflowRegistry 2.0.0` on the selected registry,
`KeystoneForwarder 1.0.0` on the fixed forwarder, six USDC decimals, and the owner's
ETH backing budget before deployment.

| Contract                               | Sepolia address                              |
| -------------------------------------- | -------------------------------------------- |
| CRE deployed-workflow forwarder        | `0xF8344CFd5c43616a4366C34E3EEE75af79a74482` |
| 3F requests factory                    | `0x56834F241E4A4D6e5C4207B03bB16b2B3FfCc5fb` |
| 3F facility                            | `0x68129DbAEefA7eB88fc0276b9C27A5169c43d675` |
| 3F request whitelist                   | `0xA80b976A357aC24f3c38F7E5ED3Dd5b813bb09E1` |
| 3F testnet USDC                        | `0x809e6c18bC13Cc7C9F7b8000d74243BAaccE84d7` |
| CRE staging WorkflowRegistry (default) | `0xaE55eB3EDAc48a1163EE2cbb1205bE1e90Ea1135` |

The forwarder is the deployed-workflow address in the
[Chainlink forwarder directory](https://docs.chain.link/cre/guides/workflow/using-evm-client/forwarder-directory-go).
The default registry is the official CRE **staging** Sepolia deployment published
in the [pinned CRE CLI environment configuration](https://github.com/smartcontractkit/cre-cli/blob/46a18d6c7a6709d2981c46437ea643a7bef1d23c/internal/environments/environments.yaml#L20-L22).
Its deployed code and `WorkflowRegistry 2.0.0` ABI were verified on Sepolia. The
public production registry listed in the
[onchain deployment guide](https://docs.chain.link/cre/guides/operations/deploying-to-onchain-registry-go)
is a mainnet deployment and cannot substitute for this same-chain registry.

The infrastructure addresses are resolved by default. Activation still requires
CRE staging tenant access, the appropriate DON authorization and Chainlink-issued
ownership proofs and workflow artifacts. A production CRE CLI login alone does
not establish staging access. The helper keeps the supplied artifacts and uses
the official authorization checks; it does not generate official ownership proofs.
An organization may override the registry using `--chainlink-registry` or
`TESTNET_CHAINLINK_REGISTRY`; overrides must have same-chain code and the required
version. An explicitly empty or invalid override is rejected. Resuming without an
explicit override preserves the registry recorded in the manifest.

The 3F bundle matches requests returned by the
[live Sepolia auction API](https://bf.dev.gcp.3f.xyz/v1/auction?scope=all&domain=true)
and its [deployment transaction](https://eth-sepolia.blockscout.com/tx/0xa1b99014217c088031c47aca329426f0985f19d85577e6ba7e3d3937d739dc93).
The newer v1.3 addresses in [3F deployments.json](https://docs.3f.xyz/deployments.json)
belong to a different factory/facility generation. Keep the factory, facility,
whitelist and request provenance together; changing an isolated binding prevents
native request and policy validation.

The official USDC contract is a testnet `MockERC20` with a public
`mint(address,uint256)` faucet. Funding calls that existing deployed faucet to
obtain actual official USDC, then transfers it into vaults and issuer backing.
A prefunded USDC balance is therefore unnecessary. WETH and staking inventory
still consume the owner's real Sepolia ETH. For example, a `--seed-assets 100`
budget needs about 0.134 ETH for backing, plus deployment and execution gas.

The default `bootstrap` phase on Sepolia performs deployment and writes the
manifest, then stops at the CRE handoff. Deployment accepts Merkle roots and roles,
but this script waits for accepted workflows and a real initial report before allocation.
The oracle itself permits flow-based NAV before the first report. Official
3F requests are zero by default. The helper creates local protocol fixtures and
connects official services without granting itself their administrative authority.

```sh
# The official CRE staging Sepolia registry is selected automatically.
python3 script/deploy/testnet/bootstrap.py \
  --rpc-url "$ETH_RPC_URL_SEPOLIA" \
  --account sepolia-testnet \
  --password-file /absolute/path/to/password-file \
  --fast \
  --seed-assets 100 \
  --manifest script/deploy/testnet/manifests/sepolia.json
```

Keep the printed manifest. Later phases use `--existing-manifest` and retain its
recorded owner, chain and seed budget. They also verify the
fixed Sepolia bindings before invoking a script.

| Phase                           | Prerequisite and result                                                                                  |
| ------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `deploy` or default `bootstrap` | Preflights infrastructure and ETH; deploys and stops with CRE activation pending                         |
| `activate`                      | Loads official activation artifacts; validates all entries before linking owners and accepting workflows |
| `seed`                          | Synchronizes an accepted initial CRE report before funding all fixture positions and redemption accounts |
| `sync`                          | Synchronizes accepted reports already delivered through the official forwarder                           |
| `validate`                      | Runs read-only checks against persisted deployment and funded positions                                  |

The CRE organization supplies a JSON file in this shape. `entries` must contain
exactly seven entries in `manifest.markets` order; the single entry below shows
its fields. Replace the placeholders with the exact issued values. `chainlinkRegistry`
must match the saved manifest; this example uses the default staging registry.
Oracle and wrapper addresses come from that market's `creOracle` and
`workflowRegistry`. Proofs and workflow IDs must be unique across entries.

```json
{
  "chainId": 11155111,
  "chainlinkRegistry": "0xaE55eB3EDAc48a1163EE2cbb1205bE1e90Ea1135",
  "owner": "0x<manifest owner>",
  "entries": [
    {
      "oracle": "0x<market creOracle>",
      "wrapper": "0x<market workflowRegistry>",
      "expiry": 2000000000,
      "proof": "0x<Chainlink-issued bytes32 proof>",
      "signature": "0x<Chainlink-issued signature bytes>",
      "workflowId": "0x<actual bytes32 workflow ID>",
      "tag": "default",
      "status": 0,
      "donFamily": "<organization DON family>",
      "binaryUrl": "<published workflow binary URL>",
      "configUrl": "<published workflow configuration URL>",
      "attributes": "0x"
    }
  ]
}
```

Store this file inside the repository so Foundry can read it. Activation checks
its identities and each unused ownership proof through upstream `canLinkOwner`
before its first transaction. The official path uses the supplied proof, signature, workflow ID
and metadata verbatim. Exact already linked and accepted workflows can be resumed;
mismatched workflow metadata is rejected.
The optional `tag` defaults to `default`; `status` defaults to `0` (`ACTIVE`),
or can be `1` (`PAUSED`). Both are part of the exact proposal and resume checks.
For local activation, `TESTNET_WORKFLOW_TAG` selects the tag and defaults to `default`,
while `TESTNET_WORKFLOW_STATUS` selects the status and defaults to `0`.
Use ACTIVE workflows for bootstrap seeding and activity; paused workflows do not run on the DON.

```sh
python3 script/deploy/testnet/bootstrap.py \
  --rpc-url "$ETH_RPC_URL_SEPOLIA" \
  --account sepolia-testnet \
  --password-file /absolute/path/to/password-file \
  --phase activate \
  --existing-manifest script/deploy/testnet/manifests/sepolia.json \
  --cre-activation script/deploy/testnet/manifests/sepolia-cre-activation.json
```

Wait for the CRE workflow to deliver an initial completed-block NAV report through
the official forwarder, then run the same helper with `--phase seed`. Its first
step verifies accepted workflows, oracle/adapter/registry/forwarder wiring and an
accepted snapshot for every market before synchronization. A missing or stale
report prevents funding. After funding, wait for a new completed-block CRE report,
then run `--phase sync` and `--phase validate` with the same manifest and wallet
arguments. `ReportMerkleTestnet` is a local delivery simulator and rejects Sepolia;
`SyncMerkleTestnet` submits only adapter synchronization transactions.

Official 3F lending starts when a real request is available. The read-only
`PrepareSepoliaThreeFOfferScript` validates the live request factory, whitelist,
asset, facility intent and EIP-712 domain, then writes an unsigned offer and digest:

```sh
export TESTNET_MANIFEST=script/deploy/testnet/manifests/sepolia.json
export TESTNET_THREE_F_MARKET=0
export TESTNET_THREE_F_REQUEST="$OFFICIAL_THREE_F_REQUEST"
export TESTNET_THREE_F_AMOUNT=2000000
export TESTNET_THREE_F_EXPECTED_RETURN=20000
export TESTNET_THREE_F_EXPIRATION="$OFFER_EXPIRY"
forge script script/deploy/testnet/PrepareSepoliaThreeFOffer.s.sol:PrepareSepoliaThreeFOfferScript \
  --rpc-url "$ETH_RPC_URL_SEPOLIA" --no-isolate
```

An authorized adapter offer signer can sign the exact native EIP-712 payload and
publish it through the 3F Bridge Facilitator API. The sibling `vault-solver` 3F
strategy supports this offer lifecycle with an explicit adapter list and an
authorized keystore signer. An auction winner or third-party request taker
consumes the signed offer and funds the adapter callback; the bootstrap does not
fabricate request authorization, settlement or yield on official contracts.
`SeedThreeFTestnet` is reserved for local fixtures.

## Runtime inputs and recovery

Shared variables: `TESTNET_OWNER`, `TESTNET_SEED_ASSETS` (USD budget per vault),
`TESTNET_MANIFEST`, `TESTNET_RPC_URL`. Sepolia additionally
uses optional `TESTNET_CHAINLINK_REGISTRY` and required activation-phase
`TESTNET_CRE_ACTIVATION` (or the corresponding CLI options). The helper uses encrypted keystores and never records keys or
passwords in manifests.

Local-only inputs are `TESTNET_LINK_EXPIRY`, `TESTNET_LINK_PROOF`,
`TESTNET_LINK_SIGNATURES`, `TESTNET_THREE_F_SIGNATURES`,
`TESTNET_WORKFLOW_BINARY_URL` and `TESTNET_WORKFLOW_CONFIG_URL`. Signatures are
comma separated. Local ownership proofs derive from a random base proof and each
wrapper address. `TESTNET_SNAPSHOT_BLOCK` is for manual local reports; bootstrap
selects a fresh completed block. Official phases discard local signature inputs.

Resume completed deployments with an explicit phase and `--existing-manifest`;
bootstrap refuses to overwrite a saved deployment. Seed intentionally rejects a
second funding run. If a broadcast partially fails, inspect Foundry receipts and
persisted state before continuing; do not rerun the entire bootstrap or funding
phase blindly. A failed funding batch can require finishing individual actions
or a fresh environment.

The Python orchestration tests use mocked subprocesses and make no RPC calls:

```sh
python3 -m unittest discover -s script/deploy/testnet -p test_bootstrap.py
```

## Fidelity and assumptions

The table describes the funded protocol models shared by both profiles. The
Chainlink row describes local fixtures; official Sepolia relies on the external
CRE organization and forwarder as described above.

| Component                                               | Behavior exercised                                                                                                   | Limits                                                                                                            |
| ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Symbiotic core, adapters and Merkle infrastructure      | Current repository contracts, real factories/proxies, roles, roots, capability recipes, policy and report accounting | No production deployment claim                                                                                    |
| Chainlink registry / forwarder                          | Source-pinned contracts, ownership signatures, workflow proposal/acceptance and routing                              | Owner routing simulates delivery; no DON consensus, CRE worker or real offchain workflow is run                   |
| Morpho Blue / Midnight                                  | Pinned upstream engines, native shares, debt, interest, liquidation and offer/ratifier semantics                     | Local fixed-rate IRM, prices and a contract lender                                                                |
| Euler / Morpho Vault V2                                 | Funded ERC4626 cash + accruing debt, native decimal conversion, collateral and cash-limited exits                    | Behavioral credit model; no EVC routing, Vault V2 timelocks, allocation queues or fees                            |
| Aave V3                                                 | Indexed aToken balances, real reserve cash, variable debt, health checks and account/configuration reads             | One reserve; no credit delegation, liquidation or multi-reserve risk engine                                       |
| Aave V4                                                 | Funded Hub/Spoke supply shares and native liquidity reads                                                            | Single supply-only endpoint; no borrowing or full governance                                                      |
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

Native engine copies are from `morpho-blue` commit
`8e26ca6a8dbc5089edcd67fb576248810fd2870a` and `morpho-midnight` commit
`531ab3b23f95dcc660b8805e46f089248c6b994e`. Only import paths/order, contract names and caret
pragmas change; `check_catalog.py` compares their executable tokens with the pinned
sources. Upstream licenses remain on the copied sources.

Run these phases promptly on a fresh chain. Timestamped prices intentionally become
stale; synthetic Midas/issuer feeds need owner publication when testing later dates.
The seed refreshes DUSD accounting and both InfiniFi NAV rounds after funding.
