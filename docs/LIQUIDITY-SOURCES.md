# Withdrawal liquidity sources

Each protocol's queries live in their own stateless contract, deployed independently:

```solidity
new ImmutableFactory(type(AaveV3Liquidity).creationCode);
new ImmutableFactory(type(AaveV4Liquidity).creationCode);
new ImmutableFactory(type(MorphoLiquidity).creationCode);
// Then factory.create("") creates and registers an instance.
```

Deploy only the sources a strategy uses. Because each contract covers one protocol, its
queries need no protocol prefix: every source exposes `liquidity`, and Aave V3 adds
`liquidityWithBorrow` for collateral supporting debt.

For a withdrawal funding source the builder sets `capacity.target` to the relevant instance
and constructs `capacity.data` from the accepted strategy's pool, token and custody account.
These contracts grant no permissions and hold no assets. The selected Merkle leaf
and its executor role remain the authorization boundary.

| Query                                                       | Capacity and supported state                                                                              |
| ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `AaveV3Liquidity.liquidity(pool, asset, account)`           | Minimum of aToken balance and virtual underlying liquidity, matching `AaveV3Adapter`.                     |
| `AaveV3Liquidity.liquidityWithBorrow(pool, asset, account)` | aToken balance, underlying/virtual cash and collateral headroom at the protocol's `1e18` health boundary. |
| `AaveV4Liquidity.liquidity(spoke, reserveId, account)`      | Minimum of account supplied assets, Hub liquidity and Spoke added assets; no debt calculations.           |
| `MorphoLiquidity.liquidity(vault, account)`                 | Fee-adjusted share value, exit gates and idle assets plus the single configured liquidity-adapter exit.   |

Every successful response is one ABI-encoded `uint256` in the funding token's
base units. Account arguments are explicit: the query caller is the RecipeExecutor,
not the adapter. Euler and Morpho V1 withdrawals use their vault's native
`maxWithdraw(account)` directly.

`AaveV3Liquidity.liquidity` only sizes liquidity. It does not inspect debt, health, reserve flags,
account modes or prices. Aave's withdrawal itself still enforces protocol checks.
Use `liquidityWithBorrow` when the account has borrowing; the LL, 3F and health-recovery
examples use this debt-aware query. Both share the same deployment, because they share
their reserve and user-configuration reads.

`AaveV4Liquidity.liquidity` uses the Spoke's reserve identifier to resolve its
Hub and Hub asset identifier. Native getters apply share conversion and rounding;
the liquidity cap uses Hub accounting rather than its raw ERC-20 balance. This query
does not check borrowing, collateral health, reserve pause or Spoke status. Use it
for positions without borrowing; the protocol checks execution. There is no V4
debt-aware withdrawal query.

Borrow amounts are selected and simulated off-chain. These sources expose no borrowing
capacity calculation or curator-specific health-floor calculation. The approved
`GuardedCallsCapability` leaf continues to enforce the configured health floor
against the actual resulting position. Even the debt-aware Aave estimate may exceed what
a stricter leaf permits; an off-chain planner must choose the smaller amount and
use a recipe that accepts that amount, rather than the maximum-capacity funding
template below.

The debt-aware Aave query supports standard mode. eMode, isolation, siloed borrowing and
zero-LTV collateral combinations return zero until their separate rules are
implemented. Reserve-index padding protects scaled aToken rounding at the
health boundary. An additional one-basis-point collateral buffer covers the
post-withdraw aggregate-threshold truncation in Aave V3.3/V3.4; it remains
conservative on later versions. Morpho V2 supports the standard market adapter and ERC-4626
wrapper adapter; unknown adapter families contribute zero, and nested V2 wrappers
are limited to four levels. The V2 helper never substitutes all adapter assets
for liquidity in its single exit market. Failed reads revert.

See [source provenance and integration changes](UPSTREAM.md).
Vault V2 uses Morpho's snippets library and native periphery arithmetic. The basic Aave query
copies `AaveV3Adapter` liquidity sizing; the debt-aware query uses native account data and
copied percentage math, with local withdrawal constraints.

The existing LL/3F funding template consumes each source in order using
`min(capacity, remaining need)`. Its execution caller supplies runtime calls and proofs. The recipe binds the
calculated amount to the configured source argument offsets; this read-only helper
does not execute or rewrite calls. The recipe independently
checks every actual asset balance increase and the final spend, so stale state or
a rejected protocol action rolls the transaction back. Runtime-sized borrowing
recipes use inputs and approved guarded leaves instead of these capacity reads.

Validation:

```sh
FOUNDRY_DYNAMIC_TEST_LINKING=false forge test --match-contract '^LiquiditySourcesTest$'
# ETH_RPC_URL must be supplied privately in the environment.
FOUNDRY_DYNAMIC_TEST_LINKING=false forge test --match-contract LiquiditySourcesMainnetTest
```

The fork tests pin Ethereum block 25,892,000 and exercise Aave V3 and V4 withdrawals without debt,
collateral withdrawals with outstanding debt and a Morpho V2 deposit/withdrawal through
MerkleAccount. The mixed-collateral Aave test also runs at block 22,000,000 with
`MAINNET_FORK_BLOCK=22000000 --match-test test_MainnetAaveV3MixedCollateral` to
check the older aggregate-threshold rounding. Unit/fuzz tests cover
withdrawal solvency, native-unit rounding, pool cash, unsupported Aave V3 states,
Aave V4 account/Hub/Spoke liquidity bounds,
Morpho V2's configured exit market, accrued interest, exit gates and failed reads.
Borrow health-factor tests remain separate and do not depend on these liquidity sources.
