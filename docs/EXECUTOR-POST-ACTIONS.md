# Executor post-swap redemption matrix

At Ethereum block **26,005,394**, the [mainnet fork suite](../test/adapters/merkle-adapter/ExecutorPostActionsMainnet.t.sol)
passes **52 tests: 49 successful token paths and three expected atomic rejections**.
The matrix covers 50 tokens. bEQTY remains blocked by issuer enrollment; the two
additional rejection cases cover fresh sUSD3 cooldown initiation and Spiko's
currently unregistered SPKCC/USDC output route.

Each successful path runs the production LiquidLaneExecutor, MerkleAdapter and
LiquidLaneConnector with actual Merkle proofs and leaf roles. After the swap,
the post-action batch consumes exactly the incoming RWA amount while preserving
the adapter's prior RWA balance. This checks consumption of the swapped token.
For asynchronous paths, the asserted result is a request, receipt or escrow
transfer; later issuer processing and final payout are not exercised.

## Calls and observed results

`a` is the swapped RWA amount. Call targets are the named token, vault, gateway
or issuer endpoint; beneficiary, owner and controller arguments are the adapter
unless shown otherwise. Approvals and every subsequent call require their own
allowed post-action leaf, a proof under the accepted root and a LiquidLaneExecutor role.
An empty per-token leaf list prohibits post actions; a nonempty list requires at
least one. The solver chooses the sequence and can repeat an allowed leaf.

| Tokens                                                                                                                                                                                                                                             | Post-action sequence                                                                           | Result asserted on the fork                                                                                             | Prerequisites exercised                                                                                                                                                                                         |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Centrifuge (7):** ACRDX, HYB, JAAA, JTRSY, deCRDX, deJAAA, deJTRSY                                                                                                                                                                               | USDC vault `requestRedeem(a, adapter, adapter)`                                                | Pending redeem request equals `a`.                                                                                      | Issuer membership for both connector and adapter, granted through the token's hook by an authorized member administrator.                                                                                       |
| **Midas (23):** CarryTradeUSDTRYLeverage, StockMarketTRBasisTrade, mAPOLLO, mBASIS, mBTC, mEDGE, mEVUSD, mFARM, mF-ONE, mGLOBAL, mHYPER, mHyperBTC, mHyperETH, mM1-USD, mMEV, mROX, mRe7BTC, mRe7YIELD, mSL, mTBILL, mevBTC, msyrupUSD, msyrupUSDp | Token `approve(redemptionVault, a)` → vault `redeemRequest(outputToken, a)`                    | Stored pending request names the adapter and chosen output token, with a positive requested amount no greater than `a`. | Vault minimum, enabled output route, applicable greenlist, unpaused vault/function and healthy feed. Fork governance and timestamp changes are detailed below.                                                  |
| **Figure (2):** PRIME, AUTO                                                                                                                                                                                                                        | Token `redeem(a, adapter, adapter)` → underlying yield vault `requestRedeem(previewRedeem(a))` | Pending underlying-vault redemption records the expected shares and positive assets.                                    | Redeemable wrapper capacity and an available underlying request path; no issuer enrollment changes in this test.                                                                                                |
| **GAIB:** sAID                                                                                                                                                                                                                                     | `unstake(a)`                                                                                   | Positive pending unstake amount.                                                                                        | Issuer's current unstake conditions; no enrollment changes in this test.                                                                                                                                        |
| **Theo:** sthUSD                                                                                                                                                                                                                                   | `initiateRedeem(a, adapter)`                                                                   | Request contains exactly `a` shares, positive assets and a future claimable timestamp.                                  | Issuer delay applies; the test stops before claiming.                                                                                                                                                           |
| **Noon:** sUSN                                                                                                                                                                                                                                     | `redeem(a, withdrawalHandler, adapter)`                                                        | Positive, unclaimed withdrawal request belonging to the adapter.                                                        | The receiver must be the issuer's withdrawal handler for this path.                                                                                                                                             |
| **3Jane:** USD3                                                                                                                                                                                                                                    | `redeem(a, adapter, adapter)`                                                                  | Native USDC proceeds reach the adapter.                                                                                 | Live issuer redemption capacity; amount uses the token's six decimals.                                                                                                                                          |
| **3Jane:** sUSD3                                                                                                                                                                                                                                   | `redeem(a, adapter, adapter)`                                                                  | USD3 proceeds reach the adapter; cooled shares decrease by exactly `a`.                                                 | Preexisting, matured cooldown capacity within its withdrawal window, with `a = maxRedeem(adapter)`. See the cooldown explanation below.                                                                         |
| **InfiniFi (2):** liUSD-4w, liUSD-13w                                                                                                                                                                                                              | Token `approve(gateway, a)` → gateway `startUnwinding(a, epochs)`                              | Positive adapter balance in the unwinding module.                                                                       | The correct lock duration: 4 or 13 epochs. Subsequent unwinding and payout are not exercised.                                                                                                                   |
| **Lido:** wstETH                                                                                                                                                                                                                                   | `approve(queue, a)` → queue `requestWithdrawalsWstETH([a], adapter)`                           | One adapter-owned withdrawal request with positive stETH amount, not claimed.                                           | Queue request bounds and available request path.                                                                                                                                                                |
| **Ether.fi:** weETH                                                                                                                                                                                                                                | `unwrap(a)` → eETH `approve(pool, output)` → pool `requestWithdraw(adapter, output)`           | Adapter receives one withdrawal NFT.                                                                                    | `output = getEETHByWeETH(a)`; adapter must implement the ERC-721 receiver callback.                                                                                                                             |
| **OpenEden:** HYBOND                                                                                                                                                                                                                               | `approve(express, a)` → express `requestRedeem(adapter, a)`                                    | Pending redeem amount equals `a`.                                                                                       | Authorized KYC operator enrolls both connector and adapter; `a` meets `redeemMinimum()`.                                                                                                                        |
| **Pareto:** AA_FalconXUSDC                                                                                                                                                                                                                         | `approve(queue, a)` → queue `requestWithdraw(0.4a)` → queue `requestWithdraw(0.6a)`            | Next-epoch withdrawal shares total `a`; approval is fully consumed.                                                     | Queue/epoch eligibility and Keyring access. The fork owner disables Keyring enforcement through the real governance setter.                                                                                     |
| **Securitize (2):** ACRED, STAC                                                                                                                                                                                                                    | Token `transfer(redemptionWallet, a)`                                                          | Redemption wallet receives exactly `a`.                                                                                 | Issuer investor/wallet enrollment and matured transfer restrictions. This proves receipt by the redemption wallet, not an onchain claim or payout.                                                              |
| **Securitize:** VBILL                                                                                                                                                                                                                              | `approve(offRamp, a)` → off-ramp `redeem(a, expected)`                                         | Adapter receives exactly `expected` RLUSD.                                                                              | Qualified-investor enrollment, matured transfer restrictions and off-ramp liquidity; `expected = calculateLiquidityTokenAmount(a)`.                                                                             |
| **Makina:** DUSD                                                                                                                                                                                                                                   | `approve(redeemer, a)` → redeemer `requestRedeem(a, adapter, 0)`                               | Adapter receives a redemption receipt NFT.                                                                              | Adapter must implement the ERC-721 receiver callback. No issuer authorization changes are made in this test.                                                                                                    |
| **Superstate:** USCC                                                                                                                                                                                                                               | `offchainRedeem(a)`                                                                            | Total supply falls by exactly `a`.                                                                                      | Allowlist owner grants the connector and adapter the `USCC` protocol-address permission. Offchain payout routing and payment are not verified.                                                                  |
| **Spiko:** SPKCC                                                                                                                                                                                                                                   | `transferAndCall(redemption, a, abi.encode(USDC, salt))`                                       | Pending request with a future deadline; redemption contract escrows exactly `a`.                                        | Existing holder group 6 for connector and adapter, issuer-enabled SPKCC/USDC route and request minimum. Both enrollment and route enablement are fork governance setup.                                         |
| **DigiFT:** bEQTY — blocked                                                                                                                                                                                                                        | Intended: `approve(manager, a)` → manager `redeem(token, USDC, a, timestamp)`                  | Actual connector-to-adapter transfer reverts `Forbid transfer`; the whole swap rolls back.                              | `addWhiteContract` requires issuer multisignatures. No signatures are fabricated and no transfer restriction is bypassed. The intended redemption call is never reached, so its compatibility remains unproven. |

The Midas helper starts from each test's preferred output and selects the first
registered payment token if that preference is absent. The stored request is
checked against the actual selection. mBASIS has no registered output at this
block, so its test explicitly adds USDC before requesting redemption. No Midas
test demonstrates delivery of the requested output asset.

## Fork setup and limits

The fork uses deployed mainnet token and issuer contracts. **Issuer calls and
their return values are not mocked.** The test deploys the adapter and connector
through their production factories, but uses local vault, delegator, registry
and NAV-oracle fixtures. LiquidLane pricing is a fixed `1e18` test oracle. Funding
and RWA balances are seeded with Foundry `deal`; packed Centrifuge balances use
`vm.store`. Each normal success retains seven preexisting RWA base units and
pays one USDC base unit to the swap recipient. These fixtures establish call and
balance compatibility, not production prices, available inventory or economic
redemption capacity.

Issuer setup is explicit and runs only on the fork:

- **Midas:** real administrators grant applicable greenlist and pause roles,
  unpause the vault or `redeemRequest` where necessary, and rewind the timestamp
  into the existing feed's healthy interval when its read is stale. Historical
  feed data is unchanged. mBASIS additionally grants the vault role and calls
  `addPaymentToken(USDC, mTokenDataFeed, 0, type(uint256).max, true)`. That is test
  output configuration, not an assertion that live mBASIS supports USDC today.
- **Pareto:** the CDO owner calls `setKeyringParams(address(0), 0)`. The test uses
  real queue and epoch state, but does not demonstrate acquiring a production
  Keyring credential.
- **Securitize:** the registry administrator registers a US investor, sets the
  required attributes, adds both contract wallets and adds the qualified
  attribute for VBILL. It issues tokens at a timestamp earlier than the US lock
  period, then restores fork time. This creates genuinely matured issuer state
  on the fork; it does not establish that fresh live holdings can transfer.
- **Superstate:** the real allowlist owner grants the `USCC` protocol-address
  permission to both contracts. The successful burn leaves offchain onboarding
  and payout untested.
- **Spiko:** the active authority administrator adds both contracts to existing
  holder group 6 and calls `registerOutput(SPKCC, USDC, true)`. A separate test
  retains the live output configuration and proves atomic rejection with
  `Input/Output pair is not authorized`, leaving no pending request.
- **NFT receivers:** weETH and DUSD install an ERC-721 holder capability on the
  adapter through its capability registry. The issuer's safe-mint callback is
  executed normally.

The successful sUSD3 test starts a real cooldown on existing adapter inventory,
advances to `cooldownEnd + 1`, checks the withdrawal window and reads the actual
`maxRedeem(adapter)`. The issuer's asset/share rounding can make this cap smaller
than the original cooled share amount. The connector then supplies exactly that
cap and the batch redeems it. Incoming tokens do not reset the recipient's
cooldown: the adapter finishes with its original RWA balance, while its cooled
allowance falls by the exact redeemed amount. This path consumes **preexisting
matured account capacity**; it does not make newly received shares immediately
redeemable without that capacity. Repeated executions must recheck the remaining
cap and window. A separate test uses only `startCooldown(a)` after the swap:
because this retains the RWA balance, LiquidLaneExecutor rejects it and rolls back both the
swap and the cooldown.

## Reproduce

Run from the repository root with an Ethereum archive RPC endpoint supplied
privately in `ETH_RPC_URL`:

```sh
: "${ETH_RPC_URL:?Set ETH_RPC_URL in the environment}"
MAINNET_FORK_BLOCK=26005394 forge test \
  --match-path test/adapters/merkle-adapter/ExecutorPostActionsMainnet.t.sol -vv
```

The suite defaults to that same block. Without `ETH_RPC_URL`, it skips; a skipped
run is not issuer verification. Changing the block requires rechecking issuer
permissions, configured output routes, feed freshness, liquidity and cooldown
capacity. The recorded result is **52 passed, 0 failed, 0 skipped** at the pinned
block, with the fork prerequisites above.
