# Native claim selection

`ClaimReadiness` is a stateless view helper. It returns native owner-ledger
facts; it never claims, transfers, approves, or substitutes for a permission.
The committed recipe binds the returned identity to the account-context action
and checks its token and ledger effects. The helper address must be explicitly
configured after deployment; no deployed address is assumed.

## Completed requests

`nextNoon(handler, account)` scans the owner's numbered request ledger in
ascending order. It selects the first positive, unclaimed request whose native
cooldown has elapsed. It returns `(id, amount)`. ID zero is valid: the separate
amount word is the execution gate and the exact USN output floor.
Use `noonReady(handler, account, id)` bound to that selected id for readiness
checks before and after the claim. It returns zero after the native claimed
flag is set, even when the request keeps its historical amount.

`nextPareto(queue, account, deposit)` scans epoch zero through the strategy's
next epoch. Deposit completion requires a nonzero epoch price, no pending
deposits and no unfinalized prefunded deposits. Withdrawal completion requires
a nonzero withdrawal price and no pending settlement cash. It returns the
epoch and the whole native owner ledger amount. That amount gates the claim;
it is not a quoted output amount.
Use `paretoEpochReady(queue, account, deposit, epoch)` bound to the selected
epoch for readiness checks. Re-reading the next-epoch selector after claiming
would inspect a different request and cannot prove the selected entry cleared.

`paretoReady(cdo, account, instant)` covers direct receipt claims. Normal claims
respect the native epoch wait (or pool-close mode), include open and settled
APR0 principal plus finalized net interest, and require sufficient strategy
cash for the entire claim. Instant claims require the CDO's instant-claim
switch and sufficient cash. Neither path selects a partial payment.

A claim clears its native owner entry. A subsequent helper read selects the
next completed entry, skipping entries that are still pending. Unroll a bounded
number of claim groups per transaction or repeat the scheduled recipe until
all readiness gates are zero. One successful transaction does not imply every
request was claimed; the configured groups bound progress per transaction.

`threeFReady(request, account)` reads native withdrawal availability, the owner's
full PT/YT balances and their native conversion. It returns the whole positive
asset payout, or zero for pending, empty or zero-value positions. Bind it as the
claim gate and asset output floor for `burnAll(account, account)`. Each configured
request needs its own fixed-target burn permission and claim group; selecting a
new mint request does not grant its future burn permission or expand claim scope.

The complete Noon request count and Pareto epoch scope must fit
`MAX_CLAIM_SCAN` (4096). Larger scopes revert rather than reporting an exhausted
ledger. This is an explicit supported-scope limit, including cleared history;
it is not a cursor or an instruction to omit earlier outstanding rights.

## 3F mint authorization ownership

Vault-solver's `threef-merkle` solver owns auction discovery, offers, authorization
selection and lease validation. `ThreeFExecuting` accepts its execution-time
request, principal and yield inputs. The guarded mint verifies the factory,
facility intent, funding pair, policy budget, current authorization, approvals
and exact cash/PT/YT changes in the transaction. The claim helper only supplies
withdrawal readiness for explicitly permissioned requests.
