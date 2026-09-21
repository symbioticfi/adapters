# Health recovery strategy

Two saved `RecipeExecutor` configurations implement health recovery:

- [`health-recovery.json`](../script/recipes/examples/health-recovery.json):
  low health → Morpho withdrawal → Aave withdrawal → repay → ordered RWA requests.
- [`health-claim.json`](../script/recipes/examples/health-claim.json):
  claim settled requests → repay the remaining need → retain surplus cash.

The recovery example triggers at health factor **≤1.25**, targets **1.50**, and caps newly
funded recovery at **100 USDC per execution**. These are illustrative limits.
Every address and leaf is a dummy value to replace with an actual accepted
strategy. Names describe the source order; executable behavior comes from the
fixed read calldata and approved leaves.

## Generate configuration transactions

```sh
forge script script/recipes/BuildRecipe.s.sol:BuildRecipe \
  --sig 'run(string,string)' \
  script/recipes/examples/health-recovery.json out/health-recovery.json

forge script script/recipes/BuildRecipe.s.sol:BuildRecipe \
  --sig 'run(string,string)' \
  script/recipes/examples/health-claim.json out/health-claim.json
```

The script emits the recipe, constructor arguments, factory-create calldata,
`setRecipe` and `setCaller` calldata. It sends no transaction and needs
no RPC or private key. Each output also lists `sourceCalls`, `requestCalls`,
`claimCalls`, `approveStep`, `repayStep` and `clearApprovalStep` for assembling
execution payloads.

Use two curator-owned instances, each with its own recipe and the provider as
caller. Grant recovery leaves to the recovery instance and claim/repayment
leaves to the claim instance. The provider needs no direct account leaf roles.
A monitoring service must submit transactions; neither configuration schedules
itself or includes a keeper implementation.

## Recovery behavior

The recipe reads the protected position's debt and health on-chain. For a single
debt asset and unchanged collateral, its target repayment is:

```text
need = debt - floor(debt × min(health, targetHealth) / targetHealth)
budget = min(need, maxRepayment)
```

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
Only the uncovered part is requested from RWAs, in order. Each request group
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
the matured principal, executes the claim group, verifies the matching pending
reduction, and checks actual repayment-token proceeds against the configured
minimum. Every positive claim must return at least one base unit of that token.

It repays the minimum of fresh claimed cash, the current target requirement and
the per-execution cap. Old cash is preserved and any excess remains available.
Debt cannot increase and health cannot worsen. Pending principal and claimable
principal must use the same accounting basis; rates may bound a settlement
shortfall, but pending face value is not guaranteed future cash.

For example, using fixture amounts:

| Run               | Action                                                                                    | Debt / pending afterward                        |
| ----------------- | ----------------------------------------------------------------------------------------- | ----------------------------------------------- |
| Start             | Debt 300 USDC, health 1.00, target 1.50                                                   | Needs 100 USDC                                  |
| Recovery          | Withdraw 30 from Morpho, 20 from Aave, repay 50; request 40 from RWA A then 10 from RWA B | Debt 250; pending 50; health 1.20               |
| Repeated recovery | Both sources empty; existing pending covers the gap                                       | No new requests; no-progress execution reverts  |
| Claim A           | Claim and repay 40                                                                        | Debt 210; pending 10; health approximately 1.43 |
| Claim B           | Claim and repay 10, despite health now being above the trigger                            | Debt 200; pending zero; health 1.50             |

## Query and execution requirements

Each read is `{ target, data, offset }`: fixed STATICCALL calldata and the byte
offset of its uint256 result. The sample uses existing Aave health and liquidity
lens signatures for those reads. Its `availableRedemptionAssets(address)`,
`pendingAssets(address)` and `claimableAssets(address)` signatures describe
normalized **example issuer queries**, not an API implemented by every RWA.
Replace them with verified issuer-specific calls or a suitable read lens.

Pending reads must cover distinct requests for the same repayment token, include
matured unclaimed requests, and avoid double-counting. Use conservative proceeds
estimates where supported. Capacity must exclude already committed holdings.
Changing prices or settlement haircuts can leave an additional recovery need.
For an 18-decimal RWA worth one 6-decimal USDC, `maxTokenPerAssetWad = 1e30`.

The JSON source entries contain `amountOffsets`, with one offset list per leaf.
The builder inserts each calculated withdrawal amount into those words. Set
`amountOffsets.repay` to the repayment amount word(s); the Aave example uses `[36]`.
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
forge test --match-contract 'Recipe(Recovery|Build)Test' -vv
```

Tests use the real adapter, factory and recipe executor with current proofs and
roles. External lending pools, vaults and issuer settlement state are explicit
local fixtures; these configurations have not been deployed or mainnet-executed.
