# Borrow health factors

Stateless view helpers under `src/contracts/merkle_adapter/borrow_capability/`.
Each exposes only `getHealthFactor`, returning liquidation-adjusted collateral
value divided by debt, scaled by `1e18` and rounded down. Higher is safer;
`1e18` is the liquidation boundary. Zero debt returns `type(uint256).max`.

| Helper                       | Arguments                     | Calculation                                                                                                    |
| ---------------------------- | ----------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `AaveHealthFactor`           | `pool, account`               | Sixth value of `getUserAccountData(account)`, preserving the pool's scale and zero-debt behavior.              |
| `MorphoBlueHealthFactor`     | `morpho, marketId, account`   | Oracle-valued collateral × LLTV / debt, including pending interest and virtual shares. Debt rounds up.         |
| `MorphoMidnightHealthFactor` | `midnight, marketId, account` | Sum of activated collateral values × their LLTVs / face-value debt. Unpaid debt after maturity returns zero.   |
| `EulerHealthFactor`          | `vault, account`              | Ratio of the values returned by `accountLiquidity(account, true)`, using liquidation LTVs and midpoint prices. |

The queried account is the adapter, or its explicitly configured protocol
subaccount. Protocol and market arguments keep helpers reusable across deployments.
They hold no funds, approvals, configuration or storage. External query failures
revert.

Install one constructorless `BorrowCapability`. Each approved lending leaf calls
`borrow(address target, address healthFactorTarget, bytes data, bytes healthFactorData)`. The lending calldata includes its actual
amount; the Merkle action mask permits only the selected amount to vary. The
health query's target and complete calldata are fixed by the leaf.

The curator calls `setHealthFactor(keccak256(abi.encode(healthFactorTarget, healthFactorData)), minimum)`
through an approved adapter self-call leaf using `manage`. The leaf fixes the health-query ID
and permits only the minimum to vary; the caller must hold its leaf role. The minimum is adapter-local
and shared by all leaves using that exact query. Changing it needs no new root proposal. An unset minimum
blocks checked operations. The query must return exactly one scalar word; no
return-data offset is configured.

Health is checked immediately after each wrapped operation, including borrowing
and collateral withdrawal. A missed floor reverts the entire operation. Curator
minimum updates do not require the position to currently meet the new floor;
repayment and collateral supply remain available through their own approved leaves.

## Sources and verification

The Blue helper imports `MorphoBalancesLib.expectedBorrowAssets` and Morpho's
interfaces from the pinned `lib/morpho-blue` submodule. Run `forge install` to
install dependencies. Accrued-interest math, virtual balances, debt rounding and
overflow checks belong to the upstream library; our wrapper only values
collateral and divides by the returned debt. The wrapper uses the library's
`GPL-2.0-or-later` license.

Midnight exposes `isHealthy(...)` as a boolean. Its published periphery has no
numeric health-factor getter, so the Midnight wrapper sums activated collateral
and handles maturity locally. It visits only set bits, taking the highest active
index with Morpho's `UtilsLib.msb` from the pinned `lib/morpho-midnight` submodule
and clearing that bit after each collateral valuation. The wrapper uses the
library's `GPL-2.0-or-later` license.

Arithmetic and read interfaces were checked against:

- [Morpho Blue](https://github.com/morpho-org/morpho-blue/tree/8e26ca6a8dbc5089edcd67fb576248810fd2870a/src), including its interest preview, debt rounding and virtual balances.
- [Morpho Midnight](https://github.com/morpho-org/midnight/blob/531ab3b23f95dcc660b8805e46f089248c6b994e/src/Midnight.sol), including active collateral and maturity rules.
- [Euler EVK](https://github.com/euler-xyz/euler-vault-kit/tree/bfb325a6e6ca09613d940b46f72ccfe017353933/src/EVault), using its existing account-liquidity calculation.

`BorrowHealthFactors.t.sol` covers rounding, zero debt, oracle failures, interest and its overflow checks,
collateral selection and maturity. The mainnet tests at
block `25,892,000` exercise successful borrowing and atomic rollback through the
production adapter and capability for all three protocols. They also compare Blue's
interest preview with actual accrual. Initial token funding, the Morpho oracle
price and Midnight maker authorization are local fixtures; the lending contracts,
debt accounting and token transfers run against deployed contracts.

```sh
forge test --match-contract BorrowHealthFactorsTest
# Requires ETH_RPC_URL, an Ethereum archive RPC.
forge test --match-contract BorrowHealthFactorsMainnetTest
```
