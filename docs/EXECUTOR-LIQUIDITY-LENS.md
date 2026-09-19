# Executor liquidity queries

`ExecutorLiquidityLens` is a stateless contract deployed with:

```solidity
new ImmutableFactory(type(ExecutorLiquidityLens).creationCode);
// Then factory.create("") creates and registers an instance.
```

For each recipe funding source the builder sets `capacity.target` to that instance and
constructs `capacity.data` from the accepted strategy's pool, token and adapter.
The helper grants no permissions and holds no assets. The selected Merkle leaf
and its executor role remain the authorization boundary.

| Query                                                             | Capacity and supported state                                                                                                   |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `aaveWithdraw(pool, asset, account)`                              | aToken balance, underlying/virtual cash and collateral health headroom.                                                        |
| `aaveBorrow(pool, asset, account, minHealthFactor)`               | Borrowable account value converted with Aave's price and reserve decimals, minimum health factor, reserve cash and borrow cap. |
| `aaveWithdrawGuarded(pool, asset, account, minHealthFactor)`      | Aave withdrawal capacity preserving the leaf-pinned minimum, with required debt value rounded upward.                          |
| `morphoBorrowGuarded(morpho, marketId, account, minHealthFactor)` | Morpho Blue borrowing capacity preserving the leaf-pinned minimum.                                                             |
| `morphoVaultWithdraw(vault, account)`                             | Fee-adjusted share value, exit gates and idle assets plus the single configured liquidity-adapter exit.                        |
| `morphoBorrow(morpho, marketId, account)`                         | Current interest, oracle collateral value, LLTV, rounded debt shares and market cash.                                          |
| `eulerBorrow(vault, account)`                                     | Enabled sole controller, borrow cap, cash and debt priced with EVK's ask-side oracle against borrow-LTV collateral value.      |

Checked liquidity queries take the same literal minimum health factor encoded in
the accepted guarded leaf. The recipe builder takes that floor from the leaf
and constructs the lens calldata. There is no adapter
mapping lookup. A changed threshold requires a new accepted leaf and an updated
execution plan. Minima below `1e18`, including zero, use the protocol solvency
boundary. Checked withdrawals return zero when the account is already below the
configured floor.

Every successful response is one ABI-encoded `uint256` in the funding token's
base units. Account arguments are explicit: the query caller is the RecipeExecutor,
not the adapter. Ordinary Euler withdrawal uses the vault's native
`maxWithdraw(adapter)` directly.

Aave standard mode is supported. eMode, isolation, siloed borrowing and
zero-LTV collateral combinations return zero until their separate rules are
implemented. Reserve-index padding protects scaled aToken/debt-share rounding
at health-factor boundaries. Euler requires an already enabled controller and
returns zero for custom borrow or vault-status hooks. Morpho V2 supports the
standard market adapter and ERC-4626 wrapper adapter; unknown adapter families
contribute zero, and nested V2 wrappers are limited to four levels. The V2
helper never substitutes all adapter assets for liquidity in its single exit
market. Failed reads revert.

The protocol calculations are copied or directly imported from pinned upstream
sources. See [source provenance and integration changes](../src/contracts/merkle-adapter/automations/libraries/UPSTREAM.md).
Vault V2 uses Morpho's snippets library; Blue/Midnight use native arithmetic and
periphery; Euler uses its native account liquidity and copied cap decoder;
Aave uses native account data and copied percentage math. The amount search and
stricter health-factor floors remain integration code where no upstream getter exists.

The recipe consumes each source in order using `min(capacity, remaining need)`.
Its execution caller must supply matching runtime amounts and proofs; this
helper does not rewrite calldata. The recipe independently checks every actual
asset balance increase and the final spend, so stale state or a rejected
protocol action rolls the transaction back.

Validation:

```sh
FOUNDRY_DYNAMIC_TEST_LINKING=false forge test --match-contract '^ExecutorLiquidityLensTest$'
# ETH_RPC_URL must be supplied privately in the environment.
FOUNDRY_DYNAMIC_TEST_LINKING=false forge test --match-contract ExecutorLiquidityLensMainnetTest --match-test test_MainnetLens
```

The fork tests pin Ethereum block 25,892,000 and exercise real Aave supply,
protected borrowing, collateral withdrawal and Morpho Blue borrowing through
MerkleAdapter. Unit/fuzz tests cover caps, native units, rounded shares, V2's
configured exit market, Euler controller/hooks, and failed reads.
