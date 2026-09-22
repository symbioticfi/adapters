# Guarded calls

`GuardedCallsCapability` adds conditions to direct protocol calls made by the account.
It is stateless. Install its `execute` selector once; onboarding another protocol
requires a new accepted Merkle leaf, not another capability.

```solidity
execute(Call[] calls, Check[] checks)
```

Execution requires an account self-call through `manage`, its accepted Merkle proof
and the caller's leaf role. All conditions and literal thresholds belong to the
Merkle leaf. The capability has no storage, setter or configuration transaction.
Adapter owners cannot bypass leaf authorization.

Each `Call` contains `target` and `data`. Each `Check` contains a static `query`, a
return-data byte `offset`, an `observation`, a `comparison` and a `bound`:

| Field        | Values                                                                                       |
| ------------ | -------------------------------------------------------------------------------------------- |
| Observation  | `Before`, `After`, `Increase`, `Decrease`                                                    |
| Comparison   | `Equal`, `GreaterOrEqual`, `LessOrEqual`                                                     |
| Bound source | `Constant`: literal value; `Calldata`: uint256 word at `calls[value].data[offset:offset+32]` |

Delta baselines are captured before any writes. Before conditions run
before the calls. Other conditions run after every call has succeeded. Negative
unsigned deltas revert; they never saturate to zero. Literal zero is a valid bound. All query and call
failures roll back the transaction. The original call return data is returned.

## Borrow with a leaf-pinned health floor

- Call: Aave `borrow(asset, amount, 2, 0, account)`.
- Query: `AaveHealthFactor.getHealthFactor(pool, account)` at return offset `0`.
- Condition: `After >= Constant(1.2e18)`.

The borrowing leaf fixes the asset, pool, account, rate, full health query and minimum.
Its mask permits only the nested amount to vary. Changing the minimum requires a
new accepted leaf and its leaf role. The same pattern protects collateral
withdrawals. Morpho and Euler use their scalar health helpers with the same condition.

## Redeem an exact supplied amount

- Calls: approve the issuer, then its native redemption/request function.
- Query: the RWA's `balanceOf(account)`.
- Condition: `Decrease == Calldata(redemptionCallIndex, amountByteOffset)`.

The leaf fixes the issuer, approval spender, account and every condition. The bound
is taken from the immutable submitted redemption calldata. This verifies an exact
RWA balance decrease, including zero when explicitly approved. Add another condition
on a receipt-token balance increase or settlement-token output where the issuer's
flow needs it. Clearing approval can be a final approved call.

## Meter a call against a stateful policy

- Calls: `ThreeFPolicy.consume(asset, assets, yieldAssets)`, then the protocol call it meters.
- Queries: the balances the protocol call moves.
- Conditions: `Increase == Calldata(consumeCallIndex, assetsOffset)` and the same for the yield.

The leaf pins the policy, the asset key and every condition; only the two amount words vary.
Because each declared amount must equal the balance change the protocol actually produced,
an understated charge reverts the sequence. This is stronger than asserting the declared
amount equals another call's argument: it survives a protocol fee, a partial fill or rounding.

The budget and the minimum ratio live in the policy, so the curator can retune them without a
root update, while the leaf fixes what is measured. Set the account as the policy's sole
consumer: an executor reaches the leaf through `account.manage`, so the charge originates
from the account. A curator's direct `manage` through the same leaf shares that budget.
A bare `consume` leaf charges budget without enforcing an accompanying protocol call.
`ThreeFGuardedMint` builds the guarded 3F sequence. Alternatively, `ThreeFExecuting` can
consume the policy through an executor-originated `Call` and enforce the same cash and
share deltas around a native mint leaf. That mode uses the executor as policy consumer
and requires the native mint leaf role to be restricted to it.

## Boundaries

No native value, delegatecall, arithmetic VM, calldata substitution, branches,
dynamic query arguments or asynchronous continuation are included. Conditions
observe the whole batch; split it into separate guarded leaves for intermediate
checks. Empty checks intentionally allow the entire approved call sequence.

Every call target, selector, fixed argument, layout, check, query, comparison,
bound source, index and offset must be committed by the Merkle leaf. Only intended
amount fields should be masked. An unpinned condition would let a caller weaken its
own guard. `RecipeExecutor` executes configured sequences with runtime amounts for approved leaves;
it cannot change or skip the guards encoded in them.
