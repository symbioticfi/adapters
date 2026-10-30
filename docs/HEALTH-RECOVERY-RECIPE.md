# Health recovery and repayment

Health recovery, claiming and cash repayment use separate `RecipeExecutor`
configurations:

- [`health-recovery.json`](../script/recipes/examples/health-recovery.json):
  low health → ordered Morpho/Aave withdrawals → repay → ordered RWA requests.
- [`claim.json`](../script/recipes/examples/claim.json):
  claim one ready request. Proceeds stay in the account. The executor SDK discovers
  requests and batches repeated executions through `multicall`.
- [`health-repay.json`](../script/recipes/examples/health-repay.json):
  repay from cash already received, preserving an explicit reserve.

Grant each executor only the leaves required by its own recipe. A failed repayment
transaction does not roll back a claim completed in an earlier transaction. See
[claim preparation and ordering](RECIPE-CLAIMS.md).

## Generate configuration transactions

```sh
forge script script/recipes/BuildRecipe.s.sol:BuildRecipe \
  --rpc-url "$ETH_RPC_URL" \
  --sig 'run(string,string)' \
  script/recipes/examples/health-recovery.json out/health-recovery.json

forge script script/recipes/BuildRecipe.s.sol:BuildRecipe \
  --rpc-url "$ETH_RPC_URL" \
  --sig 'run(string,string)' \
  script/recipes/examples/health-repay.json out/health-repay.json
```

The script resolves the custody account from the adapter and writes constructor,
factory-create, `setRecipe` and `setCaller` calldata. It does not broadcast. Example
addresses and amounts must be replaced with verified deployment values.

## Recovery

The recipe reads debt and health on-chain. For one debt asset and unchanged
collateral, the repayment requirement is:

```text
need = debt - floor(debt × min(health, targetHealth) / targetHealth)
budget = min(need, maxRepayment)
```

Recovery requires `health <= triggerHealth < targetHealth`. It spends available
account cash and withdraws permitted liquidity sources in order. Source proceeds
must equal the selected amounts. Repayment verifies debt reduction, cash debit,
health and cleared allowance. If liquidity is insufficient, the recipe can request
RWA redemption for the remaining need, sharing the per-execution cap with repayment.

Pending-principal reads must include distinct outstanding and matured unclaimed
requests in the repayment asset. They reduce new redemption requests, never count
as repayment. Capacity reads must exclude already committed holdings. Each read is
fixed `{ target, data, offset }`; example issuer getters are not universal APIs.

`optimizations.skipUnusedReads` reuses source cash observations. It does not remove
repayment checks or permit unavailable source or issuer reads. `amountOffsets`
binds the selected amounts to the permitted calldata; repayment and request
amounts remain derived from live state.

## Cash repayment

Run `health-repay` after claims or pushed payouts have delivered cash. It computes:

```text
repayment = min(max(cash - minCashBalance, 0), need, maxRepayment)
```

It does not require health below the recovery trigger. With no repayment need or
no spendable cash, execution reverts. Cash has no provenance tag: this recipe may
spend any account cash above its configured reserve. It contains no claim call and
cannot initiate a new redemption request.
