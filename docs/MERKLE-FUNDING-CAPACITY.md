# Merkle LL and 3F funding capacity

`MerkleFundingLens.getAvailableAssets(account, asset, sources)` returns the account's
cash plus explicitly configured synchronous withdrawal capacities, in funding-token
base units. It excludes the MerkleAdapter's cash, reported NAV and asynchronous exits.
It does not change execution permissions or reserve funds.

Consumers apply their existing limits afterward:

- LL: minimum of funding and `LiquidLaneConnector.remainingAssets(tokenToRedeem)`.
- 3F: minimum of funding and `ThreeFPolicy.remainingAssets(asset, underlyingAsset)`;
  live offers also reserve both physical funding and their pair budget.

Deploy the stateless helper once per chain, using the normal deployment account:

```sh
forge create src/contracts/merkle-adapter/automations/liquidity/MerkleFundingLens.sol:MerkleFundingLens \
  --rpc-url "$RPC_URL" --account "$DEPLOYER_ACCOUNT" \
  --password-file "$PASSWORD_FILE" --broadcast
```

No deployed address is implied by this change. Configure the returned address in
RFQ backend and vault-solver `merkleFunding` entries. Each entry is scoped to an
`account`/`asset` pair and includes `lens` plus up to 32 `sources`. Each source has:

| Field    | Meaning                                                                                                                                                       |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `id`     | Nonzero bytes32 canonical venue/position identity, e.g. `keccak256(abi.encode(pool, asset))`. Alternate queries for the same liquidity use the same identity. |
| `target` | Deployed protocol or reviewed scalar liquidity helper.                                                                                                        |
| `data`   | Complete ABI call data with the account, asset and market bound where required.                                                                               |
| `offset` | Byte offset of the returned uint256 capacity word, normally zero.                                                                                             |

Reuse the selected recipe's capacity queries. For Aave V3, a source can target
`AaveV3Liquidity.liquidityWithBorrow(pool, asset, account)`; this includes pool cash
and standard-mode solvency checks. `MorphoLiquidity.liquidity(vault, account)`
models the configured Morpho V2 withdrawal route. ERC4626/Euler `maxWithdraw(account)`
queries are usable only when their returned amount includes the execution constraints
of the approved recipe. Aave V4's supply-only helper must not size collateral exits
supporting debt. Stricter recipe health floors require equally strict sizing queries.

The operator must review source ownership, denomination, permissions and underlying
liquidity overlap. Do not list two paths to the same position, both a nested vault
and its underlying position, or sources competing for the same cash pool. Duplicate
identities and identical target/calldata queries are rejected; arbitrary overlap
cannot be inferred from query bytes. Disjointness must also hold across accounts/routes
combined in one quote. Sources must exclude account cash itself.
A source requiring a state-changing preparation call cannot be represented as a
static query; use a reviewed view helper that computes the needed bound instead.

All reads use the consumer's pinned block. Failed calls, missing words, malformed
configuration and duplicate sources fail closed. With no account/asset entry, the
consumer retains cash-only capacity. Backend and pricing solver must use matching
reviewed source sets, and the final recipe/outer transaction must still be simulated.
RFQ and 3F orders share live account funds: each workflow's reservations must not be
interpreted as an on-chain guarantee against another workflow consuming those funds.
