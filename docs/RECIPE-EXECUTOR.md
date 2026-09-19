# Configurable strategy execution

`RecipeExecutor` runs a curator-defined sequence of reads, adapter calls and
checks. The owner stores its steps with `setRecipe`; the provider supplies
amounts, concrete calls and current Merkle proofs on each run. Execution reads
the stored steps directly. Failed checks revert the whole transaction.

The executor holds no strategy assets. Direct protocol calls and approvals run
through `MerkleAdapter`. The adapter checks its current root, leaf roles and
asset limits. The executor adds ordering, amount dependencies and economic
postconditions. `GuardedCallsCapability` enforces the health checks pinned into approved lending leaves.

## Ownership and authorization

1. Deploy an instance through
   `ImmutableFactory(type(RecipeExecutor).creationCode)` using
   `create(abi.encode(curator, adapter))`.
2. The curator calls `setRecipe(recipe)` and `setCaller(provider)`.
3. Grant the executor the recipe's required adapter leaf roles. The provider
   receives no direct leaf roles and cannot call the adapter instead of the recipe.
4. The provider calls `execute(inputs, runtime)` using the stored recipe.

Setting the recipe caller to zero disables execution. Replacing a recipe needs
one curator transaction; changing a permitted venue still requires an accepted
adapter leaf. A root update that retains the leaves only requires new proofs,
not a recipe update. Configuration setters cannot run during execution.

`setRecipe` replaces the whole stored `steps` array and emits it in `SetRecipe`.
The public `steps(index)` getter returns one instruction; the event provides the
complete ordered list. Execution always uses the configuration stored when the
transaction runs, including any owner update made after it was submitted.

## Define recipes from JSON

Fill in the named addresses, accepted leaves and limits in the selected example,
then run:

```sh
forge script script/recipes/BuildRecipe.s.sol:BuildRecipe \
  --sig 'run(string,string)' \
  script/recipes/examples/lending.json out/lending-recipe.json

forge script script/recipes/BuildRecipe.s.sol:BuildRecipe \
  --sig 'run(string,string)' \
  script/recipes/examples/ll-executing.json out/ll-executing-recipe.json

forge script script/recipes/BuildRecipe.s.sol:BuildRecipe \
  --sig 'run(string,string)' \
  script/recipes/examples/3f-executing.json out/3f-executing-recipe.json
```

The output contains the encoded recipe, `setRecipe` and `setCaller` calldata,
and constructor arguments. Supplying a factory address also generates
`factory.create` calldata. The script needs no RPC, key or broadcast and sends
no transactions. The supplied examples deliberately use dummy addresses and
leaf hashes: replace them with the selected adapter's actual configuration.
`ll-executing` and `3f-executing` run complete strategies through the adapter.

## 1. Supply LBTC, borrow USDC, purchase an RWA

The executable definition is
[`LendingRecipe.build`](../script/recipes/LendingRecipe.sol). It takes fixed
adapter/token/pool/issuer addresses, five approved leaves, and three limits:

```text
maxSupplyLbtc       = 100000000          # at most 1 LBTC per run, 8 decimals
maxTotalDebtUsdc    = 50000000000        # total debt <= 50,000 USDC, 6 decimals
minRwaPerUsdcWad    = 990000000000000000 # >= 0.99 RWA per USDC, RWA has 18 decimals

inputs[0] = 100000000                   # supply 1 LBTC
inputs[1] = 30000000000                 # borrow and spend 30,000 USDC
```

These are example policy values, not a live quote or a lending recommendation.
The health floor and available borrowing capacity can reject them. The pool's
collateral settings, including any required eMode selection, must already allow
the chosen borrowing or be configured through additional approved recipe leaves.

| Order | Defined action                                                 | Enforced relationship                                                                                    |
| ----- | -------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| 1     | Read wallet, collateral receipt and debt balances              | Positive inputs, supply limit, remaining debt headroom                                                   |
| 2     | Approve LBTC and supply the fixed Aave pool                    | Exact LBTC debit; collateral receipt increases by that amount, within one base unit                      |
| 3     | Borrow USDC through the approved `GuardedCallsCapability` leaf | Health check succeeds; measured USDC inflow equals the selected borrow amount                            |
| 4     | Read variable debt                                             | Debt increase matches the measured inflow within one base unit; resulting total debt stays below its cap |
| 5     | Approve the issuer for measured borrowed USDC and purchase     | Final USDC balance equals its pre-borrow balance; minimum actual RWA output is received                  |
| 6     | Clear both approvals                                           | No residual pool or issuer allowance from this recipe                                                    |

If the adapter already holds 10,000 USDC and borrows 30,000, only the additional
30,000 funds the purchase; the original 10,000 remains. A second run cannot
silently exceed the total-debt cap. The recipe does not grant the provider the
health-floor setter role.

The five leaves are LBTC approval, Aave supply, checked borrowing, USDC approval
and issuer purchase. Pin pool, token, spender, account, recipient, rate mode and
health query in those leaves; mask only approved amount fields. The runtime
slots are the named `LendingRecipe.Register` values. Approval slots contain
`abi.encode(IRecipeExecutor.Permission)`; each managed slot contains
`abi.encode(IMerkleAdapter.Action[])` with exactly the configured leaf.

This definition expects an immediate purchase. For asynchronous subscriptions,
change the output read to the issuer's verifiable pending entitlement and use a
separate claim recipe after settlement. A successful request is not delivery of
the RWA.

## 2. Fund and execute LL or 3F directly

[`LLExecuting.build`](../script/recipes/LLExecuting.sol) and
[`ThreeFExecuting.build`](../script/recipes/ThreeFExecuting.sol) generate complete
recipes: obtain liquidity in the configured order, approve through the adapter,
execute the approved connector/request leaf, clear approvals and check the results.

The common funding configuration uses `adapter`, `addresses.vault`,
`addresses.asset` and ordered `sources[]`. Each source contains a capacity read
`{target, data, offset}` and an ordered `leaves` array. Capacity must be in raw
vault-asset units. The recipe verifies the adapter's vault and vault's asset,
uses idle cash excluding `reservedAssets`, then requests
`min(remaining shortfall, live capacity)` from each source. Each source must
increase the adapter's cash by exactly the calculated amount. Reserved funds
must remain covered after the final operation. A zero amount skips the source's
actions; its capacity read still runs. A reverting read or action aborts the run.
The adapter also enforces reserves after each source's `manage` call. If cash
starts below reserved assets, the first active source must cover that initial
deficit; partial refills cannot accumulate across calls below the reserve floor.

For example, funding 100 USDC with 20 spendable idle USDC and source capacities
of 30 and 80 requires withdrawals of 30 and 50 in that order. The provider must
construct those amounts in the action calldata and supply current proofs.

### Liquid Lane

[`ll-executing.json`](../script/recipes/examples/ll-executing.json) adds:

- `addresses.connector`, `addresses.rwa`, `addresses.recipient`.
- `leaves.approval` for funding-token approval to the connector, and
  `leaves.swap` for the connector's signed `swap` overload.
- `limits.maxAmountIn` in RWA units and `limits.maxFundingAmount` in funding-token
  units. Runtime inputs are `[amountIn, amountOut]`; `amountIn` must be positive.
  `amountOut` is the exact live discounted quote, including zero for a 100% discount.
- Optional `redemption`: a spender and approval leaf, ordered redemption leaves,
  a receipt read, `minReceiptNumerator`, `receiptDenominator` and
  `maxReceiptBalance`. Omit it or use `redemption.leaves: []` to retain the RWA.
  For a direct burn without approval, set `redemption.spender` to the zero address.

The swap leaf targets the connector and pins the RWA and payout recipient. Only
approved amount/signature fields may vary. The mask also pins ABI structural
offsets and length words: different signature lengths require separately
approved templates. The standard catalog emits a 65-byte/65-byte EOA template.
The connector accepts ERC-1271 signers when the approved leaf matches the actual
signature lengths.

The connector validates its owner's or configured signer's discount signature
and the protocol's countersignature. It checks expiry, nonce invalidation, the
owner-configured discount floor and the live oracle quote. EIP-712 uses
`LiquidLaneConnector`, version `1`, the current chain and connector proxy address.
The owner calls `setSigner(address)` and `setMinDiscount(token, ppm)`; owner or
signer can call `invalidateNonce(token, nonce)`. Successful fills do not consume
the nonce. No capability installation is needed for connector swaps.

The recipe checks exact funding-token debit, exact recipient payout and exact
RWA inflow. A supplied quote that differs from the capability's actual result
reverts. It clears the connector approval. If redemption is configured, all its
leaves run in order and must consume exactly the newly received RWA, preserving
pre-existing RWA holdings. The receipt increase must be at least
`floor(amountIn * minReceiptNumerator / receiptDenominator)`, with at least one
receipt base unit required even when this floor rounds to zero, and the resulting
receipt balance must stay below its cap. Choose a nonzero denominator and a
minimum meaningful at the smallest allowed fill. The optional issuer approval
is cleared after redemption.

The receipt read can be a claim-token balance, an issuer's pending entitlement
or immediate redemption proceeds. It is measured around redemption only, so a
cash receipt does not accidentally count the source withdrawals. Verify issuer
accounting and decimal conversion: there is no universal RWA receipt ABI.

### 3F

[`3f-executing.json`](../script/recipes/examples/3f-executing.json) supplies
`addresses.request`, `addresses.requestsFactory`, `addresses.policy`,
`leaves.approval`, `leaves.mint` and a raw funding-token `limits.maxPrincipal`.
Deploy `ThreeFPolicy(curator, recipeExecutor)` and configure the JSON `policy`
values: cumulative `maxAssets` per `duration` seconds and `minYieldPerRequest`
(yield/principal scaled by 1e6, not annualized). The output includes both policy
setter calldatas. They can be updated directly by the policy owner without
changing the recipe or Merkle root.

The recipe requires `requestsFactory.isRequest(request)` and positive live
`mintAuthorization(adapter)` principal within its cap. It authenticates the two
static arguments supplied to `policy.consume(principal, yield)` before invoking
it, then sources liquidity and requires that authorization to remain unchanged.
The policy enforces its current yield floor and period budget. Failed funding or
minting reverts the policy charge as part of the same transaction.

The operation is a native request `mint` through the adapter's approved guarded
call. After minting, cash must decrease by exactly principal and native PT/YT
balances must increase by exactly principal/yield. The request approval is cleared.
No facility, separate request whitelist, adapter position registry or aggregate
position-value cap is used. Native `burnAll(adapter, adapter)` claims return funds
to the adapter and do not replenish the cumulative funding budget. Policies for
separate executors are independent; duplicate budgets are the curator's responsibility.

### Runtime layout and roles

Both JSON outputs add `sourceCalls` and `sourceAmounts`: the action runtime slots
and the corresponding calculated-amount result slots. They also include
`approveStep`, `operationStep` and `clearApprovalStep`. LL adds `amountInStep`,
`amountOutStep` and, when enabled, `redeemStep`, `redeemApproveStep` and
`redeemClearApprovalStep`; the two redemption approval indices are zero when no
spender is configured. 3F adds `principalStep` and `consumeStep`.

Allocate one runtime entry per stored step. Approval entries encode
`IRecipeExecutor.Permission`; source, operation and redemption entries encode
`IMerkleAdapter.Action[]`. For 3F, `runtime[consumeStep]` is
`abi.encodeCall(IThreeFPolicy.consume, (livePrincipal, liveYield))`; the recipe
checks both values against on-chain authorization. Leave other entries empty. No signed transactions or
runtime action calldata are generated by the offline builder.

Grant these leaf roles to `RecipeExecutor` only, and set its caller to the
provider. A provider with the same direct leaf roles can bypass recipe ordering
and economic bounds by calling `adapter.manage` directly. Curators retain
control of the stored recipe and executor policies.

## Instruction format

The [health-recovery configuration](HEALTH-RECOVERY-RECIPE.md) adds another
strategy using the same engine: a live health trigger, ordered Morpho/Aave
withdrawals, debt repayment, then RWA redemption requests. A separate claim
recipe handles settlement without requiring health to remain below the trigger.
Both have JSON templates and generated runtime slot metadata.

Managed runtime must be canonical `abi.encode(actions)`. Fixed-offset checks inside an
action also require its inner ABI offsets and lengths to be pinned by the accepted leaf.
For invoked calls, check only top-level static words; arbitrary dynamic tails remain
caller-controlled.

Each step has `{ operation, a, b, c, data }`. Results are indexed by step.
Arithmetic and comparison operands refer only to earlier results. The complete
instruction, including its fixed call configuration, is stored on-chain.

| Instruction                            | Configuration                                                                                       | Runtime effect                                                            |
| -------------------------------------- | --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `Constant`, `Input`                    | `a` is a literal or input index                                                                     | Return a uint256                                                          |
| `Read`                                 | Fixed target/query in `data`, result byte offset `a`; optional prior result `b` at query offset `c` | STATICCALL, read a complete uint256 word                                  |
| `Add`, `Subtract`, `Minimum`, `MulDiv` | Prior result indices                                                                                | Checked math; full-precision MulDiv rounds down                           |
| `Equal`, `LessOrEqual`                 | Two prior result indices                                                                            | Revert if comparison fails                                                |
| `Manage`                               | Guard result `a`, ordered leaves in `data`                                                          | If guard > 0, verify exact supplied leaf sequence and call adapter.manage |
| `Approve`                              | Amount result `a`, fixed token/spender/leaf                                                         | Adapter approval, resetting an existing allowance before a nonzero amount |
| `Invoke`                               | Fixed trusted executor and selector                                                                 | Call that entrypoint from the recipe executor                             |
| `Calldata`                             | Runtime slot `a`, byte offset `b`                                                                   | Read the actual static ABI argument before its invocation                 |

`runtime` has one entry per stored step, usually empty. Current proofs are
supplied at execution rather than stored with the steps. Managed actions cannot
send native value; direct executor calls send zero native value and do not
delegatecall. Invoked executors enforce
their own nested authority: `Invoke` is for trusted, configured entrypoints, not
an alternative Merkle verifier.

`Read` leaves the query unchanged when `c` is zero. Otherwise it replaces one
32-byte word at query byte offset `c` with prior result `b`; the word must fit
after the selector. The target, selector and all other query bytes stay fixed.
For Pareto queue redemptions, read the strategy's `epochNumber()`, add one, then
read `userWithdrawalsEpochs(adapter, 0)` with `c = 36` and `b` pointing to that
computed epoch. Use the same epoch result before and after the adapter's native
`approve(queue, amount)` and `queue.requestWithdraw(amount)` calls, and require
the queued-share increase to equal the amount. The stored recipe then works
across epochs without accounts or a caller-chosen receipt query.

`Calldata` offsets must refer to top-level static ABI words. Fixed offsets into
dynamic or nested data do not prove which value the ABI decoder uses, because
the caller can relocate dynamic tails. The LL example reads top-level word four
at byte 100. Deep action parameters are constrained by the adapter's leaf mask
and the measured effects, rather than by raw dynamic-data offsets.

Recipes are reusable. Configure resulting debt/position caps and protocol rate
limits where repetitions matter. A per-run input cap alone is not a cumulative
budget. Exact pre-approval alone does not clear a partial-fill allowance: include
an explicit zero approval or a post-use allowance check when needed.

## Practical limits

The engine executes a fixed sequence in one transaction. It stores the caller
and steps, not intermediate results or execution history. Results exist
only for that invocation. `Equal` and `LessOrEqual` are assertions, not boolean
operators: they revert on failure and return zero on success.

Only `Approve` builds calldata using a calculated amount. For `Manage` and
`Invoke`, the provider supplies complete calldata. A recipe may calculate that
a source must supply 30 USDC, but it does not insert 30 into the withdrawal
call. Its exact balance-delta check rejects any different effect. Numeric input
bounds alone do not bind those numbers to supplied calls: recipes must also
check the relevant static arguments or measured effects. Merkle leaves must
pin recipients, assets, markets and other authority-bearing fields.

| Practical requirement                                        | What the current executor needs                                                                                                                                                             |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Run automatically when health deteriorates                   | An off-chain monitor to submit `execute`; there is no scheduler.                                                                                                                            |
| If a withdrawal reverts, continue with the next source       | A specialized fallback executor. `Manage` can skip a zero guard, but any attempted failed read/call aborts the recipe.                                                                      |
| Borrow and repay a flash loan within a callback              | A callback-capable typed executor invoked through `Invoke`; this engine has no callback entrypoints and blocks reentrant execution.                                                         |
| Redeem now, wait for settlement, then claim                  | Separate request and claim transactions/recipes, as in the recovery example. Cross-chain settlement also needs an external state machine.                                                   |
| Enforce a daily budget, cooldown or one-time execution       | A stateful capability or helper. The engine has no counters or timestamps; per-run limits do not limit cumulative turnover.                                                                 |
| Use an unpredictable returned request ID in a later call     | A typed wrapper or a later transaction. Write return data is discarded and read calldata is fixed. A caller-known ID can be supplied and checked where the protocol exposes suitable state. |
| Iterate over a changing list of pools or redemption requests | A bounded stored list, a replacement recipe or an appropriate helper. There are no runtime-sized instruction loops or jumps.                                                                |
| Send native ETH from the adapter                             | A specialized route. Managed actions reject native value, and direct invocations send zero.                                                                                                 |
| Validate arbitrary dynamic/nested calldata                   | Typed decoding in a trusted executor, or suitable Merkle constraints and postconditions; a fixed byte offset alone is insufficient.                                                         |
| Execute an action missing from the accepted tree             | Curator approval of the leaf and the required role first. A recipe cannot expand adapter authority.                                                                                         |

`Invoke` permits composition with such helpers, but the helper then owns that
additional policy and state. Target/selector matching alone does not validate
its arguments. Curators must select a trusted contract and configure its caller,
roles, limits and signatures appropriately.

The supplied builders impose additional assumptions:

- **Lending:** 6-decimal USDC, an 18-decimal RWA, Aave-style receipt/debt balances
  with at most one base unit of rounding, and immediate RWA delivery. Different
  tokens or asynchronous subscriptions need adjusted checks.
- **Recovery:** one debt asset and unchanged backing collateral. Withdrawing
  collateral from the protected loan or handling several debt currencies needs
  a different recovery calculation. Issuer capacity, pending and claimable
  queries must be verified or normalized through a read lens.
- **Liquid Lane:** the direct recipe requires the exact live discounted quote,
  so price changes between preparation and execution can revert.
- **3F:** factory membership is the only request eligibility check. The recipe
  binds one request and checks exact native PT/YT and cash deltas. Authorization
  changes during funding revert. Policies are per executor; direct adapter calls
  do not consume their budgets.

## Verification

```sh
forge test --match-contract 'Recipe.*Test' -vv
```

The local strategy tests execute the production Merkle adapter, capability,
connector and executors with current proofs and roles. The Aave, issuer, source,
vault/NAV and 3F request fixtures model external state; these tests do not prove
issuer onboarding, live liquidity or a successful mainnet strategy transaction.

`ThreeFExecutingMainnetTest` additionally exercises real factory membership and
native adapter minting at block `25_892_000` when `ETH_RPC_URL` is configured.
