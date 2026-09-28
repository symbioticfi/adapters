# Pass 2 review record

## Specialty 1: Math and precision

Completed full 1,967-line bundle. No findings or new leads; retained `CREOracle._onReport`, `unchecked-negative-baseline`. The current-value guard and historical-baseline conversion use different report/flow expressions. A negative baseline would become a large unsigned value and can make checked percentage multiplication revert before caching. Supported portfolio history and material harm remain unverified. Cash-backed reserves constrain portfolios with nonnegative positions, but the interface permits net external liabilities. Reviewed delivery skips movement-limit multiplication; the concern is not a universal inability to approve an already cached report.

## Specialty 2: Access control

Completed full 1,946-line bundle. No findings or new leads; no new evidence to re-report the existing lead. Rechecked initialization, proxy upgrades, role administration, multicall caller preservation, self-call checks, exact rejected-payload review, workflow proposal acceptance, cached approvals and consumer/caller checks.

## Specialty 3: Economic accounting

Completed full 1,954-line bundle. No findings or new leads; retained the exact same historical-baseline lead. Deallocation caps prevent a negative projected baseline for flows after preceding-report acceptance. Remaining uncertainty concerns a later snapshot taken before that acceptance, not ordinary post-acceptance flows. Net liabilities mean NAV need not exceed idle cash; the inspected cash-loss invariant fixture does not establish a universal bound for negative net positions. No supported strategy history or material loss was established. Also reviewed delayed reports, fixed stages, losses/gains, replenishment, request changes, amount denomination and active-period usage retention.

## Specialty 4: Execution and ordering

Completed full 1,952-line bundle. No new finding or lead; retained the known historical-baseline sign lead without promotion. Reviewed account preflight, callbacks, self-call restrictions, capability dispatch, migration, multicall, skipped runtime alignment, approval reset/return checks and rollback, pre-transfer budget consumption, delegator transfers and upstream registration failure.

## Specialty 5: State invariants

Completed full 1,963-line bundle. No new finding or lead; retained the known historical-baseline sign lead with authentic-report reachability unverified. Reviewed overlapping requests, cancellation, delayed PnL, synchronization, governance transitions, signatures and approvals. Cash reservations remain backed under documented collateral behavior. The live mock-based historical-baseline regression does not prove a supported history.

## Specialty 6: Periphery and integrations

Completed full 1,946-line bundle. No new findings or leads; retained the historical-baseline sign lead only. Checked register-before-initialize factory semantics, proxy-bound EIP-712 domain, ERC-1271 return validation, local forwarder metadata layout, saved oracle lifecycle, amount budgets, account/executor call context, binding bounds and approval response checks. Dependencies remain contextual review, not a claim of full third-party audit.

## Specialty 7: First principles

Completed full 1,955-line bundle. No new finding; retained the same conditional baseline lead against the frozen source. Reviewed authority, custody, rollback, reserve isolation, commitments and dependency behavior. Independently distinguished current-NAV validation from historical baseline calculation. No complete supported history was established.

## Specialty 8: Paired-path asymmetry

Completed full 1,996-line bundle. No findings or new leads; retained the historical-baseline lead. Compared report/review paths and the distinct signed calculations, then examined all allocation/reserve, capability, signature, workflow, swap, budget and interpreter pairs. No additional inconsistency found. Explicitly distinguished the live checked-cast edit from frozen behavior.

## Specialty 9: Boundaries

Completed full 1,998-line bundle. No findings or new leads; no additional reachability evidence for the known lead. Rechecked ABI and mask bounds, packed fields, runtime alignment, optional approval returns, report lengths/order/freshness, zero budgets and exact rollover boundaries. Verified actual SafeERC20/Address behavior. Did not treat concurrent source or NatSpec edits as part of frozen code.

## Specialty 10: Numerical interaction gaps

Completed full 1,965-line bundle. No new finding or lead; retained the historical-baseline lead without promotion. Checked report/reserve arithmetic, checkpoints, budget periods, recipe values, quotes and policy quantities. No supported history established the lead's prerequisite state.

## Specialty 11: Trust interaction gaps

Completed full 1,959-line bundle. No findings or fresh leads; did not re-report the known lead without new evidence. Reviewed factory identity versus paired custody, dual workflow approval, report authority, bound calls versus account roles, saved authorizations, proxy-bound signatures and connector funding. Actual production Chainlink implementation/permissions remain outside the verified boundary.

## Specialty 12: Flow interaction gaps

Completed full 1,968-line bundle. No findings or fresh leads; did not re-report the known lead without new lifecycle reachability. Reviewed requests/cancellations, reserves, allocations, report review, governance, capability changes, signatures, recipe configuration and connector budgets. Actual delegator transfer order and dependency behavior were checked as context.

## Candidate accounting and gates

All 12 agents returned. One unique (contract, function, class) was independently raised by 8 agents: `CREOracle._onReport`, `unchecked-negative-baseline`. The signed-to-unsigned conversion is present in the frozen code. The current-value check uses a different expression and does not establish the historical sign. Reachability through legitimate liability-inclusive portfolio histories and an unprivileged harmful effect remain unproved. Retained as one unscored LEAD; agreement does not supply the missing evidence. No new candidate or confirmed finding.

The live checked-cast edit was inspected separately and never substituted for the frozen source during this pass. Completeness: 1 unique candidate, 1 retained lead, 0 silently dropped.
