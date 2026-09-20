# Configurable strategy execution

`RecipeExecutor` runs one curator-defined sequence of reads, calculations,
conditions and approved leaf calls. The curator commits its hash and publishes
the full recipe in an event. The provider supplies that exact recipe, execution
inputs, current proofs and signatures. A failed call or condition reverts the
entire transaction.

The Merkle adapter enforces call permissions and holds reserves separately from its strategy account. Approved calls and protocol positions belong to `adapter.account()`. The recipe
selects which leaves run, in what order, with which amounts and relationships
between their results. Protocol conditions already committed inside a guarded
leaf, such as a borrowing health floor, remain enforced by that leaf.

## Ownership and authorization

1. Deploy through `ImmutableFactory(type(RecipeExecutor).creationCode)` using
   `create(abi.encode(curator, adapter))`.
2. The curator calls `setRecipe(queries, steps)` and `setCaller(provider)`.
3. Grant the executor the required adapter leaf roles. The provider needs only
   permission to call the executor, not those adapter roles.
4. The provider calls `execute(queries, steps, inputs, runtime)`.

The caller cannot replace the selected leaves, their order, bindings, queries or
conditions: `keccak256(abi.encode(queries, steps))` must equal the current `recipeHash`
before any external query or action. A supplied action must match the specific
leaf configured for its instruction, not merely another permitted leaf.
`adapter.manage()` checks the final calldata against the current root and roles.

`setRecipe` replaces `recipeHash`, records `recipeBlock`, and emits
`SetRecipe(recipeHash, queries, steps)`. Configuration uses **two persistent slots**,
independent of program size. Owner and caller use two further slots; the adapter
is immutable and the reentrancy guard is transient. No instructions or queries
are stored in persistent contract storage.

To recover the recipe, read its hash and event block at a pinned chain snapshot,
query this executor's matching event in that single block, and verify the decoded
recipe's hash. A cache is usable only if it matches the current commitment.
Configuration changes invalidate pending executions using different recipes.
An unconfigured executor rejects execution; an explicitly committed empty recipe
is a no-op. `setRecipe` and `setCaller` cannot run during execution. Setting caller to zero disables
execution.

## Instruction schema

```solidity
enum Operation {
    Read, Add, Sub, SaturatingSub, Min, Max, MulDiv,
    Equal, LessOrEqual, Manage, Approve, Call
}
enum Source { Literal, Input, Result }
struct Value { Source source; uint256 value; }
struct Binding { uint256 offset; Value value; }
struct Step { Operation operation; bytes data; }
```

Configuration and execution take `bytes[] queries` and `Step[] steps` separately.
Each query encodes its fields directly:

```solidity
queries[i] = abi.encode(target, data, bindings, returnOffset);
// address target, bytes data, Binding[] bindings, uint256 returnOffset
```

`returnOffset` selects a complete 32-byte word from the returned bytes; it does
not need to be aligned. There is no outer `Query` or `Recipe` struct wrapper in
the public ABI. Script builders use local structs only for assembling recipes.

Each payload uses `abi.encode(...)` with these arguments, in order:

| Operation       | Payload                                                      | Effect                                                  |
| --------------- | ------------------------------------------------------------ | ------------------------------------------------------- |
| `Read`          | `uint256 queryIndex`                                         | STATICCALL a shared query and read one complete word    |
| `Add`, `Sub`    | `Value a, Value b`                                           | Checked uint256 arithmetic                              |
| `SaturatingSub` | `Value a, Value b`                                           | Subtraction floored at zero                             |
| `Min`           | `Value a, Value b`                                           | Smaller operand                                         |
| `Max`           | `Value a, Value b`                                           | Larger operand                                          |
| `MulDiv`        | `Value a, Value b, Value denominator`                        | OpenZeppelin `a.mulDiv(b, denominator)`, rounded down   |
| `Equal`         | `Value a, Value b`                                           | Require `a == b`                                        |
| `LessOrEqual`   | `Value a, Value b`                                           | Require `a <= b`; swap operands for a lower bound       |
| `Manage`        | `Value gate, bytes32[] leaves, Binding[][] bindings`         | One ordered, atomic adapter call group                  |
| `Approve`       | `Value amount, address token, address spender, bytes32 leaf` | Set account-owned allowance through approved leaves     |
| `Call`          | `address target, bytes template, Binding[] bindings`         | Executor-originated call using fixed committed calldata |

Only `Manage` and `Approve` consume runtime entries, sequentially:

- `Manage`: `abi.encode(IMerkleAdapter.Action[])`.
- `Approve`: `abi.encode(dataMask, proof)`, with `bytes dataMask` and
  `bytes32[] proof`.

A zero `Manage.gate` consumes its runtime slot but skips decoding and execution;
an empty `0x` placeholder is sufficient. Surrounding reads and conditions still
run. Missing or excess runtime entries revert. No runtime entry is supplied for
reads, arithmetic, assertions or `Call`.

`Approve` constructs token approval through the account, resets a nonzero
allowance before a new nonzero allowance when needed, and checks token return
values. Both reset and approval must match the configured leaf. A later zero
approval clears the remaining allowance. Empty return data is accepted; a false
or malformed boolean return reverts.

`Call` is used for `ThreeFPolicy.consume`, whose authorization requires the
executor as caller. Its full calldata template and target belong to the committed
recipe; only explicitly bound words can change. It grants no adapter authority
and must not replace ordinary protocol leaves. Calls send no native value and
never delegatecall.

## Values, queries and conditions

`Literal` contains a full uint256. `Input` indexes this execution's inputs.
`Result` indexes an **earlier instruction**, and only `Read` through `MulDiv`
produce referenceable values. Assertions and effects return unused zero entries
but cannot be referenced. The returned array has one slot per instruction.
A result can populate any number of subsequent arguments; there is no
three-variable stack or fixed small register limit.

A delta is an explicit `Read` before the action, `Read` after, then `Sub`.
Both reads reference the same shared query template. Each read copies it afresh
before applying bindings. Queries are deduplicated by their entire configuration,
including bindings and return offset. To keep a Pareto epoch or receipt ID fixed,
read it once before the action and bind both balance reads to that result. Query
bindings cannot reference a future instruction or reread a moving identifier
implicitly.

For example, with a shared account-USDC balance query, a withdrawal can be:

1. Read the USDC balance.
2. Manage the approved withdrawal, binding its amount to input zero.
3. Read the same USDC balance query.
4. Subtract the first balance from the second balance.
5. Require that difference to equal input zero.

Bindings replace complete 32-byte calldata words after the selector. They are
sorted, nonoverlapping and in bounds, and preserve calldata length. Offsets are
relative to the individual call, not the outer `Action[]` wrapper. Nested ABI
words need not align with outer words. Leaves must pin the relevant nested
headers, lengths and all nonvariable fields. Read return offsets are byte
offsets, including unaligned offsets; a complete 32-byte word must be returned.

Managed actions are checked against their configured leaves **after** binding,
then passed to `adapter.manage()`. Outer ABI padding or relocated tails do not
change the decoded actions or bypass their final leaf checks. A binding cannot
alter a pinned token, recipient or market. Signatures must remain valid for the
resulting signed content. Read queries and local policy calls originate from the
executor; protocol leaves and approvals originate from the account.

## Configuration and identity

Select approved leaves and derive addresses from their verified configuration.
The recipe does not repeatedly compare duplicated adapter/vault/token settings.
The connector already restricts calls to its bound account. The adapter checks reserve coverage whenever an approved `release(amount)` funds that account.

A Merkle leaf commits call data, not a target's internal storage. In particular,
Liquid Lane's payment asset is stored in the connector rather than supplied to
its signed swap. Verify connector deployment, account binding and payment asset
when configuring the automation. The frontend revalidates these relationships
before saving. Script inputs must be verified separately.

Mutable protocol state still needs checks when it affects the strategy: live
liquidity, debt, health, authorization, receipts and economic outputs. If a
condition is already enforced by a guarded leaf, do not add a duplicate recipe
condition. Changes to that leaf's health floor require an accepted root update.

## Build recipes

The JSON templates in `script/recipes/examples/` use illustrative addresses and
leaf hashes. Replace them with verified configuration and run, for example:

```sh
forge script script/recipes/BuildRecipe.s.sol:BuildRecipe \
  --rpc-url "$ETH_RPC_URL" --sig 'run(string,string)' \
  script/recipes/examples/ll-executing.json out/ll-executing-recipe.json
```

Other templates are `lending`, `3f-executing`, `health-recovery` and `health-claim`.
The script resolves the custody address using `adapter.account()` at the selected RPC. It does not sign, deploy or broadcast. Pure builders accept that account address; query calldata and leaf recipients must refer to it. Its output contains
the encoded recipe, curator transaction calldata, constructor arguments and
named `stages` with inclusive start and exclusive end instruction indices. An optional
factory address adds `factory.create` calldata.

Allocate one `runtime` entry per `Manage` or `Approve` instruction. The generated
`runtimeSteps` array maps each runtime slot to its absolute instruction index.
Set the optional `leaves.release` permission to let LL/3F funding first release available underlying from the adapter. The builder reads its balance and `reservedAssets()` and caps release to the smaller of unreserved cash and the account funding shortfall. Other sources withdraw or borrow directly into the account.

Source, approval and operation layout fields identify runtime slots; a policy
`consumeStep` identifies an instruction because `Call` takes no runtime payload.
All numeric result references use absolute instruction indices. Human-readable
stages group instructions for display; they do not change execution semantics.

### Supply, borrow and purchase

`LendingRecipe` supplies LBTC, borrows USDC through the approved guarded leaf,
and purchases an RWA with the newly borrowed funds. It preserves preexisting
USDC, checks collateral/debt changes and resulting debt limits, requires minimum
RWA delivery, and clears approvals. The leaf controls the borrowing health floor.

The example assumes 6-decimal USDC, 18-decimal RWA, Aave-style receipt/debt tokens
with at most one base unit of rounding and immediate purchase settlement. Async
subscriptions need an issuer receipt condition and a later claim recipe.

### Liquid Lane

`LLExecuting` draws only the funding shortfall from ordered approved sources,
approves the connector, performs the signed swap and clears its allowance.
Available cash is the account balance; adapter reserves are held at a separate address. Sources report capacity in funding
asset units and must deliver their calculated amounts.

Each source's `amountOffsets` has one list per leaf; use an empty list for a leaf
without a bound amount. Aave withdrawal uses `[[36]]`; ERC-4626 withdrawal uses
`[[4]]`. Never substitute a funding amount into an argument denominated in
another token or representing a request ID.

Inputs are `[rwaAmount, quotedPayout]`, bounded by configured per-run limits. The
swap's outer amount argument is bound automatically. The connector validates
discount signatures, deadlines, nonce invalidation, its minimum discount, oracle
pricing and period budget. It transfers RWA to the account and payment to the
leaf-pinned recipient. Recipe reads and comparisons check the exact cash debit, recipient
payment and RWA receipt.

Optional native redemption consumes exactly the newly acquired RWA, preserves
preexisting RWA holdings, and checks the issuer receipt increase and resulting
receipt cap. Clear any issuer allowance afterward. Receipt units and queries
are issuer-specific; they can represent pending entitlement, claim tokens or
immediate proceeds. A request is not a settled redemption.

### 3F

`ThreeFExecuting` checks factory membership and live mint authorization, calls
`ThreeFPolicy.consume` from the executor, obtains funding and mints through the
approved adapter leaf. Principal and yield are bound to the policy call from
live reads. Exact cash and PT/YT changes are checked; approvals are cleared.

The policy owner can update cumulative principal per duration and minimum
per-request yield without a root update. Failed funding/minting rolls back the
policy charge. Separate executors have independent budgets. Direct adapter
execution does not consume this executor's policy budget.

### Recovery and later claims

`RecoveryRecipe` supports a live health trigger, ordered withdrawals, repayment
and RWA redemption requests for the remaining gap. A separate claim recipe can
settle and repay after health has recovered. Pending principal reduces the
redemption gap but never counts as cash or repaid debt.

The calculation assumes one debt asset and unchanged backing collateral. Use
sources outside the protected loan's collateral. Queries must report comparable
repayment-asset units. See [health recovery](HEALTH-RECOVERY-RECIPE.md).

## Practical limits

- An external caller must submit transactions; saving a recipe does not schedule it.
- A failed read or attempted call reverts everything. Zero guards skip calls, but
  there is no catch-and-continue fallback.
- Async settlement requires later transactions; results are not persisted across runs.
- Per-run limits do not enforce turnover budgets, cooldowns or one-time execution.
  Those require appropriate stateful policy, such as `ThreeFPolicy`.
- There are no runtime-sized action loops, jumps or flash-loan callback handlers.
- A managed group cannot read intermediate state between its calls. Use separate
  groups within the account, or a protocol helper.
- Write return data is not exposed as arbitrary numeric results. Use supported
  queries, or a suitable helper for otherwise unavailable request IDs.
- Native-value managed actions are rejected. Direct local calls also send zero value.
- Proofs and roles remain necessary under the current root. A recipe cannot add authority.

## Configuration costs

The six generated example configurations each write **two recipe slots**. The
executor has four persistent slots in total, including owner and caller. A
regression test also covers 300 instructions with 30 large queries: increasing
recipe size does not increase persistent storage.

| Example                        | Instructions | Runtime entries | `setRecipe` transaction gas |
| ------------------------------ | -----------: | --------------: | --------------------------: |
| One Aave withdrawal + LL swap  |           28 |               4 |                     222,494 |
| Supply + borrow + RWA purchase |           48 |               7 |                     313,889 |
| LL swap + native redemption    |           52 |               8 |                     339,847 |
| 3F mint                        |           46 |               5 |                     321,746 |
| Health recovery                |          101 |               7 |                     585,578 |
| Later claim + repayment        |           64 |               5 |                     383,902 |

Recorded for commit `ee57a69` with Solidity 0.8.37, optimizer 200, non-IR and Osaka, using the checked-in
JSON examples plus an LL variant with only its Aave source and no redemption.
Gas comes from Anvil transaction receipts for a first `setRecipe` on each fresh
production executor. It includes transaction intrinsic and calldata gas, but
excludes deployment and protocol execution. These are configuration benchmarks
for the illustrative examples, not mainnet estimates. The full recipe is supplied
on every execution, so the storage saving trades for recurring calldata;
execution still has to perform the same protocol reads and writes.

## Verification

```sh
forge test --no-match-contract '.*(Mainnet|Benchmark).*'
```

Local tests execute production adapter, capability, connector and executor code
with explicit lending/issuer fixtures. They do not prove issuer onboarding or
live mainnet liquidity. Dedicated fork suites require their RPC configuration.
