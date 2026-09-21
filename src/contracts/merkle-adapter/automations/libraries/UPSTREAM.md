# Protocol source provenance

Keep the original SPDX licenses and pinned references when updating these copies.

| Local code                                         | Upstream source                                                                                                                                                                                                                 | Integration changes                                                                                                                                                                                                                                                                                                        |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `VaultV2LiquidityLib.sol`                          | [Morpho snippets, `VaultV2LiquidityLib`](https://github.com/morpho-org/morpho-snippets/blob/2da95cc5dd5e180b745e8c2bbc047b5d97545179/src/vault-v2/VaultV2LiquidityLib.sol) (GPL-2.0-or-later)                                   | Copied the five withdrawal/liquidity functions. Imports use minimal native interfaces and pinned Blue libraries. Retained existing exit-gate checks, four-level recursion bound and exact 160-byte exit-market encoding. Nested V2 exits use the same checks. Omitted unused share-redemption and external-lens functions. |
| `../health-factors/MorphoMidnightHealthFactor.sol` | [Midnight, `isHealthy`](https://github.com/morpho-org/midnight/blob/531ab3b23f95dcc660b8805e46f089248c6b994e/src/Midnight.sol#L899-L916) (GPL-2.0-or-later)                                                                     | Copied maximum-debt accumulation, MSB traversal and bit clearing. Uses public getters instead of protocol storage, returns a 1e18-scaled ratio and retains the zero-debt/overdue-debt rules. Locals accommodate the non-IR compiler. `UtilsLib` and constants come from the pinned submodule.                              |
| `../health-factors/MorphoBlueHealthFactor.sol`     | [Morpho snippets, `userHealthFactor`](https://github.com/morpho-org/morpho-snippets/blob/2da95cc5dd5e180b745e8c2bbc047b5d97545179/src/morpho-blue/MorphoBlueSnippets.sol#L134-L147) (MIT; uses GPL-2.0-or-later Blue libraries) | Copied collateral valuation, LLTV and ratio arithmetic. Uses the existing market-id API, rejects uncreated markets and returns before oracle/IRM reads for zero debt.                                                                                                                                                      |
| `PercentageMath.sol`                               | [Aave V3 Origin, `PercentageMath`](https://github.com/aave-dao/aave-v3-origin/blob/8305565ae342f1773c42cd2e4593f175fe5968a0/src/contracts/protocol/libraries/math/PercentageMath.sol) (BUSL-1.1)                                | Copied without arithmetic changes; only attribution and formatting.                                                                                                                                                                                                                                                        |

## Native reads and remaining integration code

Aave health uses native `getUserAccountData`. Euler health uses native
`accountLiquidity(account, true)` and normalizes the ratio. Neither wrapper
recalculates protocol collateral portfolios.

`AaveV3Liquidity.liquidity` copies the liquidity sizing in `AaveV3Adapter._deallocate`: the
minimum of the account's aToken balance and the pool's virtual underlying balance.
It does not perform health, mode, reserve-flag or oracle reads.

`AaveV3Liquidity.liquidityWithBorrow` retains Aave's supported-mode filtering, reserve cash
constraints and conservative index/base-unit rounding at the protocol's `1e18`
solvency boundary. Account data and indexes come from the pool; percentage
operations use the copied library. These wrappers are integration code, not
verbatim upstream withdrawal getters. Protocol rules are in
[GenericLogic](https://github.com/aave-dao/aave-v3-origin/blob/8305565ae342f1773c42cd2e4593f175fe5968a0/src/contracts/protocol/libraries/logic/GenericLogic.sol)
and [ValidationLogic](https://github.com/aave-dao/aave-v3-origin/blob/8305565ae342f1773c42cd2e4593f175fe5968a0/src/contracts/protocol/libraries/logic/ValidationLogic.sol).
The collateral buffer also covers the one-basis-point aggregate-threshold
truncation in [V3.3 GenericLogic](https://github.com/aave-dao/aave-v3-origin/blob/v3.3.0/src/contracts/protocol/libraries/logic/GenericLogic.sol)
and V3.4 before withdrawal validation.

`AaveV4Liquidity.liquidity` uses native getters from Aave V4 at
[`40232a0`](https://github.com/aave/aave-v4/tree/40232a0a91150d8ee5cab42bd3ddd0baf4ffff9f).
[`Spoke.getUserSuppliedAssets`](https://github.com/aave/aave-v4/blob/40232a0a91150d8ee5cab42bd3ddd0baf4ffff9f/src/spoke/Spoke.sol#L573-L580)
uses the same `previewRemoveByShares` conversion as `Spoke.withdraw`.
[`Hub.remove`](https://github.com/aave/aave-v4/blob/40232a0a91150d8ee5cab42bd3ddd0baf4ffff9f/src/hub/Hub.sol#L223-L246)
limits removal by accounted liquidity and the Spoke's added shares. The wrapper caps
the user's supplied assets by `getAssetLiquidity` and `getSpokeAddedAssets`.
Share math stays in Aave's getters; no implementation code is vendored. Debt,
health, pause and active/halted checks remain with protocol execution.

Euler withdrawals use native `maxWithdraw`. Borrow sizing and withdrawal sizing
for stricter curator health floors are off-chain calculations. Approved guarded
leaves still enforce their actual health and balance conditions on-chain.
