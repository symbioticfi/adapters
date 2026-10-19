# Account recipe capability

`RecipeCapability` executes a Merkle-committed program as the account. It inherits
its interpreter from the stateless abstract `Recipes` contract. `RecipeExecutor`
uses the same instruction schema and interpreter, adding owner/caller controls,
a stored recipe commitment, and account-management instructions.

```solidity
execute(bytes[] queries, bytes[] steps, uint256[] inputs)
```

Install the capability's `execute` selector on the account. An authorized caller
submits an action targeting the account through `MerkleAccount.manage`. The account
verifies its accepted Merkle proof and the caller's leaf role, calls itself, and
delegates to the capability. The capability requires `msg.sender == address(this)`.
Protocol calls originate from the account; direct external calls to either the
account selector or the implementation revert.

The capability has no storage, setters, owner, immutable account or separate
reentrancy lock. The outer `manage` holds the account's lock. `Manage` and `Approve`
instructions are executor-only and revert with `InvalidOperation` in the capability.
Approvals inside capability recipes are explicit `Call` instructions; these do not
provide the executor's automatic allowance reset or optional-bool return handling.

## Instructions and authorization

`IRecipes.sol` defines the file-level `SRC_*` and `OP_*` constants and the shared interpreter errors.
Each `steps` element contains one operation byte followed by its ABI-encoded payload.
Each numerical operand is a `uint256` whose low 28 bytes contain a source byte
and a 27-byte literal or index. Each binding is also one `uint256`: its high
4 bytes contain the calldata offset, and its low 28 bytes contain `srcAndValue`.
See the [instruction schema](RECIPE-EXECUTOR.md#instruction-schema).
Executor-specific errors live in `IRecipeExecutor`. The capability supports:

- `Read`: a shared static query, optionally with bound numerical arguments, selecting
  one complete return-data word at a byte offset.
- `Add`, checked `Sub`, `SaturatingSub`, `Min`, `Max`, and `MulDiv` with checked multiplication followed by floor division.
- `Equal` and `LessOrEqual`: reverting assertions. Express `a >= b` as `b <= a`.
- `Call`: a fixed target and calldata template with optional numerical bindings.

Operands can be uint216 literals, inputs, or results from earlier numerical
instructions. Inputs and results retain all 256 bits; only literals and indices
are limited to 216 bits. Binding offsets are limited to 32 bits; query return offsets
remain uint256.
Bindings replace full words, preserve selectors and length, and must be ordered,
nonoverlapping and in bounds. Queries are decoded afresh for each read. Calls carry
no native value and cannot delegate. Any failure rolls back the entire sequence.
The return value is one numerical slot per step; calls and assertions return zero.
Raw protocol return data is not returned or interpreted by `Call`.

The outer Merkle leaf must pin the complete program: query targets and calldata,
operations, call targets/selectors, layouts, bindings, references and safety
thresholds. Mask only intended variable words, normally in `inputs`. An unpinned
assertion or binding could let the caller weaken its own constraints. The mask is
part of the leaf commitment. Changes to a pinned condition need a new accepted
leaf and a corresponding role grant. Changing packed operand or binding layouts
changes recipe commitments and leaf hashes. Regenerate recipes, masks, bindings
and proofs together. The public
`execute(bytes[],bytes[],uint256[])` selector stays unchanged for this layout change.
Re-encode operands even in recipes without bindings. Old source bytes in the
highest four bytes are now ignored, so old operands may become literals instead
of reverting.

## Borrow with a fixed health floor

1. `Call` the lending protocol's native borrow function as the account.
2. `Read` its current health factor, through a scalar helper or a selected word
   of a protocol response.
3. Assert `LessOrEqual(Literal(1.2e18), Result(healthRead))`.

Pin the asset, pool, account, interest mode, health query and minimum. Permit only
the intended amount to vary. A failed health check rolls back the borrowing. The
same sequence protects collateral withdrawals. Conditions can also be placed
between calls when each intermediate position must satisfy them.

## Before/after conditions and deltas

Place precondition reads and assertions before the first call. Capture all required
delta baselines before writes, execute the calls, then read the resulting state.
For an increase, calculate `Sub(after, before)`; for a decrease, calculate
`Sub(before, after)`. Checked subtraction rejects movement in the opposite direction.
Compare the result to a literal or to the same input used to bind the protocol call.
Do not use `SaturatingSub` when an opposite-direction change must revert.

`ThreeFGuardedMint` builds a capability recipe that checks factory membership,
captures cash and PT/YT baselines, charges `ThreeFPolicy`, mints, then checks exact
principal, yield and cash deltas. Four masked inputs bind the two policy amounts
and two mint amounts. Every declared policy charge must match the observed movement.
The builder derives the mask and executor binding offsets from the final encoding.
Set the account as the policy's sole consumer for this route.
