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

The [claim builder](RECIPE-CLAIMS.md) permits an all-empty
program to succeed. A generic keeper classifies work only after simulating the
complete authenticated `execute` call: a nonempty managed group with a positive
gate is work, and every unconditional `Call` or `Approve` is work, including
`Approve(0)`. Read/check-only programs and zero-gated managed groups can wait.
Argument values and request identities do not determine readiness. Simulation
failures remain errors. A successful canonical receipt proves that the committed
checks passed in that execution; later issuer settlement and claims are separate.

For native CoW and Liquid Lane signing, use the [bounded signing template](RECIPE-SIGNING.md)
with a committed oracle query, slippage constant, amount bounds and maximum lifetime.

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

Queries and calls use literal addresses. Unknown opcodes are rejected.

`Approve` constructs token approval through the account, resets a nonzero
allowance before a new nonzero allowance when needed, and checks token return
values. Both reset and approval must match the configured leaf. A later zero
approval clears the remaining allowance. Empty return data is accepted; a false
or malformed boolean return reverts.

The `readIf` builder helper selects values using ordinary reads and arithmetic.
A runtime zero gate does **not** skip the query or its failure. Tuple words use
explicit offsets and fresh reads, including across intervening calls.

`Call` performs an executor-originated call, for a policy that is not reached
through a leaf. Its full calldata template and target belong to the committed
recipe; only explicitly bound words can change. It grants no new authority, but
the target can exercise permissions already granted to the executor. For example,
a committed direct call to `account.manage` still passes that account's Merkle
and role checks, including any approved native-value action. The interpreter's
own calls send no native value and never delegatecall; its `Manage` and `Approve`
instructions reject native-value actions. 3F charges `ThreeFPolicy.consume` inside
an account-side `ThreeFGuardedMint` leaf. Only the permanently bound account can
consume the policy; the executor reaches that leaf through `account.manage`.

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
The connector already restricts calls to its bound account. New allocations arrive in that account immediately.

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

Other templates are `lending`, `3f-executing`, `health-recovery`, `health-claim`,
`health-repay`, `claim`, [`signing`](RECIPE-SIGNING.md) and `withdrawals`. `withdrawals`
covers the vault queue's live demand from account cash and synchronous withdrawals,
then returns the covered amount to the adapter with `pull`. Because the delegator's sweep
first takes every adapter's free assets, demand also excludes the following adapters' free
assets, and the recipe requires the delegator route to match `precedingAdapters`, the adapter
and `followingAdapters` exactly. [Claims after settlement](RECIPE-CLAIMS.md) covers
separate transactions, partial claims, async mints, rewards and pushed payouts.
The script resolves the custody address using `adapter.account()` at the selected RPC. It does not sign, deploy or broadcast. Pure builders accept that account address; query calldata and leaf recipients must refer to it. Its output contains
the encoded recipe, curator transaction calldata, constructor arguments and
named `stages` with inclusive start and exclusive end instruction indices. An optional
factory address adds `factory.create` calldata.

Allocate one `runtime` entry per `Manage` or `Approve` instruction. The generated
`runtimeSteps` array maps each runtime slot to its absolute instruction index.
Funding uses account cash first, then the configured protocol withdrawals or borrows. Adapter-held staging and released cash cannot fund recipes; the adapter has no `push` entry point.

Source, approval and operation layout fields identify runtime slots; a policy
`consumeStep` identifies an instruction because `Call` takes no runtime payload.
Result fields serialized as bytes (`borrowedUsdc`, `minimumRwa`, `rwaReceived`,
`amountIn` and `amountOut`) contain one packed source/value word.
`sourceAmountResults` contains unpacked result indices. The 3F `requestSource`,
`principalSource` and `yieldSource` fields contain packed operands for either live
results or external inputs. The manual path also publishes `requestInput`,
`principalInput` and `yieldInput`. Numeric result references use absolute instruction indices. Human-readable
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
- Reuse the same token/account balance until the next `Manage`, `Approve` or `Call`.
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
which also provides a baseline for gas comparisons. Raw `Manage` and `Approve` instructions advance the same runtime-slot counter as the action
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

LL source entries support an optional `prepare` call before the source's
capacity read. Grouped 3F recipes reject preparation calls because inactive markets
must not change state. For a verified Morpho Vault V2, this can call `accrueInterest()`
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
When configured, it runs unconditionally in either read mode, including when idle
cash or earlier sources already cover the funding need, and resets balance reuse.
The source's managed withdrawal still skips when its selected amount is zero.
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
skip capacity.

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
RWA delivery, and clears approvals. Supply is
`min(balanceOf(LBTC, account), maxSupplyLbtc)`. Input 0 is raw debt-asset
borrowing capacity, calculated by the executor using a deployless simulation
of the authenticated prefix **after supply**. The executor derives the pool,
asset, account and health floor from the pinned guarded borrow permission;
it does not accept a manual fixed borrowing amount. There is no deployed
borrow-capacity helper or capacity query in the transaction.

Borrowing is `min(input(0), saturatingSub(saturatingSub(maxTotalDebtUsdc, currentDebt), 1))`.
The reserved raw debt unit accommodates the indexed-token rounding admitted by
the effect checks. The transaction still enforces the same configured health
floor, final debt limit, exact collateral spending and borrowed cash, receipt/debt
rounding, RWA delivery and cash conservation. An excessive or stale capacity
cannot bypass those checks; a changed state may make the transaction revert.

The executor's Aave V3.3+ calculation considers liquidation-adjusted global debt
headroom, native LTV availability, actual/virtual cash and reserve borrow caps.
It floors conversion to raw debt-asset units and reserves one raw debt unit for
health/LTV and borrow-cap rounding before applying the exact cash cap. eMode
uses native category borrowability and effective account thresholds. Unsupported
isolation and siloed borrowing produce zero capacity; required read failures
stop preparation. The full original recipe is simulated before submission.

The example assumes 6-decimal USDC, 18-decimal RWA, Aave-style receipt/debt tokens
with at most one base unit of rounding. By default it checks immediate RWA
delivery. Optional `purchaseReceipt: {target, data, offset}` instead snapshots
new subscription entitlement, expressed in raw RWA units; the same output rate
minimum applies. The request spends the borrowed asset once and clears approval.
Use the standalone `claim` template after issuer settlement; claiming must not
transfer the subscription assets again. Existing receipts never satisfy the new
request delta check.

The explicit positive-output check is retained for raw output rates below 1e6.
At rates at least 1e6, positive measured borrowing and the checked minimum-output
calculation already require positive output. The committed examples and manifests
record the resulting instruction count and query bindings.

### Liquid Lane

`LLExecuting` draws only the funding shortfall from ordered approved sources,
approves the connector, performs the signed swap and clears its allowance.
Available cash is the account balance; adapter reserves are held at a separate address. Sources report capacity in funding
asset units and must deliver their calculated amounts.

Each source's `amountOffsets` has one list per leaf; use an empty list for a leaf
without a bound amount. Aave withdrawal uses `[[36]]`; ERC-4626 withdrawal uses
`[[4]]`. Never substitute a funding amount into an argument denominated in
another token or representing a request ID.

Inputs are `[rwaAmount, quotedPayout]`. The swap's outer amount argument is
bound automatically. The connector validates
discount signatures, deadlines, nonce invalidation, its minimum discount, oracle
pricing and period budget. It transfers RWA to the account and payment to the
recipe-configured recipient. Recipe reads and comparisons check the exact cash debit, recipient
payment and RWA receipt.

Signed discounts and the connector's minimum discount use `1e8` precision (`1_000_000` = 1%).

Use one `LLExecuting` recipe and executor per RWA asset. With no redemption
leaves, the acquired RWA remains in the account. If issuer redemption is required,
include that asset's issuer calls in the same recipe. The host selects the
explicit connector/asset mapping; there is no shared acquisition executor or
custody fallback.

Optional native redemption consumes exactly the newly acquired RWA, preserves
preexisting RWA holdings, and checks only the fresh issuer receipt increase.
For cooldowns that retain tokens, set `redemption.retainsRwa=true`: the request
must preserve the complete RWA balance and create new locked entitlement
satisfying the configured receipt rate. Pin the cooldown selector and query its
locked amount, not its timestamp or the unchanged token balance. Optional
`redemption.amountOffsets` binds the acquired amount into the request calldata,
with one list per leaf. Clear any issuer allowance afterward. Receipt units and queries
are issuer-specific; they can represent pending entitlement, claim tokens or
immediate proceeds. A request is not a settled redemption.

Trade size is governed by `LiquidLaneConnector`'s on-chain budget and discount
policy. The LL recipe adds no per-execution RWA or funding cap, so a single
execution may consume the connector's remaining budget. Funding, exact payment
and RWA deltas, allowance cleanup and redemption receipt checks remain enforced.
Scaled receipt rates retain checked multiplication/division because there is no
recipe input cap proving the product safe. The builder still folds a `1/1` rate.
Rebuild existing committed LL recipes to adopt the removal of the extra caps.

### 3F

Create `ThreeFPolicy` through its `MigratablesFactory` with `abi.encode(account)`.
The account is set once and has no setter. Configure budgets for
`(funding token, collateral underlying)` through authorized `account.manage` calls
with both addresses pinned: `setMaxAssetsPerDuration(asset, underlyingAsset, maximum, duration)`.
Configure the shared collateral-underlying yield floor with
`setMinYieldPerRequest(underlyingAsset, minimum)`. Different funding tokens have
independent budgets and share the same minimum for a given underlying.

`consume(request, assets, yieldAssets)` validates factory membership, a decimal
intent ID after the name's first eight bytes, the facility's request binding and
its target position manager for subscriptions or deposit position manager for redemptions. It resolves both asset keys from the live request.
New auction requests with the same pair share cumulative usage. A retargeted
request can consume only an explicitly enabled pair. The guarded mint also pins
the pair selected when building the leaf and checks its exact budget debit;
retargeting to another underlying reverts even when that other pair is enabled.

Install `RecipeCapability` on the account. `ThreeFExecuting` builds one executor
from 1–32 `Config` entries, each with a distinct funding-token/underlying pair
and the same custody account. Each market owns a disjoint
`[request, authorizedPrincipal, authorizedYield]` input triple. Read the latter
two from `mintAuthorization(account)` before submitting the transaction; the
capability rechecks both live values before consuming any policy budget.

The host selects the authorized market and sets inactive triples to zero. Their
funding withdrawals and guarded mints are skipped. Funding `prepare` calls are
rejected, and the complete recipe rejects an all-zero principal vector. One
host sender and durable journal serialize offer leases across all markets.

Vault-solver's `threef-merkle` solver owns auction discovery, offer management,
authorization selection and lease validation. Its provider supplies these three
inputs after validating the complete guarded permission. No request-factory
scan runs in the transaction.

The executor binds the same request source into all seven masked request words:
every query target, the mint target and the nested request input used by
consume and approvals. Its committed bindings overwrite caller-supplied payload
words before `account.manage()` invokes `RecipeCapability.execute()`. Changing
auctions with the same funding pair needs neither a new leaf nor a new recipe.
Grant this masked leaf role only to the committed executor or a trusted curator;
direct leaf holders must bind these slots coherently themselves.

Inside the leaf, the account verifies the request's funding token, consumes the
policy, resets and grants the exact allowance, mints, clears the allowance, and
checks exact cash/PT/YT movements and the pinned pair's budget debit. Allowance
checks reject unsuccessful approvals
or cleanup. Every failure rolls back the complete sequence. Do not authorize
separate raw mint or unrestricted approval leaves. Only the bound account can edit
limits through approved configuration leaves; a zero maximum disables spending
without erasing usage.

`BuildRecipe` checks the policy's bound account and publishes `mintLeafTarget`,
`mintLeafData`, `mintLeafMask`, `mintLeafHash`, `requestSource`, `principalSource`,
`yieldSource` and both limit setters, plus the three input indices.
The builder resolves and pins `underlyingAsset` for configuration and the mint leaf;
`.addresses.asset` selects
the funding token and `.addresses.request` supplies the initial request. It derives
the mint leaf hash before encoding the recipe; `.leaves.mint` is ignored and a
separate request-approval leaf is unnecessary. Pure `ThreeFExecuting` callers
supply `Config.mintLeaf` and `Config.underlyingAsset` for every entry and pass
the array to `ThreeFExecuting.build`. The returned layouts expose each group's
disjoint input bindings.

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
  managed calls. All reads are unconditional. Legacy `readIf` helpers select fallback values for an unused
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

## Configuration storage

The executor stores the recipe hash, the event block packed with caller, and its
owner. Increasing recipe size does not increase persistent storage; the full
recipe is supplied on every execution.

## Verification

```sh
forge test --no-match-contract '.*(Mainnet|Benchmark).*'
forge test --match-contract RecipeOptimizationTest --fuzz-runs 1000 -vv
```

Local tests execute production adapter, capability, connector and executor code
with explicit lending/issuer fixtures. They do not prove issuer onboarding or
live mainnet liquidity. Dedicated fork suites require their RPC configuration.

### Source reads and cleanup

Cleanup emits ordinary `Approve(0)` with current proof and role checks.
`skipUnusedReads` selects fallback values using arithmetic; every configured
query still executes and must succeed. Source `prepare` calls run unconditionally
before capacity reads. Native 3F selection rejects these preparation calls so an
empty authorization can complete without state changes. Other source recipes
must use preparations whose side effects are safe to repeat.

Rebuild executor recipes and guarded 3F leaves, masks and roles together.

The Aave recovery/claim examples read health directly from
Aave V3 `Pool.getUserAccountData(account)` at byte offset `160`, avoiding the wrapper.
Here `account` is the MerkleAccount or actual borrowing subaccount. Aave V4 Spoke
uses offset `64` for health factor; offset `160` is collateral count. The existing
Aave health helper and these examples use the V3 layout only.
The debt query must still use the repayment asset's debt-token balance: Aave's
aggregate debt tuple word is denominated in base currency, not repayment units.
The health wrapper remains available for integrations that need its scalar ABI.

The Aave capacity helper now returns early when the account has no borrow bits
and defers oracle/price queries until collateral sizing needs them. It reuses
reserve configuration while retaining active/paused, eMode, isolation and
rounding checks. Differential tests compare capacity with the original implementation and then
perform the withdrawal while checking health.

The Morpho helper stops scanning adapters when idle underlying already covers
the owner's valued shares. Share valuation and transfer/withdraw gates still
apply. The withdrawal tests check capacity and execute the withdrawal.
