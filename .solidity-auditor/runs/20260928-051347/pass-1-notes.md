# Pass 1 review record

## Specialty 1: Math and precision

Completed full 1,940-line bundle and supporting context. No confirmed finding; two raw leads:

- `MerkleAdapter._allocate / deallocate`, `unchecked-signed-downcast`: checkpoint writes explicitly narrow signed values to `int208`. Practical supported-collateral reachability is unverified. Suggested checked casts. The raw agent's claim that existing boundary tests require SafeCast failures is not current: these tests changed concurrently and are not evidence for a vulnerability.
- `CREOracle._onReport`, `unchecked-negative-baseline`: historical baseline converts signed arithmetic to `uint256`, while the separate current-value check does not establish the sign of that historical baseline. Normal-operation reachability is unproven. Suggested checked signed-to-unsigned conversion. The raw agent's cited mock-based negative-baseline test was changed concurrently and is not current evidence.

These are unjudged candidates pending completion of all twelve specialties. A raw lead is not a validated finding.

## Specialty 2: Access control

Completed full 1,919-line bundle, matching interfaces and inherited code. No findings or leads. Reviewed proof-plus-role authorization, mask commitments, self-call restrictions, account/delegator authority, oracle forwarder/workflow metadata, exact rejected-report review, dual approval for workflow registration, initialization atomicity, multicall caller preservation, proxy migration and reverting static delegation.

## Specialty 3: Economic accounting

Completed full 1,927-line bundle and supporting interfaces, delegator transfer paths and accounting tests. No confirmed findings or actionable leads. Reviewed report-gated release, later cash staging, cancellation reserves, current NAV reconciliation, fixed-period budgets, recipe commitments and policy consumption. Rejected intentional reusable discounts, saved approvals, period-boundary budgets and token behavior outside documented collateral assumptions.

## Specialty 4: Execution behavior

Completed full 1,925-line bundle and factory, proxy, multicall, adapter and delegator context. No confirmed finding. Raw lead `MerkleAdapter._allocate/deallocate`, `flow-checkpoint-truncation` describes the same unchecked `int208` narrowing as specialty 1, with no established supported balance or actor path. Reviewed recipe commitments, final bound leaves, skipped runtime alignment, preflight authorization, reentrancy, transfer ordering and atomic initialization.

## Specialty 5: State invariants

Completed full 1,936-line bundle and supporting code. No confirmed finding. Raw lead `MerkleAdapter._allocate/deallocate`, `unchecked-flow-narrowing` describes the same unchecked `int208` narrowing and explicitly requires values outside the documented range. Suggested the same SafeCast changes as specialty 1. Reviewed staged/released cash backing, push reserves, payout ordering, batch cutoffs, accepted/rejected oracle transitions, capability removal, signature persistence and budget rollover.

## Specialty 6: Periphery and integrations

Completed full 1,919-line bundle and matching interfaces, lifecycle inheritance and selected test context. No findings or retained leads. Reviewed budget consumption/reconfiguration, bound recipe calls, padded Merkle hashing, account-only connector signatures, exact workflow acceptance, registration rollback and fixed-code factory creation.

## Specialty 7: First principles

Completed full 1,928-line bundle and context. No confirmed finding. Raw lead `MerkleAdapter._allocate/deallocate`, `unchecked-flow-narrowing` again identifies the same unsupported-range truncation. No practical supported-asset reachability was established. Reserve accounting, recipe commitments, masks, self-call restrictions, saved capabilities, workflow identity and reusable discount policies produced no separate candidate.

## Specialty 8: Paired-path asymmetry

Completed full 1,969-line bundle and context. No findings or retained leads. Compared allocation/deallocation, staging/release, normal/reviewed reports, capability add/remove, direct/signed swaps, token add/remove, budget view/consume/configure and executor/capability recipe paths. Treated explicit casts as truncating; did not retain an unsupported-range-only finding.

## Specialty 9: Boundaries

Completed full 1,971-line bundle and context. No findings or leads. Reviewed token return handling, recipe byte bounds and packed fields, hash-plan buffers, partial words/selectors, oracle ABI/freshness limits, initialization, budget deadlines and factory failure cases. Verified vendored SafeERC20 and Address reject no-code targets; contrary generic bundle claims were not used as evidence.

## Specialty 10: Numerical interaction gaps

Completed full 1,938-line bundle and supporting dependencies. No findings or leads. Reviewed flow-adjusted NAV and transfer boundaries, loss caps, skipped operations, amount denomination, budget rollback, ratio rounding and signed/unsigned range assumptions.

## Specialty 11: Trust interaction gaps

Completed full 1,932-line bundle and actual inherited code. No findings or leads. Reviewed vault/account custody, workflow authentication, recipe commitments plus account authorization, account-only connector funding, and governance changes affecting saved permissions.

## Specialty 12: Flow interaction gaps

Completed full 1,941-line bundle and dependencies. No findings or leads. Reviewed lifecycle transitions across funding, staging, valuation, release, workflow changes, capabilities, connector policies and factory initialization.

## Candidate accounting and gates

All twelve tasks returned. Three distinct (contract, function) locations from raw candidates are accounted for below. Shared flow-cast candidates were canonicalized as `unchecked-flow-narrowing`, then separated by the two actual functions rather than the agents' synthetic combined function names.

1. `MerkleAdapter._allocate`, `unchecked-flow-narrowing`: the cast truncates (source evidence), but the proposed path needs an unsupported cumulative flow outside int208 (approximately 2.06e62 base units). No plausible supported collateral or material unprivileged route was established. REJECTED under the skill's implausible-precondition exclusion; not promoted by repeated agent agreement.
2. `MerkleAdapter.deallocate`, `unchecked-flow-narrowing`: same unsupported numeric boundary on the separate outflow writer. REJECTED for the same reason. This does not claim the casts are checked.
3. `CREOracle._onReport`, `unchecked-negative-baseline`: ALLOWS the explicit signed-to-unsigned conversion; the current-value guard checks a different expression. Normal-operation historical reachability is UNCERTAIN. No unprivileged trigger or material harm is proved. Retained as an unscored LEAD only, not a finding. The normal percentage multiplication is checked, while reviewed reports bypass that calculation. Existing test citations that drifted during the audit are excluded from the evidence.

Completeness: 3 unique (contract, function) candidates accounted for: 1 lead and 2 rejected candidates. No confirmed finding. The retained lead is a question for source-level follow-up, not an established vulnerability or failed regression.
