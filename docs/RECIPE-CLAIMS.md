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
any earlier ready group. When every group is waiting, execution can succeed without
work. The claim template and `ClaimRecipe.build(account, claims)` use this behavior
for all claim recipes; the
[`claim-conditional` example](../script/recipes/examples/claim-conditional.json)
shows two independent groups.

A generic keeper can simulate the exact authenticated program and wait when
all managed groups have zero gates. Failed reads, malformed active runtime and
failed economic assertions remain errors; never translate `CheckFailed` into
idle. A request ID of zero remains a valid identity when its independent readiness
query returns a positive amount. Pin or bind the same identity in the query and
authorized action.

Manual on-chain execution of an all-empty claim recipe can succeed without useful
work. Automatic waiting is a keeper decision after successful simulation.

For a group with a minimum rate of one or more, its minimum checks prove that a
positive selected amount delivers positive new output. Fractional and optional-only
groups require their largest fresh output delta to be at least
`min(selected amount, 1)`. Every output snapshot, delta and checked minimum
calculation remains in place. There is no overall progress aggregation.

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

For equal positive rate factors `minNumerator == denominator == d`, the builder
uses the selected amount directly only when `maxAmount > 0`, `d` fits `uint216`
and `maxAmount <= floor(uint256.max / d)`. The existing cap conversion still
requires `maxAmount` to fit `uint216`. Since `selected <= maxAmount`, this proves
the original checked product cannot overflow and `floor(selected * d / d)` equals
`selected`, including zero. Uncapped claims, unsafe caps, unequal rates and invalid
literal widths retain their original calculation or configuration error. Each
omitted `MUL_DIV` removes one instruction and 192 ABI bytes; fresh output deltas,
exact capped readiness debits and active positive-output checks are retained.

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

`RecipeERC7540Test` executes Curator-generated request, mint-claim and asset-claim
programs through `RecipeExecutor` and `MerkleAccount`. The standard flows need no
issuer-specific executor provider: request sizing is committed in the recipe,
claims bind fresh `maxMint` or `maxWithdraw`, and recipients/controllers are fixed
to the account. Claiming requires no new asset approval. These local fixtures
verify encoding and execution, not live Lagoon settlement or portfolio valuation.
Do not infer economic ownership from a paused vault's zero `max*` result; that is
a separate accounting concern.

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

`selectedId: {target, data, offset}` optionally reads a live request or epoch ID.
`claimableIdOffsets` inserts that result into the readiness query and `idOffsets`
inserts the identical result into each claim action. These offsets are calldata
byte offsets, including the selector. Readiness gates execution independently of
the identifier, so ID zero remains valid. A pinned ID is suitable for a particular
claim; automation across new requests uses the live selector. `claimable.bindings`
also accepts packed query bindings.

An output may supply `minimum: {target, data, offset}` for a live full-claim
minimum, such as the complementary async ERC-4626 `maxMint` or `maxWithdraw`
getter. The read happens before the claim. It cannot be combined with a positive
`maxAmount`, because the full entitlement need not describe a capped payout.
All quantities use raw integer token units.

`ClaimReadiness.nextNoon(handler, account)` and
`nextPareto(queue, account, deposit)` return `(id, entitlement)` at offsets zero
and 32. They scan complete bounded owner scope and revert when the scan bound
cannot cover it. The helpers only read; the permissioned claim still runs through
the MerkleAccount. Repeat groups to consume several ready entries in one recipe;
a fresh selector read sees each preceding claim's ledger changes. A fixed number
of slots is bounded progress, and the executor must repeat confirmed executions
until fresh simulation finds no ready requests. Merkl proof discovery remains an
offchain witness provider; these ledger helpers do not discover Merkl proofs.

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
if that cash should repay debt. This template spends available account cash up to
the current target need and `maxRepayment`; it clears approval and checks the actual
cash debit, debt reduction and health. It treats existing cash and payouts equally.

Execute ready requests through the standalone `claim` recipe, then run
`health-repay` after cash is available. There is no combined claim-and-repay template.

The Liquid Lane recipe checks a new receipt/request and, by default, consumption of
the newly acquired RWA. Set `redemption.retainsRwa` for a cooldown that locks the
tokens in the account; its receipt read must measure new locked entitlement.
It has no absolute receipt-balance cap and does not require a delayed
payout within the swap transaction. Configure its receipt read to match the actual
request outcome, then collect proceeds with the appropriate later phase.

Tests in [`RecipeClaims.t.sol`](../test/adapters/merkle-adapter/RecipeClaims.t.sol)
exercise real MerkleAccount/RecipeExecutor routing with local protocol fixtures.
They do not establish live issuer settlement or deployment compatibility.

For 3F, a reusable RecipeCapability leaf first requires
`requestsFactory.isRequest(request) == true`, then calls
`burnAll(account, account)` on that same runtime request. The request is an input,
not an individually whitelisted call target. A nested account self-call lets the
recipe bind the checked address into the burn target while keeping the selector,
owner, receiver and program fixed. Requests created after root acceptance use the
same leaf.

`ClaimReadiness.threeFReady(request, account)` returns the matured PT/YT asset
entitlement. Bind the readiness query and claim to the same runtime input and
require the same newly received funding asset amount. There is no burn amount
argument. The host discovers requests and chooses ready ones; a successful factory
membership check is not an inventory-completeness proof. Curator's generic Claims
builder generates this runtime-bound recipe against the existing contracts.
