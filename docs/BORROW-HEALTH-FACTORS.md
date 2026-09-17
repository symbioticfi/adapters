# Borrow health factors

Stateless view helpers under `src/contracts/merkle_adapter/borrow_capability/`.
Each exposes only `getHealthFactor`, returning liquidation-adjusted collateral
value divided by debt, scaled by `1e18` and rounded down. Higher is safer;
`1e18` is the liquidation boundary. Zero debt returns `type(uint256).max`.

| Helper                       | Arguments                     | Calculation                                                                                                         |
| ---------------------------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `MorphoBlueHealthFactor`     | `morpho, marketId, account`   | Oracle-valued collateral × LLTV / debt, including pending interest and virtual shares. Debt rounds up.              |
| `MorphoMidnightHealthFactor` | `midnight, marketId, account` | Sum of activated collateral values × their LLTVs / face-value debt. Unpaid debt after maturity returns zero.        |
| `EulerHealthFactor`          | `vault, account`              | Ratio of the values returned by `accountLiquidity(account, true)`, using liquidation LTVs and midpoint prices.      |
| `CompoundV3HealthFactor`     | `comet, account`              | Collateral valued with `liquidateCollateralFactor` / current base-token debt, using Comet's price and token scales. |

The queried account is the adapter, or its explicitly configured protocol
subaccount. Protocol and market arguments keep helpers reusable across deployments.
They hold no funds, approvals, configuration or storage. External query failures
revert. Compound also returns the maximum value if the debt's quoted value rounds
to zero, matching Comet's integer valuation.

Configure `BorrowCapability` with the helper as `healthFactorTarget`, the encoded
`getHealthFactor(...)` call as `healthFactorData`, and `healthFactorOffset = 0`.
The curator's `minHealthFactor` uses the same `1e18` scale. The check runs after
borrowing and reverts the entire operation if the floor is missed.

Aave V3 and V4 expose their health factor directly, so they need no helper.
Compound support here is for V3/Comet. These helpers do not add Compound V2 borrow
return-code handling or change capability authorization.

## Sources and verification

The Blue helper imports `MorphoBalancesLib.expectedBorrowAssets` and Morpho's
interfaces from the pinned `lib/morpho-blue` submodule. Run `forge install` to
install dependencies. Accrued-interest math, virtual balances, debt rounding and
overflow checks belong to the upstream library; our wrapper only values
collateral and divides by the returned debt. The wrapper uses the library's
`GPL-2.0-or-later` license.

Midnight exposes `isHealthy(...)` as a boolean. Its published periphery has no
numeric health-factor getter, so the Midnight wrapper sums activated collateral
and handles maturity locally.

Arithmetic and read interfaces were checked against:

- [Morpho Blue](https://github.com/morpho-org/morpho-blue/tree/8e26ca6a8dbc5089edcd67fb576248810fd2870a/src), including its interest preview, debt rounding and virtual balances.
- [Morpho Midnight](https://github.com/morpho-org/midnight/blob/531ab3b23f95dcc660b8805e46f089248c6b994e/src/Midnight.sol), including active collateral and maturity rules.
- [Euler EVK](https://github.com/euler-xyz/euler-vault-kit/tree/bfb325a6e6ca09613d940b46f72ccfe017353933/src/EVault), using its existing account-liquidity calculation.
- [Compound Comet](https://github.com/compound-finance/comet/blob/f766f51583c23acc33b2a7824654ef2029a96804/contracts/CometWithExtendedAssetList.sol), including current debt, collateral valuation and liquidation factors.

`BorrowHealthFactors.t.sol` covers rounding, zero debt, oracle failures, interest and its overflow checks,
different token decimals, collateral selection and maturity. The mainnet tests at
block `25,892,000` exercise successful borrowing and atomic rollback through the
production adapter and capability for all four protocols. They also compare Blue's
interest preview with actual accrual. Initial token funding, the Morpho oracle
price and Midnight maker authorization are local fixtures; the lending contracts,
debt accounting and token transfers run against deployed contracts.

```sh
forge test --match-contract BorrowHealthFactorsTest
# Requires ETH_RPC_URL, an Ethereum archive RPC.
forge test --match-contract BorrowHealthFactorsMainnetTest
```
