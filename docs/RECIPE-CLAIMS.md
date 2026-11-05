# Claims after settlement

The executor discovers ready requests and rewards, then prepares one claim per execution.
Multiple prepared claims can be batched in one transaction. Native issuer and distributor
contracts enforce entitlement, readiness, replay protection and payout. A failed native claim
reverts the transaction; the recipe does not convert that failure into an idle result.

The `claim` template executes its permitted calls unconditionally. There are no readiness
gates, balance snapshots, output-floor assertions or claimable-ledger checks. Read a value
only when it supplies a native call argument, for example `maxWithdraw(account)` for a
settled withdrawal. For request IDs, epochs and proofs, the executor supplies the authorized
runtime fields. The leaf continues to fix the target, selector, owner and recipient.

Each claim specifies `leaves` and optional `arguments`:

```json
{
  "leaves": ["<permission leaf>"],
  "arguments": [{
    "query": {"target": "<issuer>", "data": "<maxWithdraw(account)>", "offset": 0},
    "offsets": [[4]]
  }]
}
```

`offsets` has one list per leaf, identifying calldata words to fill with that query result.
Calls needing no calculated arguments omit `arguments` and perform no recipe reads.
Use only supported issuer claim methods: an ordinary vault withdrawal is not necessarily
an asynchronous claim, even if both use the same selector.

Merkl receives one reward token, cumulative amount and proof selected by its executor
provider. For 3F, the unchanged RecipeCapability checks `isRequest(request)` and calls
`burnAll(account, account)` on that request. The outer recipe simply invokes that capability.

Claims do not repay debt or initiate another redemption. Payouts already delivered to the
account need no claim; later operations can use that cash directly.

`RecipeClaimsTest` exercises native claims through the production RecipeExecutor and
MerkleAccount using local issuer fixtures. It does not establish live issuer settlement.
