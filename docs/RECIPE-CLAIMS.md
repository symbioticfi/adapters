# Claims after settlement

Use the [`claim` template](../script/recipes/examples/claim.json) to collect independently
settled redemptions, withdrawals, mints or rewards into the MerkleAccount. Requests,
protocol settlement and claims can happen in different transactions. The recipe
does not require debt or a health factor and does not initiate another request.

For each claim group it reads the currently claimable amount and optionally caps
it with `maxAmount`. It reads the output balances and executes the approved
leaves only when the selected amount is positive. It inserts that selected amount
at the configured calldata `amountOffsets`, then checks the
newly received tokens against the configured minimum rates. Existing balances do
not count as proceeds. Every executed group must deliver at least one base unit of
an output token, even if its minimum rate rounds to zero. Groups still awaiting
settlement skip their action, but all configured output queries still run. An
unavailable output token or balance lens reverts the entire execution, including
any earlier ready group. An execution with no proceeds reverts.

A partially settled request can be claimed now and the same recipe run again after
further settlement. The recipe does not require all pending requests to disappear.
A bounded claim can leave already settled amounts for subsequent transactions;
each run selects its amount from the remaining live claimable amount.
For capped groups, the recipe reads the same claimable query after the claim and
requires its decrease to equal the selected amount. A claim that collects more
or less than selected reverts the transaction. The second readiness query still runs when the selected amount is zero.
A reverted claim or failed query still reverts the whole current execution; select
a readiness query that returns zero when its operation is not ready.

## Configure the claim ABI and units

Each group specifies `claimable: {target, data, offset}`, `leaves`, one
`amountOffsets` list per leaf, and `outputs`. Optional `maxAmount` uses the same raw
units as the claimable read: omitted or zero selects the full live amount; a
positive value selects `min(claimable, maxAmount)`. The claimable read is a STATICCALL;
`offset` selects a uint256 word in its returned bytes. Readiness must refer to the
actual custody account and the exact request, epoch or position being claimed.
Leaves must pin the protocol, token, account, recipient/controller and request IDs.

Each output uses:

```text
minimum new token balance = floor(selected amount × minNumerator / denominator)
```

Rates use raw units, including differences in decimals. `denominator` must be
positive. A zero numerator allows an optional reward token to pay nothing, but
another output in the same active group must increase. List each output token once.
Approval or unwrap calls can be included in the same group when they can execute
atomically with the claim; they need their own leaves and proofs.

For native ETH outputs, omit `token` and provide `balance: {target, data, offset}`
instead. Use a trusted lens that returns the MerkleAccount's actual ETH balance,
for example encoded `getEthBalance(account)`. The recipe reads it before and after
the claim and checks the newly received wei; existing ETH cannot satisfy the check.
Specify exactly one of `token` or `balance`. The balance read must measure custody
proceeds, not a pending or claimable entitlement. Native payouts do not require
sending value with the claim action, so the executor's native-value guard stays intact.

For [asynchronous ERC-4626 / ERC-7540](https://eips.ethereum.org/EIPS/eip-7540):

| Claim call                           | Claimable read         | Amount units | Output            |
| ------------------------------------ | ---------------------- | ------------ | ----------------- |
| `mint(shares, account)`              | `maxMint(account)`     | Shares       | Vault share token |
| `deposit(assets, account)`           | `maxDeposit(account)`  | Assets       | Vault share token |
| `redeem(shares, account, account)`   | `maxRedeem(account)`   | Shares       | Underlying asset  |
| `withdraw(assets, account, account)` | `maxWithdraw(account)` | Assets       | Underlying asset  |

The request transfers the assets or shares earlier; the asynchronous claim must
not transfer them again. Do not use reverting asynchronous `preview*` methods or
treat pending requests as claimable. Confirm that the specific vault implements
the selected async interface. `lending-async.json` uses `purchaseReceipt` to
verify a separate subscription request in queued share units; claim the minted
shares with this template after settlement. The plain `lending` example still
checks immediate token delivery.

For ID/epoch claims, keep those identifiers pinned and use empty offset lists when
the claim has no amount parameter. The selected amount then gates the group and sets
its minimum output. Reward calls such as `getReward()` work the same way when a
reliable `earned(account)` or other readiness view exists. A callable claim alone
does not prove that a request is ready or that tokens will arrive.
With a positive `maxAmount`, the readiness query must decrease by exactly the
selected amount, including for calls without an amount parameter. An amountless
call that collects all ready proceeds reverts when readiness exceeds the cap;
it can succeed when the full ready amount fits within the cap. Omitted or zero
`maxAmount` preserves readiness as a gate and minimum-output basis, without a
post-claim readiness-decrease check.

`claimable.bindings` optionally accepts the executor's packed query bindings. If
using input-bound identifiers, the action's approved identifier must match the
query's identifier; the template only inserts the claim amount, not request IDs.

## Generate and execute

Replace the example addresses, reads, rates and leaf hashes, then generate:

```sh
forge script script/recipes/BuildRecipe.s.sol:BuildRecipe \
  --rpc-url "$ETH_RPC_URL" --sig 'run(string,string)' \
  script/recipes/examples/claim.json out/claim-recipe.json
```

The builder resolves `adapter.account()` and writes the committed recipe,
`setRecipe`/`setCaller` calldata, named stages and `claimCalls`. It does not broadcast.
Use a curator-owned RecipeExecutor with the appropriate account leaf roles. At
execution, put ABI-encoded `IMerkleAccount.Action[]` groups in the reported
`claimCalls` runtime slots with current Merkle proofs. Unready slots may be empty.
Run again after later settlements; no background runner is required.
The same configuration also supports repeated capped claims while settled amounts
remain, without rebuilding the recipe between transactions.

## Payouts that arrive without a claim

Some issuers push tokens to the account or settle through an offchain process.
An already completed payout has no same-transaction balance delta to claim. Wait
for actual token delivery, then use the [`health-repay` template](../script/recipes/examples/health-repay.json)
if that cash should repay debt. This template authorizes spending already-held
cash above an explicit `limits.minCashBalance` reserve. It caps repayment by that
available cash, the current target need and `maxRepayment`; it clears approval and
checks the actual cash debit, debt reduction and health. It cannot distinguish
payout cash from other existing cash, so configure the reserve accordingly.

For compatible issuers, `health-claim` can still claim and repay in one transaction;
its normalized pending read includes matured unclaimed principal. When that view
is unavailable, omit `pending` as in `health-claim-ready.json`; the recipe instead
requires the ready amount to decrease by exactly the selected principal. Use standalone
`claim` for other pending conventions, non-debt outputs or separately executed
claims, then `health-repay` when repayment should occur later.

The Liquid Lane recipe checks a new receipt/request and, by default, consumption of
the newly acquired RWA. Set `redemption.retainsRwa` for a cooldown that locks the
tokens in the account; its receipt read must measure new locked entitlement.
It has no absolute receipt-balance cap and does not require a delayed
payout within the swap transaction. Configure its receipt read to match the actual
request outcome, then collect proceeds with the appropriate later phase.

Rebuild saved configurations and apply the new `setRecipe` calldata through the
curator. Previously committed recipe bytes keep their old checks until replaced.
Source preparation now emits ordinary `Call` instructions and always runs.
The restored interpreter rejects historical conditional/cached opcodes 12, 14,
15 and 16; rebuild programs containing those instructions before executing them.

Tests in [`RecipeClaims.t.sol`](../test/adapters/merkle-adapter/RecipeClaims.t.sol)
exercise real MerkleAccount/RecipeExecutor routing with local protocol fixtures.
They do not establish live issuer settlement or deployment compatibility.
