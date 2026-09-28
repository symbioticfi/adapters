# Configurable strategy execution

`RecipeExecutor` inherits the stateless `Recipes` interpreter and adds access
control, recipe configuration and account management. Shared Solidity types and
interpreter errors live in `IRecipes`. `RecipeCapability` uses the same interpreter
for account self-calls authorized by a Merkle leaf.

`RecipeExecutor` runs one curator-defined sequence of reads, calculations,
conditions and approved leaf calls. The curator commits its hash and publishes
the full recipe in an event. The provider supplies that exact recipe, execution
inputs, current proofs and signatures. A failed call or condition reverts the
entire transaction.

The Merkle account enforces call permissions; its paired adapter holds vault reserves. Approved calls and protocol positions belong to `adapter.account()`. The recipe
selects which leaves run, in what order, with which amounts and relationships
between their results. Protocol conditions already committed inside a guarded
leaf, such as a borrowing health floor, remain enforced by that leaf.

## Ownership and authorization

1. Deploy through `ImmutableFactory(type(RecipeExecutor).creationCode)` using
   `create(abi.encode(curator, account))`.
2. The curator calls `setRecipe(queries, steps)` and `setCaller(provider)`.
3. Grant the executor the required account leaf roles. The provider needs only
   permission to call the executor, not those account roles.
4. The provider calls `execute(queries, steps, inputs, runtime)`.

Use the existing `multicall` to change the program and operator atomically:

```solidity
bytes[] memory calls = new bytes[](2);
calls[0] = abi.encodeCall(RecipeExecutor.setRecipe, (queries, steps));
calls[1] = abi.encodeCall(RecipeExecutor.setCaller, (provider));
executor.multicall(calls);
```

The owner sends this transaction. Both changes succeed together or both revert.

The caller cannot replace the selected leaves, their order, bindings, queries or
conditions: `keccak256(abi.encode(queries, steps))` must equal the current `recipeHash`
before any external query or action. A supplied action must match the specific
leaf configured for its instruction, not merely another permitted leaf.
`account.manage()` checks the final calldata against the current root and roles.

A masked word is intentionally variable under its Merkle leaf. A binding replaces
that word with a recipe literal, input or earlier result; an unbound masked word
keeps the value supplied in the runtime action. For example, if a transfer leaf
masks its amount and the recipe provides no amount binding, the caller chooses
the amount. Binding it to a queried balance or a checked input enforces that
relationship. Bindings need cover only fields the recipe intends to constrain;
there is no requirement to overwrite every variable field.

`setRecipe` replaces `recipeHash`, records `recipeBlock`, and emits
`SetRecipe(recipeHash, queries, steps)`. The hash occupies one persistent slot;
the `uint48 recipeBlock` shares another with the caller address. Owner uses one
further slot, for **three persistent slots** in total, independent of program size.
The account is immutable and the reentrancy guard is transient. No instructions
or queries are stored in persistent contract storage.

To recover the recipe, read its hash and event block at a pinned chain snapshot,
query this executor's matching event in that single block, and verify the decoded
recipe's hash. A cache is usable only if it matches the current commitment.
Configuration changes invalidate pending executions using different recipes.
An unconfigured executor rejects execution; an explicitly committed empty recipe
is a no-op. `setRecipe` and `setCaller` cannot run during execution. Setting caller to zero disables
execution.

## Instruction schema

```solidity
uint8 constant SRC_LITERAL = 0;
uint8 constant SRC_INPUT = 1;
uint8 constant SRC_RESULT = 2;

uint8 constant OP_READ = 0;
uint8 constant OP_ADD = 1;
uint8 constant OP_SUB = 2;
uint8 constant OP_SATURATING_SUB = 3;
uint8 constant OP_MIN = 4;
uint8 constant OP_MAX = 5;
uint8 constant OP_MUL_DIV = 6;
uint8 constant OP_EQUAL = 7;
uint8 constant OP_LESS_OR_EQUAL = 8;
uint8 constant OP_MANAGE = 9;
uint8 constant OP_APPROVE = 10;
uint8 constant OP_CALL = 11;
```

Configuration and execution take `bytes[] queries` and `bytes[] steps` separately.
Each instruction starts with one operation byte, followed by its ABI-encoded payload.
Each operand uses the low 28 bytes of one word: its source byte selects a `SRC_*`
constant, and its low 27 bytes contain a literal or index. A binding adds its
4-byte calldata offset in the high 4 bytes of that same word.

```solidity
uint256 srcAndValue = uint256(source) << 216 | uint256(value); // source is uint8; value is uint216
uint256 binding = uint256(offset) << 224 | srcAndValue; // offset is uint32
steps[i] = abi.encodePacked(operation, abi.encode(/* payload fields */)); // operation is uint8
```

Builders reject literals and indices above `type(uint216).max`, binding offsets above
`type(uint32).max`, and packed operands above `type(uint224).max`. Inputs and numerical
results remain full `uint256` values, including values written by bindings.
The opcode and source byte must match supported constants. These constants are
defined at file level in `IRecipes.sol` and imported by name.
Each query encodes its fields directly:

```solidity
queries[i] = abi.encode(target, data, bindings, returnOffset);
// address target, bytes data, uint256[] bindings, uint256 returnOffset
```

`returnOffset` selects a complete 32-byte word from the returned bytes; it does
not need to be aligned. There is no outer `Query` or `Recipe` struct wrapper in
the public ABI. Script builders use local structs only for assembling recipes.

Each payload uses `abi.encode(...)` with these arguments, in order. Numerical
operands (`a`, `b`, `denominator`, `gate` and `amount`) use the packed source/value word:

| Operation       | Payload                                                        | Effect                                                  |
| --------------- | -------------------------------------------------------------- | ------------------------------------------------------- |
| `Read`          | `uint256 queryIndex`                                           | STATICCALL a shared query and read one complete word    |
| `Add`, `Sub`    | `uint256 a, uint256 b`                                         | Checked uint256 arithmetic                              |
| `SaturatingSub` | `uint256 a, uint256 b`                                         | Subtraction floored at zero                             |
| `Min`           | `uint256 a, uint256 b`                                         | Smaller operand                                         |
| `Max`           | `uint256 a, uint256 b`                                         | Larger operand                                          |
| `MulDiv`        | `uint256 a, uint256 b, uint256 denominator`                    | Checked `a * b / denominator`, rounded down             |
| `Equal`         | `uint256 a, uint256 b`                                         | Require `a == b`                                        |
| `LessOrEqual`   | `uint256 a, uint256 b`                                         | Require `a <= b`; swap operands for a lower bound       |
| `Manage`        | `uint256 gate, bytes32[] leaves, uint256[][] bindings`         | One ordered, atomic account call group                  |
| `Approve`       | `uint256 amount, address token, address spender, bytes32 leaf` | Set account-owned allowance through approved leaves     |
| `Call`          | `address target, bytes template, uint256[] bindings`           | Executor-originated call using fixed committed calldata |

Only `Manage` and `Approve` consume runtime entries, sequentially:

- `Manage`: `abi.encode(IMerkleAccount.Action[])`.
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

`Call` performs an executor-originated call, for a policy that is not reached
through a leaf. Its full calldata template and target belong to the committed
recipe; only explicitly bound words can change. It grants no new authority, but
the target can exercise permissions already granted to the executor. For example,
a committed direct call to `account.manage` still passes that account's Merkle
and role checks, including any approved native-value action. The interpreter's
own calls send no native value and never delegatecall; its `Manage` and `Approve`
instructions reject native-value actions. 3F can use `Call` with the executor as policy consumer, or
charge `ThreeFPolicy.consume` inside a guarded mint leaf with the account as consumer.
A policy has one consumer at a time; changing it preserves usage and blocks the old caller.

## Values, queries and conditions

`Literal` contains a uint216. `Input` indexes this execution's uint256 inputs.
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
limited to 32 bits and relative to the individual call, not the outer `Action[]`
wrapper. Nested ABI words need not align with outer words. Leaves must pin the relevant nested
headers, lengths and all nonvariable fields. Read return offsets remain uint256 byte
offsets, including unaligned offsets; a complete 32-byte word must be returned.

Managed actions are checked against their configured leaves **after** binding,
then passed to `account.manage()`. Outer ABI padding or relocated tails do not
change the decoded actions or bypass their final leaf checks. A binding cannot
alter a pinned token, recipient or market. Signatures must remain valid for the
resulting signed content. Read queries and local policy calls originate from the
executor; protocol leaves and approvals originate from the account.

## Configuration and identity

Select approved leaves and derive addresses from their verified configuration.
The recipe does not repeatedly compare duplicated adapter/vault/token settings.
The connector already restricts calls to its bound account. The adapter checks reserve coverage whenever an approved `push(amount)` funds that account.

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
Set the optional `leaves.push` permission to let LL/3F funding first push available underlying from the adapter. The builder protects `max(pendingDeallocation(), releasedLiquidity() + stagedLiquidity())` and caps the push to the smaller of cash above that amount and the account funding shortfall. Staged and released cash remain protected after the request is cancelled. Other sources withdraw or borrow directly into the account.

Source, approval and operation layout fields identify runtime slots; a policy
`consumeStep` identifies an instruction because `Call` takes no runtime payload.
Result fields serialized as bytes (`borrowedUsdc`, `minimumRwa`, `rwaReceived`,
`amountIn` and `amountOut`) contain one packed source/value word. `principalResult`
and `sourceAmountResults` contain unpacked result indices. All numeric result
references use absolute instruction indices. Human-readable
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
recipe-configured recipient. Recipe reads and comparisons check the exact cash debit, recipient
payment and RWA receipt.

Signed discounts and the connector's minimum discount use `1e8` precision (`1_000_000` = 1%).

Optional native redemption consumes exactly the newly acquired RWA, preserves
preexisting RWA holdings, and checks the issuer receipt increase and resulting
receipt cap. Clear any issuer allowance afterward. Receipt units and queries
are issuer-specific; they can represent pending entitlement, claim tokens or
immediate proceeds. A request is not a settled redemption.

### 3F

`ThreeFExecuting.Config.guardedMint` selects the policy-consumption path. Create
`ThreeFPolicy` through its `MigratablesFactory` with `abi.encode(consumer)` and configure
its per-collateral-underlying period budget and minimum yield, scaled by `1e8`
(`1_000_000` = 1%). The policy implementation pins the trusted requests factory and
facility in its constructor and keeps one consumer at a time.

`consume(request, assets, yieldAssets)` resolves its own budget key. It requires
factory membership, a valid `request-{id}` name, a matching request from the facility's
intent, and a position-manager target. It resolves that manager's collateral asset
and reads its `underlying()`, with these checks inlined in `consume`. The funding
token remains separate: principal, budget usage and yield
amounts use the request's funding-token units, while the collateral underlying keys
the policy limits. Requests sharing a collateral key must use the same funding token
and denomination; use separate policy instances otherwise.

- **Guarded mint:** use `guardedMint: true` and the account as consumer. The
  `ThreeFGuardedMint` leaf consumes the policy for the request and mints,
  binding the charge to observed cash, principal and yield movements. The recipe binds
  four amount words from the live mint authorization. Direct managers using that leaf
  share the same budget and checks.
- **Direct mint:** use `guardedMint: false` and the executor as consumer. The recipe
  consumes the policy for the request through a committed `Call`, executes
  a native `request.mint` leaf, and checks the exact cash debit and principal/yield
  increases. No guarded capability is required. Grant the native mint and funding
  leaf roles only to the executor; a direct manager using those leaves would bypass
  the recipe's policy and checks.

Both paths read and recheck live authorization, obtain funding, clear approvals, and
roll back policy consumption on any failure. Policy limits remain editable without a
root update. Switching a policy's consumer preserves period usage and disables its
previous path; use separate policy instances if both consumer addresses need concurrent
independent budgets.

For `BuildRecipe`, `.policy.guardedMint` defaults to `true`.
Set it to `false` and supply the deployed executor address as `.executor` for the direct
path. The output includes `mintLeafTarget`, `mintLeafData`, `mintLeafMask`, `mintLeafHash`
and the matching `setConsumerCalldata`. The builder resolves `underlyingAsset` from the
request using the policy's pinned `REQUESTS_FACTORY()` and `FACILITY()`, with the same
validation as `consume`, and uses it for both limit setters; `.addresses.asset` still selects
the funding token. Publish that leaf and use its hash as `.leaves.mint` when generating
the final committed recipe.

Regenerate existing 3F leaves and recipes when adopting this implementation:
`consume(address,uint256,uint256)` keeps its selector but its first argument now
identifies the request. Migrating from funding-token budget keys requires explicit
reconciliation of limits and period usage against the new collateral-underlying keys;
the policy cannot infer that mapping.

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
- A failed read or attempted call reverts everything. Zero `Manage` gates skip
  managed calls; reads are unconditional. A later funding source's capacity or
  pending-request query must still succeed even when earlier sources or existing
  cash cover the amount. Remove unavailable sources from the saved recipe before
  execution. There is no catch-and-continue fallback.
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

The six generated example configurations each write **two slots**: the recipe
hash and the event block packed with caller. The executor has three persistent
slots in total, including owner. A regression test covers 300 instructions with
30 large queries: increasing recipe size does not increase persistent storage.

Packing avoids initializing a separate block slot when a caller is already set.
A historical isolated `RecipeExecutorTest.test_ConfigurationFactoryAndCurrentCommitment`
benchmark, using a single-call recipe and Solidity 0.8.37 with the settings below,
measured these before/after call costs:

| Operation                         | Before packing | After packing |
| --------------------------------- | -------------: | ------------: |
| First recipe after setting caller |         78,183 |        61,127 |
| Replace recipe with an empty one  |         35,200 |        35,244 |

The first configuration saved 17,056 gas; subsequent writes preserved the packed
caller and added 44 gas in that benchmark. Current measurements are recorded in
`snapshots/RecipeExecutor.json`.

| Example                        | Instructions | Runtime entries | `setRecipe` transaction gas |
| ------------------------------ | -----------: | --------------: | --------------------------: |
| One Aave withdrawal + LL swap  |           28 |               4 |                     222,494 |
| Supply + borrow + RWA purchase |           48 |               7 |                     313,889 |
| LL swap + native redemption    |           52 |               8 |                     339,847 |
| 3F mint                        |           27 |               5 |                     222,147 |
| Health recovery                |          101 |               7 |                     585,578 |
| Later claim + repayment        |           64 |               5 |                     383,902 |

These historical figures predate packing caller, recipeBlock, operands and instructions. They were
recorded for commit `ee57a69` with Solidity 0.8.37, optimizer 200, non-IR and Osaka, using the checked-in
JSON examples plus an LL variant with only its Aave source and no redemption.
Gas comes from Anvil transaction receipts for a first `setRecipe` on each fresh
production executor. The 3F row was re-recorded when its charge moved into the guarded
mint leaf, which removed the policy call and the conditions that leaf now enforces. That
rerun reads about one percent below the original harness on untouched examples, so compare
the 3F figure with the other rows only approximately. It includes transaction intrinsic and calldata gas, but
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
