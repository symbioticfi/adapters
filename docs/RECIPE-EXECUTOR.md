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
uint8 constant OP_READ_IF = 12;
uint8 constant OP_CLEAR_APPROVAL = 13;
uint8 constant OP_READ_CACHED = 14;
uint8 constant OP_READ_WORD = 15;
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

| Operation       | Payload                                                        | Effect                                                                      |
| --------------- | -------------------------------------------------------------- | --------------------------------------------------------------------------- |
| `Read`          | `uint256 queryIndex`                                           | STATICCALL a shared query and read one complete word                        |
| `Add`, `Sub`    | `uint256 a, uint256 b`                                         | Checked uint256 arithmetic                                                  |
| `SaturatingSub` | `uint256 a, uint256 b`                                         | Subtraction floored at zero                                                 |
| `Min`           | `uint256 a, uint256 b`                                         | Smaller operand                                                             |
| `Max`           | `uint256 a, uint256 b`                                         | Larger operand                                                              |
| `MulDiv`        | `uint256 a, uint256 b, uint256 denominator`                    | Checked `a * b / denominator`, rounded down                                 |
| `Equal`         | `uint256 a, uint256 b`                                         | Require `a == b`                                                            |
| `LessOrEqual`   | `uint256 a, uint256 b`                                         | Require `a <= b`; swap operands for a lower bound                           |
| `Manage`        | `uint256 gate, bytes32[] leaves, uint256[][] bindings`         | One ordered, atomic account call group                                      |
| `Approve`       | `uint256 amount, address token, address spender, bytes32 leaf` | Set account-owned allowance through approved leaves                         |
| `Call`          | `address target, bytes template, uint256[] bindings`           | Executor-originated call using fixed committed calldata                     |
| `ReadIf`        | `uint256 gate, uint256 queryIndex, uint256 fallbackValue`      | Read the query when gate is nonzero; otherwise resolve the fallback operand |
| `ClearApproval` | `address token, address spender, bytes32 leaf`                 | Clear account allowance only when it is nonzero                             |
| `ReadCached`    | `uint256 queryIndex`                                           | Read one word and retain the complete query response for this execution     |
| `ReadWord`      | `uint256 producerIndex, uint256 offset`                        | Extract one word from the latest explicit cached read                       |

Only `Manage`, `Approve` and `ClearApproval` consume runtime entries, sequentially:

- `Manage`: `abi.encode(IMerkleAccount.Action[])`.
- `Approve` and `ClearApproval`: `abi.encode(dataMask, proof)`, with `bytes dataMask` and
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

`ReadIf` returns a full-width numerical result. Only its selected branch is evaluated:
a zero gate resolves the fallback without decoding, binding or calling the query;
a nonzero gate reads the query without resolving the fallback. The gate and fallback
are packed operands; the query index is an ordinary index. It is also supported by
the account's `RecipeCapability`.

`ReadCached` performs the same query and first-word validation as `Read`, then
retains its complete return data. `ReadWord` extracts a full-width word from
that snapshot without another call. Its producer is an ordinary earlier
instruction index, and its offset is an ordinary byte offset, which may be
unaligned. The complete 32-byte word must fit inside the response. Both
instructions return numerical values and are supported by `RecipeCapability`.

Only one explicit cached response is retained: another `ReadCached` replaces
it and makes further extraction from the old producer invalid. Already extracted
numbers remain usable. Ordinary `Read`, `ReadIf` and actions leave this immutable
snapshot intact; they never implicitly reuse it. A new execution starts with
an empty cache. Refresh the cached read explicitly when current state is needed
after an action.

`ClearApproval` is executor-only. It always consumes one runtime slot and reads the
current allowance. A zero allowance skips the account call, including runtime
decoding and leaf/proof/role validation; an empty runtime placeholder is sufficient.
A nonzero allowance executes `approve(spender, 0)` with the same permissions and
optional-bool validation as `Approve`. Use ordinary `Approve(0)` when the cleanup
call or its permission validation must run even for an already-zero allowance.

`Call` performs an executor-originated call, for a policy that is not reached
through a leaf. Its full calldata template and target belong to the committed
recipe; only explicitly bound words can change. It grants no new authority, but
the target can exercise permissions already granted to the executor. For example,
a committed direct call to `account.manage` still passes that account's Merkle
and role checks, including any approved native-value action. The interpreter's
own calls send no native value and never delegatecall; its `Manage`, `Approve` and `ClearApproval`
instructions reject native-value actions. 3F can use `Call` with the executor as policy consumer, or
charge `ThreeFPolicy.consume` inside a guarded mint leaf with the account as consumer.
A policy has one consumer at a time; changing it preserves usage and blocks the old caller.

## Values, queries and conditions

`Literal` contains a uint216. `Input` indexes this execution's uint256 inputs.
`Result` indexes an **earlier instruction**, and only `Read` through `MulDiv`, `ReadIf`,
`ReadCached` and `ReadWord`
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

Allocate one `runtime` entry per `Manage`, `Approve` or `ClearApproval` instruction. The generated
`runtimeSteps` array maps each runtime slot to its absolute instruction index.
Set the optional `leaves.push` permission to let LL/3F funding first push available underlying from the adapter. The builder protects `max(pendingDeallocation(), releasedLiquidity() + stagedLiquidity())` and caps the push to the smaller of cash above that amount and the account funding shortfall. Staged and released cash remain protected after the request is cancelled. Other sources withdraw or borrow directly into the account.

Source, approval and operation layout fields identify runtime slots; a policy
`consumeStep` identifies an instruction because `Call` takes no runtime payload.
Result fields serialized as bytes (`borrowedUsdc`, `minimumRwa`, `rwaReceived`,
`amountIn` and `amountOut`) contain one packed source/value word. `principalResult`
and `sourceAmountResults` contain unpacked result indices. All numeric result
references use absolute instruction indices. Human-readable
stages group instructions for display; they do not change execution semantics.

### Readable build manifest

Every build includes a `manifest` with `schemaVersion: 1`. It decodes the emitted
recipe bytes into named instructions and queries, including targets, calldata,
return offsets, operand sources, bindings and runtime slots. `requiredOpcodes`
lists the distinct operation codes in ascending order. Operand `value` fields
are decimal strings, preserving their complete `uint216` literal or reference
index in JSON consumers; input and result references are not resolved amounts.
The manifest's `recipeHash` is `keccak256(abi.encode(queries, steps))`, matching
the executor's commitment and the enclosing artifact's `recipeHash`.

The manifest's `snapshot` records the rendering context's `chainId`, `blockNumber` and
`parentBlockHash`. The latter identifies the preceding block, because the current
block hash is unavailable during execution. The enclosing output identifies the
adapter and account. `manifestContext` is `build` for template builds and
`inspection` when decoding saved bytes. These fields record the rendering context, not verification of
deployment compatibility, permissions or protocol configuration.

Guarded 3F builds also include `guardedMintManifest`, decoded from the generated
mint leaf. Its opcode requirements apply to the account's recipe capability,
while the main manifest's requirements apply to the executor. The generated
`mintLeafHash`, leaf data/mask and outer mint bindings identify the dependency.
Direct 3F and other templates omit this nested manifest.

Keep the complete generated artifact with each automation. All current templates
use the shared manifest export, and new templates must retain that export.
Custom or future exporters must call `RecipeManifest.render` on their final
encoded recipe, including any nested capability recipe, rather than describing
their input configuration independently. Pure Solidity builders continue to
return recipe bytes; render their result at the offchain export boundary.

Every input example has a checked-in readable counterpart in
[`script/recipes/examples/manifests/`](../script/recipes/examples/manifests/).
These illustrate dummy configuration and mocked protocol resolution on a fixed
local chain. The example catalogue test discovers all input JSON files, compares
their generated manifests and nested recipes against the committed bytes, and
rejects missing or stale samples. See the
[example workflow](../script/recipes/examples/README.md) for regeneration.

### Inspect existing automations

Existing automations should be inspected from their exact saved recipe bytes.
Rebuilding an old input with a newer optimizer can change the committed hash.
Add or refresh manifests in an existing build artifact with:

```sh
forge script script/recipes/BuildRecipe.s.sol:BuildRecipe \
  --sig 'inspect(string,string)' \
  path/to/saved-recipe.json out/inspected-recipe.json
```

The input can contain `recipe` as ABI-encoded `(bytes[], bytes[])`, or `queries`
and `steps` as arrays of hex strings exported from a `SetRecipe` event. Both use
the current opcode-prefixed instruction format. If both representations are
present they must agree. Supplied `recipeHash` and `setRecipeCalldata` must also
match; a mismatch or undecodable recipe fails before writing output. Inspection
preserves existing metadata and calldata, computes the hash and runtime layout,
and renders the same manifest schema used by new builds. Guarded 3F artifacts
also have their leaf selector and hash checked, and that hash must appear in an
outer `Manage` group before rendering the nested recipe. The nested manifest
describes the supplied leaf template; inspect the data mask separately to confirm
which parts runtime inputs can change.
The input and output paths may be identical for an in-place update.

Inspection needs no RPC to decode the bytes. Select an RPC with `--rpc-url` when
the rendering snapshot should describe that chain. Its snapshot records the
inspection context, not the original build or execution block. When importing
deployed automation bytes, verify their computed hash against the executor's
current `recipeHash`; this file inspection command does not query a deployment.

### Automatic build optimization

`ExecutingRecipe.balance`, `binary`, `mulDiv` and `check` optimize instructions as the
recipe is assembled. All JSON templates inherit this behavior automatically:

- Fold constant arithmetic when the result fits an inline `uint216` literal.
- Simplify identities such as adding zero to an earlier numerical result.
- Fold `mulDiv(value, 0, positiveLiteral)` to zero once `value` is valid.
- Reuse identical calculations and checks over immutable inputs and results.
- Remove comparisons already proven true, including `0 <= value` for valid operands.
- Reuse the same token/account balance until the next `Manage`, `Approve`, `Call` or `ClearApproval`.
  Three funding sources therefore emit four balance reads instead of six.

Overflow, underflow, division by zero and failed comparisons remain runtime
failures at their original position relative to actions. `MulDiv` retains its
checked multiplication before division; cancelling equal factors could hide an
overflow. Full-width results stay numerical instructions when they do not fit
an inline literal. An input is proven valid only after an earlier arithmetic
instruction or check uses that input or a higher index; the first use remains
so a missing input still fails. A runtime denominator is not assumed nonzero.
Approvals and calls retain their order and execution count, including zero-gated actions.

`balance` assumes standard ERC20 balances remain stable between actions. Generic
`read` and `readQuery` calls always emit fresh reads. For a nonstandard balance
getter that varies without a state change, use `readQuery(balanceQuery(token, account))`.

Use the returned packed operands and generated layouts: optimization can return
a literal or reuse an earlier result instead of emitting a new instruction.
`instruction` emits exactly the supplied instruction and bypasses optimization,
which also provides a baseline for gas comparisons. Raw `Manage`, `Approve` and
`ClearApproval` instructions advance the same runtime-slot counter as the action
helpers, so the two construction styles can be mixed. The optimization is local;
savings depend on the redundancy in a recipe.

Rebuild and publish the generated `setRecipeCalldata` to adopt an optimized
recipe. The executor ABI and instruction format are unchanged, and existing
committed recipes remain executable.

Isolated local execution measurements with Foundry 1.8.1, Solidity 0.8.37,
IR, optimizer 200 and Osaka:

| Fixture                                   | Baseline gas | Optimized gas | Saving |
| ----------------------------------------- | -----------: | ------------: | -----: |
| Redundant arithmetic, 9 instructions to 4 |       85,843 |        67,940 |  20.9% |

These are total execution-transaction gas measurements; offchain building and
`setRecipe` are excluded. Removing the repeated Liquid Lane funding balance
read, zero multiplication and zero lower-bound check
reduces recipe encoding from 10,400 to 9,920 bytes. Its two-source execution also
checks idle funding, existing RWA/receipt balances, runtime amounts and cleared
approvals. The arithmetic test constructs both versions with identical effects
and reduces recipe encoding from 1,792 to 960 bytes.
The snapshots are in `snapshots/LLExecuting.json`, `snapshots/RecipeOptimization.json` and
`snapshots/RecipeRecovery.json`.

### Optional funding-source optimizations

LL and 3F source entries support an optional `prepare` call before the source's
capacity read. For a verified Morpho Vault V2, this can call `accrueInterest()`
once so subsequent capacity/withdrawal accounting reuses its transaction-local
cache ([VaultV2 implementation](https://github.com/morpho-org/vault-v2/blob/main/src/VaultV2.sol#L602-L624)).
For example, add this field to that source, replacing the illustrative
vault address:

```json
{
  "prepare": {
    "target": "0x0000000000000000000000000000000000000421",
    "data": "0xa6afed95"
  }
}
```

The call runs as the executor with committed calldata and no runtime payload.
It runs even when idle funds already cover the request and resets balance reuse.
For Morpho Vault V2 it can crystallize fees and mint fee shares, so it is an
explicit integration choice, not an automatic rewrite of arbitrary capacity
queries. MetaMorpho V1 does not share this accrual API. Measure the complete
execution from identical state; a deposit earlier in the same transaction can
already populate the cache. The proposed 123k saving has not been reproduced here.

Set `"skipCapacity": true` on the **last external funding source** to remove its
capacity read and `Min` instruction. Its `capacity` object may then be omitted.
The source attempts the entire remaining shortfall; managed permissions, amount
bindings and the exact received-balance check still apply. A zero shortfall
skips withdrawal, while insufficient liquidity reverts the transaction.
Enable this only when the withdrawal itself enforces the intended limits:
any additional policy encoded by the skipped capacity query is removed.
Omitting `capacity` without the flag is an error. Intermediate sources cannot
skip capacity, and the adapter's protected push capacity is always retained.

Pure builders express preparation through `Source.prepare` and capacity omission
through a `Read` with zero target, empty data and zero offset on the last source.
Existing configurations retain their capacity reads. `RecoveryRecipe` retains
all capacity limits because it supports partial repayment progress.

In the local two-source Liquid Lane fixture, skipping the final mock source's
capacity reduces execution from 815,306 to 805,238 gas: **10,068 gas saved**,
with 45 instructions reduced to 43. Both versions execute from identical state.
This does not establish the proposed 22k saving for an Euler source; its deployed
capacity getter must be measured separately. Snapshots are
`LLExecuting.executeZeroMinimumWithLastCapacity` and
`LLExecuting.executeZeroMinimumWithoutLastCapacity`.

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
preexisting RWA holdings, and checks the new issuer receipt increase against
the minimum and per-execution `maxReceiptBalance` cap. Earlier receipts do not use
this cap. Clear any issuer allowance afterward. Receipt units and queries
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
the funding token. The script derives the selected mint leaf hash before encoding
the recipe and uses that same hash in its mint action. `.leaves.mint` is no longer
required; an existing value is ignored. Publish the generated leaf and its roles
alongside the generated recipe. No intermediate build or manual hash copy is needed.
Pure `ThreeFExecuting` callers still supply `Config.mintLeaf` explicitly.

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
  managed calls. Ordinary reads are unconditional; `ReadIf` can skip an unused
  query when explicitly configured. With default options, a later funding source's
  capacity or pending-request query must still succeed even when earlier sources
  or existing cash cover the amount. There is no catch-and-continue fallback.
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
forge test --match-contract RecipeOptimizationTest --fuzz-runs 1000 -vv
```

Local tests execute production adapter, capability, connector and executor code
with explicit lending/issuer fixtures. They do not prove issuer onboarding or
live mainnet liquidity. Dedicated fork suites require their RPC configuration.

### Conditional recipe optimizations

The JSON builder accepts explicit options (all default to `false`):

```json
{
  "optimizations": {
    "skipUnusedReads": true,
    "skipZeroApprovals": true,
    "reuseTupleReads": true
  }
}
```

`skipUnusedReads` applies to LL/3F funding and health recovery/claim recipes. It
skips unused source capacities and their balance-delta reads, redemption reads
when the remaining request budget is zero, and pending/balance reads for zero
claims. Used actions retain their exact balance checks. Recovery still reads
all relevant pending requests before allocating a nonzero request budget,
retains the final zero-allowance checks even for unused issuers, and always takes
fresh health/debt/cash snapshots. Insufficient liquidity still allows partial
repayment. Explicit source `prepare` calls remain unconditional, and funding
refreshes its cash snapshot after preparation.

`skipZeroApprovals` uses `ClearApproval` for cleanup in LL, 3F, lending and
recovery/claim recipes. Initial approvals retain the original behavior. Runtime
slot counts and action-stage boundaries remain stable. Skipped query failures
and skipped cleanup permission checks deliberately no longer block execution;
enable these options only when that behavior matches the committed strategy.
These instructions require the updated executor (and an updated capability if
using `ReadIf`, `ReadCached` or `ReadWord` inside an account recipe). Existing deployments cannot acquire new
opcodes merely by publishing a new recipe.

`reuseTupleReads` applies to 3F execution. Each principal/yield authorization
snapshot uses one getter call, and each PT/YT balance snapshot uses one call.
Authorization is refreshed after funding and approval; balances are refreshed
after minting. All exact principal, yield and cash checks remain in place.
Guarded mode applies the same optimization inside its nested mint capability.
Its encoded leaf, mask and binding offsets change, so regenerate and publish
the guarded leaf/role as well as the executor recipe. The JSON output includes
the updated `mintLeafData`, `mintLeafMask` and `mintLeafHash`, and the generated
recipe already commits that hash. Direct mode retains its existing mint leaf.

Pure builders use `readCached` or `readCachedQuery` to take a snapshot, then
`readWord(cachedReadOperand, byteOffset)` to extract its other words. The builder
rejects a noncached or replaced producer. Generic `read`/`readQuery` remain fresh.

At Ethereum block `25,892,000`, with the current runtime and approval cleanup
disabled in both versions:

| 3F execution | Separate getter gas | Cached tuple gas | Gas saved |
| ------------ | ------------------: | ---------------: | --------: |
| Guarded      |             611,259 |          592,853 |    18,406 |
| Direct       |             495,600 |          484,437 |    11,163 |

Both versions start from identical state and verify actual PT/YT balances,
cash, final allowance and policy consumption. Guarded proofs have equal depth.
The isolated local tuple test saves 3,217 gas (46,235 to 43,018).

Adding these opcodes increases execution cost for recipes that do not use them.
Compared with the previous runtime, the measured LL fixture rises from 812,743
to 815,306 gas (0.32%), and health recovery rises from 1,101,217 to 1,107,202
(0.54%). The tuple savings above compare both recipes on the updated runtime.

Isolated execution measurements with the current executor and the same local
fixtures, enabling `skipUnusedReads` and `skipZeroApprovals`:

| Fixture                         | Unconditional gas | Conditional gas | Gas saved |
| ------------------------------- | ----------------: | --------------: | --------: |
| Liquid Lane, already funded     |           702,534 |         643,079 |    59,455 |
| Liquid Lane, two active sources |           872,211 |         828,880 |    43,331 |
| Health recovery, already funded |           791,964 |         747,690 |    44,274 |

At Ethereum block `25,892,000`, conditional cleanup saves 23,172 gas in guarded
3F execution and 23,329 gas in direct execution. Both tests check the actual
PT/YT balances, cash, allowances and policy consumption. Savings are specific
to each fixture and should not be added across unrelated paths.

The Aave recovery/claim examples read health directly from
Aave V3 `Pool.getUserAccountData(account)` at byte offset `160`, avoiding the wrapper.
Here `account` is the MerkleAccount or actual borrowing subaccount. Aave V4 Spoke
uses offset `64` for health factor; offset `160` is collateral count. The existing
Aave health helper and these examples use the V3 layout only.
The debt query must still use the repayment asset's debt-token balance: Aave's
aggregate debt tuple word is denominated in base currency, not repayment units.
The health wrapper remains available for integrations that need its scalar ABI.
Four direct health reads through the executor save 5,208 gas in the pinned
mainnet test (256,082 to 250,874 gas).

The Aave capacity helper now returns early when the account has no borrow bits
and defers oracle/price queries until collateral sizing needs them. It reuses
reserve configuration while retaining active/paused, eMode, isolation and
rounding checks. At the same pinned block, helper gas falls from 101,102 to
50,627 for supplied WETH without debt, and from 162,751 to 159,383 with USDC debt.
Differential tests compare capacity with the original implementation and then
perform the withdrawal while checking health.

The Morpho helper stops scanning adapters when idle underlying already covers
the owner's valued shares. Share valuation and transfer/withdraw gates still
apply. The pinned Vault V2 idle-liquidity test saves 27,981 helper gas (368,662 to
340,681), matches the original capacity and verifies an actual withdrawal.

`guardedMint: false` remains an explicit 3F configuration choice. It removes the
nested capability execution while retaining policy consumption and exact token
checks. It requires native mint/funding leaf roles restricted to the executor,
and that executor as the policy's sole consumer. Do not change an existing
shared-manager permission setup just to select this mode.
