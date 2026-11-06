# Claims after settlement

The executor discovers ready requests and rewards, then prepares one claim per execution.
Multiple prepared claims can be batched in one transaction. Native issuer and distributor
contracts enforce entitlement, readiness, replay protection and payout. A failed native claim
reverts the transaction; the recipe does not convert that failure into an idle result.

The `claim` template executes one permitted call unconditionally, with no reads or checks.
The executor supplies the amount, request ID, epoch or proof through the leaf's authorized
runtime fields. For asynchronous vaults it reads the native `maxDeposit`, `maxMint`,
`maxWithdraw` or `maxRedeem` before preparing the call. The leaf continues to fix the
target, selector, owner and recipient.

Each claim specifies one `leaves` entry:

```json
{ "leaves": ["<permission leaf>"] }
```

Use only supported issuer claim methods: an ordinary vault withdrawal is not necessarily
an asynchronous claim, even if both use the same selector.

Merkl receives one reward token, cumulative amount and proof selected by its executor
provider. For 3F, the unchanged RecipeCapability checks `isRequest(request)` and calls
`burnAll(account, account)` on that request. The outer recipe simply invokes that capability.

Claims do not repay debt or initiate another redemption. Payouts already delivered to the
account need no claim; later operations can use that cash directly.

`RecipeClaimsTest` exercises native claims through the production RecipeExecutor and
MerkleAccount using local issuer fixtures. It does not establish live issuer settlement.
