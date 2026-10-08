# Complete local testnet

This suite extends the bundled core deployment scripts and the current
`DeployMerkleAdapterScript`. It creates a new environment without pre-existing
addresses. It is intended for development chains and testnets.

The catalog contains **all 49 token account integrations** in
`src/contracts/ll-adapter/tokens-to-redeem`, plus generic ERC4626, Asseto,
OpenEden and daily Securitize accounts. The actual configurable account
implementations are deployed with local dependencies. The mainnet wrappers
contain fixed mainnet addresses and therefore are represented by their current
base account implementation. Source cooldowns, Midas bounds, the mGLOBAL monthly
cutoff and the native redemption asset are retained. Catalog fixture prices are
explicit synthetic values, not current market quotes.

Seven asset markets cover USDC (6), aUSD (18), tBTC (18), WBTC (8), cbBTC (8), WETH
(18) and USDT (6). USD budgets are converted into native units using fixed testnet
quotes of $3,000/ETH and $60,000/BTC. WETH and both ETH staking models require actual
native ETH backing. Other tokens are issuer-controlled testnet assets.

## Deployment phases

Use Foundry **1.8.1** with the repository's Solidity 0.8.37, IR and Osaka settings.
Do not pass plaintext private keys. Use an encrypted Foundry keystore and a
password file or interactive signing outside this helper.

For a fresh local chain, start `anvil --hardfork osaka --enable-tx-gas-limit --gas-limit 60000000`
without relaxing contract-size limits, and fund the keystore address. The default
seed budget needs about 134 ETH for genuine WETH/staking backing, plus deployment
gas; use a smaller `--seed-assets` budget on faucet-funded testnets.

1. `DeployRealisticTestnet`: fresh core/V2, adapters, protocols, the entire RWA
   catalog, per-market Merkle factories/registries/account/oracle, connector,
   executor, capability and 3F policy; accepted roots, exact proofs and roles.
2. `ActivateMerkleTestnet`: externally signed ownership links and proposed /
   accepted workflows in the real Chainlink workflow registry.
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

`bootstrap.py` coordinates these phases and signs registry ownership hashes with
`cast wallet sign`. It never records signing keys or passwords in manifests.
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

Runtime variables: `TESTNET_OWNER`, `TESTNET_SEED_ASSETS` (USD budget per vault),
`TESTNET_MAX_REPORT_AGE`, `TESTNET_MANIFEST`, `TESTNET_RPC_URL`,
`TESTNET_LINK_EXPIRY`, `TESTNET_LINK_PROOF`, `TESTNET_LINK_SIGNATURES` and optionally
`TESTNET_SNAPSHOT_BLOCK` (manual reports only; bootstrap selects a fresh block), `TESTNET_THREE_F_SIGNATURES`,
`TESTNET_WORKFLOW_BINARY_URL` and `TESTNET_WORKFLOW_CONFIG_URL`. Signatures are comma separated. Ownership proofs are
unique per registry; the base random proof is combined with each registry address.

## Fidelity and assumptions

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
| CoW                                                     | Canonical GPv2 EIP712 domain, presignature UIDs, bounded partial fills and real relayer transfers                    | Presigned ERC20 sell orders only; no auction, Balancer balances or EOA signing schemes                            |
| Merkl                                                   | Cumulative root-based funded reward transfers and replay accounting                                                  | Local owner-published roots and owner/user authorization; no dispute window or custom recipient/operator registry |

The NAV producer reads a pinned completed block and values the configured Merkle
account's cash, supplied shares, known collateral/debt, 3F position and held RWA
inventory. Native issuer redemptions belong in the deployed Liquid Lane accounts;
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
Do not restart the full helper after a partially broadcast failure: inspect its
Foundry receipts and run only the unfinished phase with the saved manifest.
