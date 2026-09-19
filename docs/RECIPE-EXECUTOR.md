# Configurable strategy execution

`RecipeExecutor` runs a curator-defined sequence of reads, adapter calls and
checks. The owner stores its steps with `setRecipe`; the provider supplies
amounts, concrete calls and current Merkle proofs on each run. Execution reads
the stored steps directly. Failed checks revert the whole transaction.

The executor holds no strategy assets. Direct protocol calls and approvals run
through `MerkleAdapter`. The adapter checks its current root, leaf roles and
asset limits. The executor adds ordering, amount dependencies and economic
postconditions. `BorrowCapability` remains responsible for health checks.

## Ownership and authorization

1. Deploy an instance through
   `ImmutableFactory(type(RecipeExecutor).creationCode)` using
   `create(abi.encode(curator, adapter))`.
2. The curator calls `setRecipe(recipe)` and `setCaller(provider)`.
3. Grant the executor the recipe's required adapter leaf roles. The provider
   receives no direct leaf roles and cannot call the adapter instead of the recipe.
4. The provider calls `execute(inputs, runtime)` using the stored recipe.

For LL/3F composition, the specialized executor retains the adapter leaf roles.
Set its caller to the recipe executor, and set the recipe executor's caller to
the provider. Both instances are curator-owned. The provider cannot bypass the
outer checks by calling the specialized executor directly.

Setting the recipe caller to zero disables execution. Replacing a recipe needs
one curator transaction; changing a permitted venue still requires an accepted
adapter leaf. A root update that retains the leaves only requires new proofs,
not a recipe update. Configuration setters cannot run during execution.

`setRecipe` replaces the whole stored `steps` array and emits it in `SetRecipe`.
The public `steps(index)` getter returns one instruction; the event provides the
complete ordered list. Execution always uses the configuration stored when the
transaction runs, including any owner update made after it was submitted.

## Define recipes from JSON

Fill in the named addresses, accepted leaves and limits in
[`lending.json`](../script/recipes/examples/lending.json) or
[`liquid-lane.json`](../script/recipes/examples/liquid-lane.json), then run:

```sh
forge script script/recipes/BuildRecipe.s.sol:BuildRecipe \
  --sig 'run(string,string)' \
  script/recipes/examples/lending.json out/lending-recipe.json

forge script script/recipes/BuildRecipe.s.sol:BuildRecipe \
  --sig 'run(string,string)' \
  script/recipes/examples/liquid-lane.json out/liquid-lane-recipe.json
```

The output contains the encoded recipe, `setRecipe` and `setCaller` calldata,
and constructor arguments. Supplying a factory address also generates
`factory.create` calldata. The script needs no RPC, key or broadcast and sends
no transactions. The supplied examples deliberately use dummy addresses and
leaf hashes: replace them with the selected adapter's actual configuration.
The LL executor's source order, leaves and signed discounts are configured
through its existing setters and signature flow.

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

| Order | Defined action                                             | Enforced relationship                                                                                    |
| ----- | ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| 1     | Read wallet, collateral receipt and debt balances          | Positive inputs, supply limit, remaining debt headroom                                                   |
| 2     | Approve LBTC and supply the fixed Aave pool                | Exact LBTC debit; collateral receipt increases by that amount, within one base unit                      |
| 3     | Borrow USDC through the approved `BorrowCapability` leaf   | Health check succeeds; measured USDC inflow equals the selected borrow amount                            |
| 4     | Read variable debt                                         | Debt increase matches the measured inflow within one base unit; resulting total debt stays below its cap |
| 5     | Approve the issuer for measured borrowed USDC and purchase | Final USDC balance equals its pre-borrow balance; minimum actual RWA output is received                  |
| 6     | Clear both approvals                                       | No residual pool or issuer allowance from this recipe                                                    |

If the adapter already holds 10,000 USDC and borrows 30,000, only the additional
30,000 funds the purchase; the original 10,000 remains. A second run cannot
silently exceed the total-debt cap. The recipe does not grant the provider the
health-floor setter role.

The five leaves are LBTC approval, Aave supply, checked borrowing, USDC approval
and issuer purchase. Pin pool, token, spender, account, recipient, rate mode and
health query in those leaves; mask only approved amount fields. The runtime
slots are the named `LendingRecipe.Register` values. Approval slots contain
`abi.encode(IExecutor.Permission)`; each managed slot contains
`abi.encode(IMerkleAdapter.Action[])` with exactly the configured leaf.

This definition expects an immediate purchase. For asynchronous subscriptions,
change the output read to the issuer's verifiable pending entitlement and use a
separate claim recipe after settlement. A successful request is not delivery of
the RWA.

## 2. Obtain liquidity, close an LL swap, optionally redeem

The executable definition is
[`LiquidityRecipe.liquidLane`](../script/recipes/LiquidityRecipe.sol). It invokes
the existing `LiquidLaneExecutor.swap` with the original typed discount and
protocol signatures. The recipe adds limits on the actual RWA amount, the
funding quote, resulting holdings and the receipt produced by redemption.

```text
LiquidLaneExecutor configuration:
  caller         = RecipeExecutor
  sources        = [approved withdrawal source, approved borrowing source]
  approvalLeaf   = USDC approval to the fixed connector
  operationLeaf  = connector swap for the fixed RWA and recipient
  postActionLeaves[RWA] = [RWA approval to issuer, issuer redemption]

Recipe configuration:
  maxAmountIn        = 100 RWA in base units
  maxFundingAmount   = 100 USDC in base units
  receipt minimum   = 1 claim unit per RWA unit, adjusted for decimals
  maxReceiptBalance = curator's outstanding claim limit
```

The provider supplies the complete signed `swap` calldata in runtime slot 11.
The recipe reads the actual top-level `amountIn` argument, checks its cap, and
checks the connector's gross quote for the maximum amount against the funding
limit. The gross cap is conservative: even a discounted smaller fill is rejected
if the full configured size's gross quote exceeds it.

The typed executor consumes idle spendable assets first, then sources in order.
For a 100-unit funding requirement with no idle funds, a first source with 30
units supplies exactly 30; the second supplies 70. Each source must deliver its
calculated amount, the connector must spend exactly the prepared funding, and
post-actions must consume exactly the swapped RWA amount.

The outer recipe then checks that the adapter received enough issuer claim
tokens and that its total claim balance remains within the cap. A burn without
a claim fails and rolls back the liquidity sourcing and swap as well.

To disable redemption, the curator sets the typed executor's post-action list
to empty and configures the outer receipt read to the RWA itself. To use an
issuer with a scalar request-accounting getter instead of claim tokens, replace
the two receipt `Read` instructions with that fixed getter. For immediate cash
redemption, measure proceeds around the redemption group; a before/after USDC
read around the whole flow also includes withdrawals and the swap payout.

The operation leaf must pin the same RWA and connector used by the quote read,
and the intended payout recipient. The nested executor's configuration remains
curator-controlled. The receipt cap limits outstanding exposure, not lifetime
turnover; use issuer/adapter rate limits when a time-based budget is required.

For 3F, `LiquidityRecipe.threeF` uses the same outer executor and runtime slot 11
with `ThreeFExecutor.mint` calldata. Its configuration fixes the request, maximum
principal, minimum yield and total 3F-position cap. It checks the actual request,
principal and yield arguments, then requires the adapter's 3F position assets to
increase by exactly the principal. The typed executor retains ordered funding
and exact spending checks; the capability validates the live request, deadline,
whitelist and period budget. A valuation change that prevents the exact position
delta conservatively reverts. This builder is available in Solidity alongside
the LL builder; the JSON tool exposes the two primary templates above.

## Instruction format

The [health-recovery configuration](HEALTH-RECOVERY-RECIPE.md) adds a third
strategy using the same engine: a live health trigger, ordered Morpho/Aave
withdrawals, debt repayment, then RWA redemption requests. A separate claim
recipe handles settlement without requiring health to remain below the trigger.
Both have JSON templates and generated runtime slot metadata.

Each step has `{ operation, a, b, c, data }`. Results are indexed by step.
Arithmetic and comparison operands refer only to earlier results. The complete
instruction, including its fixed call configuration, is stored on-chain.

| Instruction                            | Configuration                                           | Runtime effect                                                            |
| -------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------------------------- |
| `Constant`, `Input`                    | `a` is a literal or input index                         | Return a uint256                                                          |
| `Read`                                 | Fixed target/query in `data`, result byte offset in `a` | STATICCALL, read a complete uint256 word                                  |
| `Add`, `Subtract`, `Minimum`, `MulDiv` | Prior result indices                                    | Checked math; full-precision MulDiv rounds down                           |
| `Equal`, `LessOrEqual`                 | Two prior result indices                                | Revert if comparison fails                                                |
| `Manage`                               | Guard result `a`, ordered leaves in `data`              | If guard > 0, verify exact supplied leaf sequence and call adapter.manage |
| `Approve`                              | Amount result `a`, fixed token/spender/leaf             | Adapter approval, resetting an existing allowance before a nonzero amount |
| `Invoke`                               | Fixed trusted executor and selector                     | Call that entrypoint from the recipe executor                             |
| `Calldata`                             | Runtime slot `a`, byte offset `b`                       | Read the actual static ABI argument before its invocation                 |

`runtime` has one entry per stored step, usually empty. Current proofs are
supplied at execution rather than stored with the steps. Managed actions cannot
send native value; direct executor calls send zero native value and do not
delegatecall. Invoked executors enforce
their own nested authority: `Invoke` is for trusted, configured entrypoints, not
an alternative Merkle verifier.

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
- **Liquid Lane:** the funding bound quotes the configured maximum RWA amount;
  it can conservatively reject an otherwise acceptable smaller discounted fill.
- **3F:** an exact position-value increase is required; valuation changes or
  rounding can conservatively reject execution.

## Verification

```sh
forge test --match-contract 'Recipe.*Test' -vv
```

The local strategy tests execute the production Merkle adapter, capability,
connector and executors with current proofs and roles. The Aave, issuer, source,
vault/NAV and 3F request fixtures model external state; these tests do not prove
issuer onboarding, live liquidity or a successful mainnet strategy transaction.
