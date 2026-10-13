# Health recovery strategy

Saved `RecipeExecutor` configurations implement the separate health recovery phases:

- [`health-recovery.json`](../script/recipes/examples/health-recovery.json):
  low health → Morpho withdrawal → Aave withdrawal → repay → ordered RWA requests.
- [`health-claim.json`](../script/recipes/examples/health-claim.json):
  claim settled requests → repay the remaining need → retain surplus cash.
- [`health-repay.json`](../script/recipes/examples/health-repay.json):
  repay cash already received in an earlier transaction, preserving an explicit reserve.

Use the standalone [`claim` template](RECIPE-CLAIMS.md) for independent mints,
withdrawals, redemptions and rewards that need their own settlement/claim phase.

The recovery example triggers at health factor **≤1.25**, targets **1.50**, and caps newly
funded recovery at **100 USDC per execution**. These are illustrative limits.
Every address and leaf is a dummy value to replace with an actual accepted
strategy. Names describe the source order; executable behavior comes from the
fixed read calldata and approved leaves.

## Generate configuration transactions

```sh
forge script script/recipes/BuildRecipe.s.sol:BuildRecipe \
  --rpc-url "$ETH_RPC_URL" \
  --sig 'run(string,string)' \
  script/recipes/examples/health-recovery.json out/health-recovery.json

forge script script/recipes/BuildRecipe.s.sol:BuildRecipe \
  --rpc-url "$ETH_RPC_URL" \
  --sig 'run(string,string)' \
  script/recipes/examples/health-claim.json out/health-claim.json
```

The script resolves the custody account from the configured adapter at the selected
RPC and emits the recipe, constructor arguments, optional factory-create calldata,
`setRecipe` and `setCaller` calldata. It sends no transaction and needs no private
key. Each output includes the standard readable `manifest`, bound to its
`recipeHash`, and lists `sourceCalls`, `requestCalls`,
`claimCalls`, `approveStep`, `repayStep` and `clearApprovalStep` for assembling
execution payloads.

Use separate curator-owned instances for the phases needed, each with its own recipe and the provider as
caller. Grant recovery leaves to the recovery instance and claim/repayment
leaves to the claim instance. The provider needs no direct account leaf roles.
Submit executions when liquidity or settlement is ready; no configuration schedules
itself or includes a keeper implementation.

## Recovery behavior

The recipe reads the protected position's debt and health on-chain. For a single
debt asset and unchanged collateral, its target repayment is:

```text
need = debt - floor(debt × min(health, targetHealth) / targetHealth)
budget = min(need, maxRepayment)
```

For the initial recovery snapshot, the trigger check establishes
`health <= triggerHealth < targetHealth`. Its budget therefore uses the checked
`debt - floor(debt × health / targetHealth)` directly. Later snapshots, claims
and settled-cash repayment retain `min(health, targetHealth)`. The saved recovery
example has 96 instructions, one fewer than before, saving 160 encoded bytes.

At the O05 checkpoint, isolated recovery gas decreased from 1,109,260 to
1,105,658; conditional two-source recovery from 1,128,070 to 1,124,516; and
one-active-group recovery from 760,067 to 756,521. Claim and settled-cash
repayment gas and encoded recipes stayed identical.

The health-factor query and debt query must describe the same position and debt
denominator. A token balance for only one reserve cannot stand in for a health
factor that aggregates several debt assets. Capacities and debt use raw repayment
asset units; health factors use 1e18 precision.

For every source in the configured order, the recipe:

1. Reads its current withdrawal capacity.
2. Computes `take = min(remainingBudget, capacity)`.
3. Executes that source's approved group only if `take > 0`.
4. Requires the actual repayment-token inflow to equal `take`.

It then approves and repays exactly the newly obtained cash, clears the
allowance, checks the cash debit and debt reduction, and preserves preexisting
cash. Indexed debt may differ by at most the configured zero-or-one-base-unit
tolerance. Source calls must not increase debt or worsen the protected health
factor before repayment; withdrawals of that position's backing collateral are
therefore not supported by this template. If a source backs a different debt,
its own capacity query and authorized withdrawal must protect that position too.

After repayment, the recipe recomputes the unmet need and subtracts **all
configured pending redemptions**, including matured but unclaimed requests.
It then caps the uncovered need by the execution budget left after fresh repayment.
Pending from earlier runs does not consume this execution's budget. Only the
uncovered part is requested from RWAs, in order. Each request group
must increase pending repayment-asset entitlement by exactly its calculated
amount, stay within the RWA-token consumption ceiling, and leave its issuer
allowance at zero. A typical group is `approve → request → approve(0)`.

New cash plus new requests must be positive. A repeated run cannot queue the
same already-covered need again. Newly withdrawn cash can still be repaid while
requests are outstanding; later surplus claims remain in the account.

The target guides the amount; it is not a promise that every run restores
health. Partial repayment/request progress is retained when all configured
capacities are exhausted. An asynchronous request does not count as cash or
health improvement. `maxRepayment` is a per-execution cap, not a daily budget.

## Claim behavior

The claim recipe has no low-health trigger. For each configured issuer it reads
the ready principal and selects `min(ready, maxAmount)`. Omit `maxAmount` or set it
to zero to select all ready principal. Its group must consume exactly that selected
amount and return at least `floor(selected × minAssetPerClaimWad / 1e18)` repayment
tokens. Every positive claim must return at least one base unit of that token.

A claim with `minAssetPerClaimWad == 1e18` uses the selected principal directly
as its output minimum only when `maxAmount > 0` and
`maxAmount <= floor(uint256.max / 1e18)`. The cap must still fit `uint216` through
its existing literal conversion. The selected amount is bounded by that cap,
so the original checked product is safe and the identity minimum is exact. The
repayment cap cannot establish this bound: a claim may collect surplus above
`maxRepayment`. Uncapped or unsafe-cap claims retain checked multiplication;
other rates retain their existing floor and positive-output checks. Each removed
claim-minimum `MUL_DIV` saves one instruction and 192 ABI bytes. Both pending
accounting modes retain exact selected-principal debits, fresh cash deltas and
all approval/repayment barriers.

The saved pending-free capped example decreases from 57 instructions / 11,104
ABI bytes to 55 / 10,720. The frozen local conditional benchmark with pending
reads decreases from 59 / 12,384 to 57 / 12,000 and from 639,433 to 631,377
executor gas. That comparison used an uncapped health-claim control of 607,602 gas,
before the reserve-comparison optimization described below.

When `pending` is configured, the group must reduce that normalized pending
principal by exactly the selected amount. Some issuers remove pending principal
when settlement makes it ready, before the later claim transaction. For those
issuers, omit the claim's `pending` read or use `{ "target": "0x0000000000000000000000000000000000000000", "data": "0x", "offset": 0 }`.
The recipe then requires the `claimable` read to decrease by exactly the selected
amount. That read must describe consumable principal for the same requests as the
claim group, in the same units as `maxAmount`; a boolean ready flag cannot measure
a partial claim. Actual received cash and the configured rate minimum are checked
in both modes.

It repays the minimum of fresh claimed cash, the current target requirement and
the per-execution cap. Old cash is preserved and any excess remains available.
The old-cash guarantee follows from the checked fresh-cash difference, the
repayment bound and final cash conservation: the actual debit equals the selected
repayment, and the fresh cash snapshot after approval cleanup equals the cash
before repayment minus that debit. A separate final old-cash comparison adds no
constraint. Approval and cleanup effects still pass those retained checks.
Debt cannot increase and health cannot worsen. Configured pending principal and
claimable principal must use the same accounting basis; rates may bound a settlement
shortfall, but pending face value is not guaranteed future cash.

With `optimizations.skipUnusedReads=true`, recovery and claim recipes reuse the
initial cash snapshot as the first group's delta baseline, then carry each
post-action balance into the next group. A skipped group preserves the previous
balance. Two configured groups use three cash-read instructions before repayment
approval; execution now makes all three balance calls even when a group is skipped.
Legacy conditional-read helpers select fallback values with arithmetic and do
not skip queries; unavailable source or issuer queries still revert. Health and debt remain fresh, and repayment still refreshes cash after
approval and cleanup. The default `false` option preserves ordinary recipe bytes.

For example, using fixture amounts:

| Run               | Action                                                                                    | Debt / pending afterward                        |
| ----------------- | ----------------------------------------------------------------------------------------- | ----------------------------------------------- |
| Start             | Debt 300 USDC, health 1.00, target 1.50                                                   | Needs 100 USDC                                  |
| Recovery          | Withdraw 30 from Morpho, 20 from Aave, repay 50; request 40 from RWA A then 10 from RWA B | Debt 250; pending 50; health 1.20               |
| Repeated recovery | Both sources empty; existing pending covers the gap                                       | No new requests; no-progress execution reverts  |
| Claim A           | Claim and repay 40                                                                        | Debt 210; pending 10; health approximately 1.43 |
| Claim B           | Claim and repay 10, despite health now being above the trigger                            | Debt 200; pending zero; health 1.50             |

## Query and execution requirements

`health-repay` performs no claim, source withdrawal or redemption request. Its
`limits.minCashBalance` protects a configured cash reserve; only cash above that
amount may repay the current target need, up to `maxRepayment`. It has no low-health
trigger. With no debt need or no available cash, execution reverts. Cash received
earlier cannot be identified by its provenance, so this phase explicitly authorizes
spending already-held cash. Its JSON uses empty sources, redemptions and claims arrays.
The positive repayment check excludes cash at or below the reserve; repayment is
bounded by cash minus the reserve. Exact cash-debit equality and the final cash
snapshot after approval cleanup therefore enforce the reserve without repeating
that comparison. The reserve literal still rejects values wider than 216 bits.
Zero reserve already omitted the final comparison and keeps identical recipe bytes.

Each omitted comparison saves one instruction and 160 ABI bytes. In the isolated
local executor fixtures, the ordinary health claim fell from 607,602 to 603,674
gas, the bounded claim from 631,377 to 627,341 and settled-cash repayment from
339,278 to 335,718. Recovery remained 1,105,759 gas and the zero-reserve repayment
control remained 344,540 gas. These measurements do not establish live-chain costs.

Each read is `{ target, data, offset }`: fixed STATICCALL calldata and the byte
offset of its uint256 result. The sample uses existing Aave health and liquidity
lens signatures for those reads. Its `availableRedemptionAssets(address)`,
`pendingAssets(address)` and `claimableAssets(address)` signatures describe
normalized **example issuer queries**, not an API implemented by every RWA.
Replace them with verified issuer-specific calls or a suitable read lens.

Recovery-phase pending reads must cover distinct requests for the same repayment
token, include matured unclaimed requests, and avoid double-counting. If an issuer
separates pending and ready balances, its recovery query must normalize their sum;
the optional claim pending read is a separate consumption check. Use conservative proceeds
estimates where supported. Capacity must exclude already committed holdings.
Changing prices or settlement haircuts can leave an additional recovery need.
For an 18-decimal RWA worth one 6-decimal USDC, `maxTokenPerAssetWad = 1e30`.

The JSON source entries contain `amountOffsets`, with one offset list per leaf.
The builder inserts each calculated withdrawal amount into those words. Set
`amountOffsets.repay` to the repayment amount word(s); the Aave example uses `[36]`.
Each offset must fit uint32. The builder packs it with the operand into one uint256;
the resolved withdrawal or repayment amount retains all 256 bits.
The provider can leave these words as placeholders. These offsets apply only to
verified arguments denominated in the repayment asset. Issuer request and claim
calldata remains issuer-specific; receipt/balance checks constrain its effects.

The curator commits each recipe with `setRecipe`; its hash and event block are
stored and the full recipe is emitted. The provider calls
`execute(queries, steps, inputs, runtime)` with the matching recipe; `inputs` is empty
because amounts come from on-chain reads. `runtime` contains one entry per
`Manage` or `Approve` instruction. Put encoded `IMerkleAccount.Action[]` groups
in the reported source/request/claim/repay runtime slots and
`abi.encode(dataMask, proof)` in both approval slots (`bytes dataMask`,
`bytes32[] proof`). The generated `runtimeSteps`
array maps runtime slots to instructions. Reads, calculations and comparisons
are chronological instructions without runtime entries. Numeric results use
absolute instruction indices; repeated reads share query templates. All
managed actions require the executor's leaf role and a current proof. Leaves
must pin the actual market, asset, account, recipient and spender.

Zero-amount groups skip `Manage`, but their surrounding reads/checks still run.
The repayment approval steps also run at zero and need valid permissions.
Unused issuers must therefore have zero allowance and readable accounting.
A failed query or reverted action aborts the whole transaction; there is no
catch-and-continue fallback.

## Verification

```sh
forge test --match-contract 'Recipe(Recovery|Build|RepayBuild)Test' -vv
```

Tests use the real adapter, factory and recipe executor with current proofs and
roles. External lending pools, vaults and issuer settlement state are explicit
local fixtures; these configurations have not been deployed or mainnet-executed.

## Repay earlier payouts

The `health-repay` template spends cash already held by the MerkleAccount above
`limits.minCashBalance`, up to the smaller of the current target-health need and
`maxRepayment`. It performs no claim or redemption request, clears the repayment
approval, and checks actual cash debit, debt reduction and health. No available
cash or no repayment need reverts. Configure an explicit reserve because token
balances do not identify the source of earlier cash.

Use this phase after pushed payouts or actual token delivery from an offchain
settlement, before queuing more recovery requests. Follow the issuer-specific
[payout guidance](RECIPE-REDEMPTIONS.md#delayed-payouts-and-repeatable-requests).
Build `script/recipes/examples/health-repay.json` with `BuildRecipe` and use a
curator-owned executor granted the approval and repayment leaves.
