# Borrow health factors

Stateless view helpers under `src/contracts/merkle-adapter/automations/health-factors/`.
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

Install one constructorless, stateless `RecipeCapability`. A lending leaf encodes
`execute(queries, steps, inputs)`: first `Call` the lending method, then `Read` its
health factor, then assert `LessOrEqual(Literal(minimum), Result(healthRead))`.
Only intended amount words or numerical inputs may vary. The minimum, query,
operations and bindings are pinned by the leaf. Changing a floor requires a new
accepted leaf and role. There is no limit mapping or health-factor setter.

Place the condition after the complete approved sequence, or after each lending
operation if intermediate positions must also satisfy it. Failure rolls back every
call. Repayment and collateral supply remain available through their own approved
leaves. The helpers return one scalar word; the generic interpreter can also select
a word from a multiword protocol response. See [Account recipe capability](RECIPE-CAPABILITY.md).

## Sources and verification

The Blue helper copies collateral valuation and ratio arithmetic from Morpho's
`MorphoBlueSnippets.userHealthFactor`. It imports `MorphoBalancesLib`, `MathLib`
and interfaces from the pinned `lib/morpho-blue` submodule. Run `forge install`
to install dependencies. Accrued interest, virtual balances, debt rounding and
overflow behavior use the upstream implementations. The wrapper retains its
market-id input and early zero-debt return, and uses `GPL-2.0-or-later` for the
Blue libraries it incorporates.

Midnight exposes `isHealthy(...)` as a boolean. Its published periphery has no
numeric health-factor getter. The wrapper copies its maximum-debt accumulation,
including `UtilsLib.msb`, `clearBit` and the protocol's rounded arithmetic from
the pinned `lib/morpho-midnight` submodule. Public getters replace storage reads;
the wrapper returns a ratio and handles maturity. It uses the upstream
`GPL-2.0-or-later` license. All copies and integration changes are listed in
[Protocol source provenance](UPSTREAM.md).

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
