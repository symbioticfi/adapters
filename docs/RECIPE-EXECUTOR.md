# Configurable strategy execution

`RecipeExecutor` stores a curator-defined sequence of approved leaf calls. Each
action carries its argument bindings, calculations and before/after conditions.
The provider supplies execution inputs, current proofs and signatures. A failed
call or condition reverts the entire transaction.

The Merkle adapter enforces call permissions and reserved assets. The recipe
selects which leaves run, in what order, with which amounts and relationships
between their results. Protocol conditions already committed inside a guarded
leaf, such as a borrowing health floor, remain enforced by that leaf.

## Ownership and authorization

1. Deploy through `ImmutableFactory(type(RecipeExecutor).creationCode)` using
   `create(abi.encode(curator, adapter))`.
2. The curator calls `setRecipe(recipe)` and `setCaller(provider)`.
3. Grant the executor the required adapter leaf roles. The provider needs only
   permission to call the executor, not those adapter roles.
4. The provider calls `execute(inputs, runtime)`.

The owner stores the configuration. The caller cannot replace the selected
leaves, their order, bindings or conditions. A supplied action must match the
specific leaf configured for its step, not merely some other permitted leaf.
`adapter.manage()` checks the final calldata against the current root and roles.

`setRecipe` replaces the stored recipe and emits its typed configuration.
`bytes[] public steps` stores one ABI-encoded `Step` per action; `steps(index)`
returns that encoded step. Setters cannot run during execution. Setting the
caller to zero disables execution. Owner updates also apply to pending calls;
there is no recipe hash/version guard.

## Action schema

```solidity
enum Kind { Manage, Approve, Invoke }
enum Source { Literal, Input, Result }
struct Value { Source source; uint256 value; }
struct Binding { uint256 offset; Value value; }

struct Step {
    Kind kind;
    Value amount;
    bytes data;
    Expression[] beforeExpressions;
    Check[] checksBefore;
    Observation[] observations;
    Expression[] afterExpressions;
    Check[] checksAfter;
}
```

| Kind      | Stored `data`                                        | `amount`                | Execution runtime                               |
| --------- | ---------------------------------------------------- | ----------------------- | ----------------------------------------------- |
| `Manage`  | `abi.encode(bytes32[] leaves, Binding[][] bindings)` | Nonzero execution guard | Canonical `abi.encode(IMerkleAdapter.Action[])` |
| `Approve` | `abi.encode(token, spender, leaf)`                   | Allowance to set        | `abi.encode(Permission(dataMask, proof))`       |
| `Invoke`  | `abi.encode(target, selector, Binding[])`            | Unused                  | Complete call data                              |

`Manage` executes one leaf or a fixed ordered group through the adapter.
`Approve` is a leaf-backed convenience: it constructs token approval through the
adapter, resets a nonzero allowance before a new nonzero allowance when needed,
and checks token return values. Both reset and approval must match the configured
leaf. A later zero approval clears the remaining allowance.

`Invoke` is an explicit executor-originated call to a trusted configured entry
point. It is used for `ThreeFPolicy.consume`, whose authorization requires the
executor as caller. It grants no adapter authority and must not replace ordinary
protocol leaves. Direct calls send no native value and never delegatecall.

Each action executes in this order:

1. Evaluate `beforeExpressions` and append their numeric results.
2. Require every `checksBefore` comparison to hold.
3. Freeze observation queries and capture delta baselines.
4. Resolve bindings and execute the configured action.
5. Read observations and append their results.
6. Evaluate `afterExpressions` and append their results.
7. Require every `checksAfter` comparison to hold.

A zero `Manage.amount` skips the call, runtime decoding and call bindings.
Its expressions, observations and conditions still run. This lets a zero funding
shortfall skip withdrawal while checking that no cash was received or spent.

## Values, queries and conditions

`Literal` contains a full uint256. `Input` indexes `execute` inputs. `Result`
indexes a numeric result that has already been populated during this execution.
Results are global across actions, ordered as each step's before expressions,
observations and after expressions. Calls and comparisons allocate no numeric
result slots. A result can populate any number of subsequent arguments.

`Expression` contains `{ operation, a, b, c, data }`. Arithmetic operands are
`Value`s; they are not a three-variable stack. Expressions are attached to their
action, not separate execution steps.

| Operation            | Effect                                                                                  |
| -------------------- | --------------------------------------------------------------------------------------- |
| `Read`               | Decode `Query` from `data`, bind its arguments, STATICCALL and return its selected word |
| `Add`, `Subtract`    | Checked uint256 addition/subtraction                                                    |
| `SaturatingSubtract` | Subtraction floored at zero                                                             |
| `Minimum`            | Minimum of two operands                                                                 |
| `MulDiv`             | `floor(a * b / c)` using OpenZeppelin Math                                              |

```solidity
struct Query {
    address target;
    bytes data;
    Binding[] bindings;
    uint256 offset; // Byte offset in the return data.
}

enum Comparison { Equal, GreaterOrEqual, LessOrEqual }
struct Check { Value a; Value b; Comparison comparison; }

enum ObservationKind { After, Increase, Decrease }
struct Observation { Query query; ObservationKind kind; }
```

An observation replaces manually configured before/after reads and subtraction.
`After` returns the post-action word. `Increase` returns after minus before;
`Decrease` returns before minus after. Movement in the opposite direction reverts.
A check can compare this observation to an input, literal or previous result.

Observation queries and their argument bindings are fixed before the action.
The same concrete query is used for both sides of a delta. Its bindings cannot
reference that action's later observations or after-expression results. A Pareto
query can therefore use a previously read epoch consistently even if execution
changes the current epoch.

Bindings replace complete 32-byte calldata words after the selector. They are
sorted, nonoverlapping and in bounds, and preserve calldata length. Offsets are
relative to the individual call, not the outer `Action[]` wrapper. Nested ABI
words need not align with outer words. Leaves must pin the relevant nested
headers, lengths and all nonvariable fields.

Managed actions are checked against their configured leaves **after** binding,
then passed to `adapter.manage()`. A binding cannot alter a pinned token,
recipient or market. Signatures must remain valid for the resulting signed
content. Read queries and local policy calls originate from the executor;
protocol leaves and approvals originate from the adapter.

## Configuration and identity

Select approved leaves and derive addresses from their verified configuration.
The recipe does not repeatedly compare duplicated adapter/vault/token settings.
The connector already restricts calls to its bound adapter, and the adapter
checks reserved-asset coverage after every managed group.

A Merkle leaf commits call data, not a target's internal storage. In particular,
Liquid Lane's payment asset is stored in the connector rather than supplied to
its signed swap. Verify connector deployment, adapter binding and payment asset
when configuring the automation. The frontend revalidates these relationships
before saving. Offline script inputs must be verified separately.

Mutable protocol state still needs checks when it affects the strategy: live
liquidity, debt, health, authorization, receipts and economic outputs. If a
condition is already enforced by a guarded leaf, do not add a duplicate recipe
condition. Changes to that leaf's health floor require an accepted root update.

## Build recipes

The JSON templates in `script/recipes/examples/` use illustrative addresses and
leaf hashes. Replace them with verified configuration and run, for example:

```sh
forge script script/recipes/BuildRecipe.s.sol:BuildRecipe \
  --sig 'run(string,string)' \
  script/recipes/examples/ll-executing.json out/ll-executing-recipe.json
```

Other templates are `lending`, `3f-executing`, `health-recovery` and `health-claim`.
The script does not read RPC state, sign, deploy or broadcast. Its output contains
the encoded recipe, curator transaction calldata, constructor arguments and
named `stages` with inclusive start and exclusive end action indices. An optional
factory address adds `factory.create` calldata.

Allocate one `runtime` entry per action step, not per expression or observation.
Generated layout fields identify the relevant source, policy, approval and
operation entries; result references are separate from action indices.

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
Available cash excludes adapter reservations. Sources report capacity in funding
asset units and must deliver their calculated amounts.

Each source's `amountOffsets` has one list per leaf; use an empty list for a leaf
without a bound amount. Aave withdrawal uses `[[36]]`; ERC-4626 withdrawal uses
`[[4]]`. Never substitute a funding amount into an argument denominated in
another token or representing a request ID.

Inputs are `[rwaAmount, quotedPayout]`, bounded by configured per-run limits. The
swap's outer amount argument is bound automatically. The connector validates
discount signatures, deadlines, nonce invalidation, its minimum discount, oracle
pricing and period budget. It transfers RWA to the adapter and payment to the
leaf-pinned recipient. Recipe observations check the exact cash debit, recipient
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
- Write return data is not exposed as arbitrary numeric results. Use supported
  queries/observations, or a suitable helper for otherwise unavailable request IDs.
- Native-value managed actions are rejected. Direct local calls also send zero value.
- Proofs and roles remain necessary under the current root. A recipe cannot add authority.

## Verification

```sh
forge test --no-match-contract '.*(Mainnet|Benchmark).*'
```

Local tests execute production adapter, capability, connector and executor code
with explicit lending/issuer fixtures. They do not prove issuer onboarding or
live mainnet liquidity. Dedicated fork suites require their RPC configuration.
