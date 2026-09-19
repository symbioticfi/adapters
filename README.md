# Symbiotic Adapters

This repository hosts adapters for Symbiotic vaults, connecting them to lending, yield, restaking, and tokenized-asset protocols. It includes adapter factories, protocol accounts and oracles, conversion and reward helpers, deployment scripts, and their test suites.

## Adapter families

- Adapters: Aave V3, Euler, ERC-4626, Morpho Vault V2, App, Restaking App, ThreeF, Liquid Lane, and Merkle.
- Liquid Lane accounts and oracles: async redemption, cooldown/cutoff, settlement, Chainlink, ERC-4626, and integrations for Lido, EtherFi, Midas, Makina, OpenEden, Pareto, Spiko, Superstate, and other supported protocols.
- Shared helpers: CoW Swap conversion, Merkl claiming, account registries, and token-to-redeem account implementations.

### Merkle adapter

`MerkleAdapter` executes batches of ordinary calls authorized by Merkle proofs.
Each leaf binds the target, a zero/nonzero native-value byte, calldata mask, and
masked calldata. The leaf hash is also the access-control role: the administrator
uses `grantRole(leafHash, executor)` and `revokeRole(leafHash, executor)` to control
who can execute that permission. Every action requires its leaf role, including
calls from the administrator. The adapter checks all proofs and leaf roles before
executing any call. The protocol publishes candidate roots through `RootRegistry`,
and the adapter owner accepts the active root.

The leaf encoding is
`keccak256(bytes.concat(keccak256(abi.encode(target, valueByte, keccak256(dataMask), keccak256(maskedData)))))`,
where `valueByte` is `bytes1(0x00)` when `value == 0` and `bytes1(0xff)` otherwise.
Callers supply `Action(target, value, data, dataMask, proof)`; its role is derived
from those constraints. All 96 bits of native-currency `value` are forwarded unchanged.
Mask bits are `0` for fixed data and `1` for variable data; `maskedData = data & ~dataMask`.
Callers can change a nonzero `value` to another nonzero amount and change variable
calldata bits while reusing the same proof and leaf role. Zero-value calls have a
separate leaf and role. Curators can limit native-currency
outflows with `setLeafLimits` using `address(0)` as the asset.

Regenerate the committed fixture with `python3 script/utils/update_merkle_fixture.py`;
add `--check` to verify that its hashes and proofs match the action constraints.

An oracle created through the configured oracle factory reports portfolio assets
and an accounting nonce. The adapter tracks pending allocations and deallocation
reserves across those oracle epochs. `reservedAssets()` reports the current reserve,
including matured withdrawals before synchronization. Executor reads that value
without duplicating nonce arithmetic, and managed calls must preserve reserved idle
assets. The oracle implementation is supplied separately.

#### Installed capability implementations

`CapabilitiesRegistry(protocolOwner)` stores approved selectors for each adapter
and capability. The protocol owner replaces the complete list with:

```solidity
registry.whitelistCapability(adapter, implementation, selectors);
```

An empty list unwhitelists the capability. No separate proposer, acceptance
contract, or immutable registry manifest is required. The adapter owner chooses
when to install an approved implementation with `addCapability(implementation)`.
See [capability governance](docs/capability-governance.md).

Deploy the Merkle adapter implementation with `(vaultFactory, adapterFactory,
oracleFactory, rootRegistry, capabilitiesRegistry)`. The registry is fixed for
that implementation and exposed as `CAPABILITIES_REGISTRY()`. Multiple adapters
can share it; their approvals are independent.

Installation copies the current selectors into the adapter and reverts atomically
on duplicate selectors or a collision with another installed capability. Native
adapter and proxy functions retain dispatch precedence. Discover implementations
through `getCapabilities()` and `isCapability(implementation)`, installed selectors
through the adapter's `capabilitySelectorsLength(implementation)` and indexed
`capabilitySelectors(implementation, index)` getter, and routes through
`capabilityBySelector(selector)`. Registry selector reads use the same getters
with the adapter address as the first argument.

The adapter uses OpenZeppelin's `Proxy` to delegate calls to installed capability
code. Caller, value, adapter storage, return data, and revert data are preserved.
Dispatch only reads state, so view callbacks work under `STATICCALL`. Empty
calldata uses the payable receive function; incomplete or unknown selectors revert.

Registry edits affect future installations only. Installed functions remain active
until the adapter owner calls `removeCapability(implementation)`, which clears the
locally copied selector list without consulting the registry. To adopt a changed
list, remove and reinstall the capability. These calls can be batched atomically
with the adapter's `multicall`. Only reviewed direct implementations fit this model;
upgradeable capability proxies are outside it.

Adding and removing routes do not execute initialization or migration hooks,
clear capability storage, cancel orders, or revoke token allowances. Capability
configuration functions must enforce their own authorization and initialization
rules; an owner can include them in an atomic multicall where appropriate.
Implementations must use compatible namespaced storage, preserve or resolve
outstanding obligations before replacement, and authenticate their protocol
callbacks. Delegatecall grants full access to adapter storage: selector
registration is an entrypoint list, not a storage or custody sandbox. Callback
implementations must enforce their own liquidity/reserve invariants; the fallback
does not run the final `manage` reserve check or enable nested `manage` execution.

#### Immutable deployment factory

`ImmutableFactory` inherits the core `Registry`. Its constructor fixes the
implementation's **creation bytecode**. Anyone can call `create(bytes data)`;
this deploys an ordinary contract with `CREATE(creationBytecode ++ data)` and
registers the returned address. `data` contains ABI-encoded constructor arguments.
Repeated calls create distinct instances, including when their arguments match.
The factory has no bytecode setter or owner.

Use separate factory instances for each logical type:

```solidity
address guardedFactory = address(new ImmutableFactory(type(GuardedCallsCapability).creationCode));
address executorFactory = address(new ImmutableFactory(type(ThreeFExecutor).creationCode));

address guardedCapability = IImmutableFactory(guardedFactory).create("");
address executor = IImmutableFactory(executorFactory).create(abi.encode(owner, adapter, requestsFactory));
```

The deployed constructor sees the factory as `msg.sender`, so ownership must be
passed explicitly, as it is for Executor. `isEntity`, `totalEntities`, `entity`,
and `AddEntity` provide deployment discovery. Constructor reverts are bubbled;
failed deployments or empty runtime code leave the registry unchanged.

Factory registration records deployment provenance. GuardedCallsCapability goes
through registry whitelisting and adapter installation. Its calls and health
thresholds are fixed in accepted Merkle leaves; the capability has no storage.

#### Capabilities and Liquid Lane connector

`GuardedCallsCapability` is a directly deployed implementation installed through
its capability registry. Merkle leaves target the adapter itself; the fallback
delegates to the implementation, so protocol calls, funds and positions belong
to the adapter. Its `onlyMyself` modifier requires Merkle-authorized self-calls.
The capability is stateless; its health minimums belong to the leaves.

Signature validation is native to `MerkleAdapter`. Approved signature envelopes
select stateless external validators such as `LiquidLaneSignatureValidator`,
without installing them as capabilities. Validators run through static calls.
Token approval calls require their own accepted leaves or a fully approved
guarded sequence.

`LiquidLaneConnector` remains a factory-created, adapter-bound proxy called normally.
It holds RWA inventory separately, checks the saved oracle and asset budget, sends
RWA to the adapter, and transfers payment directly from the adapter to the recipient.
RWA must already be delivered to the connector before `swap` executes. Its storage,
inventory, and saved oracles survive compatible factory migrations.

#### Liquid Lane token and oracle configuration

The registry owner calls `OracleRegistry.setOracle(adapter, tokenToRedeem, oracle)`.
Here `adapter` is the **LiquidLaneConnector proxy address**: the connector looks up
`OracleRegistry.oracles(address(this), tokenToRedeem)`. Each approval is scoped to
that connector and token. Oracles are deployed separately and must price the RWA in
the connector's configured `inputAsset`.

The curator calls `addTokenToRedeem(tokenToRedeem)` through an authorized Merkle
leaf. The connector requires a nonzero registry entry and saves it in its own
`oracles(tokenToRedeem)` mapping. Adding a configured token reverts.
`removeTokenToRedeem(tokenToRedeem)` removes the token from the list and clears its
saved oracle. Both functions require calls from the bound MerkleAdapter; grant
their leaf roles only to the curator or its configuration executor.

Replacing or clearing the registry entry leaves an already-saved oracle active.
To accept a replacement, submit removal followed by addition in **one
`MerkleAdapter.manage` transaction**. If addition fails, removal is rolled back.
Removal and re-addition preserve budget configuration, current usage, and token
inventory. Removed tokens cannot be quoted or swapped; removal may reorder the
enumerated token list.

Initialization remains `abi.encode(adapter, inputAsset, tokensToRedeem[])` and
now permits an empty list: create the connector, register its oracles, then add its
tokens and configure budgets through Merkle leaves. A nonempty initial list
requires approvals for the connector's predicted address before creation. Existing
connector storage and saved oracles survive migration; the new implementation must
point to a registry using the new direct-oracle interface.

#### Curator asset budgets

For 3F, each executor has a separate `ThreeFPolicy`. Its owner calls
`setMaxAssetsPerDuration(maxAssets, duration)` and `setMinYieldPerRequest(minimum)`
directly; these settings do not require Merkle leaves or root updates. The budget
charges cumulative request principal in the vault asset's base units. Claims do
not refund it. Policies are independent: the curator is responsible for avoiding
multiple executors with duplicate budgets for the same asset.

LiquidLaneConnector retains `setMaxAssetsPerDuration(asset, maxAssets, duration)`
through a dedicated Merkle leaf. Its asset key is the **RWA token** and the budget
charges `swap.amountOut` in `inputAsset` base units. For either policy, a USDC
budget of `1_000_000e6` with duration `1 days` permits one million USDC per period.

Periods start at configuration and retain fixed boundaries. Spending at the
exact end of a period uses the next period's budget; unused capacity does not
accumulate. Adjacent periods each have their full budget. Repeating the same
configuration, changing the maximum, or disabling and reenabling an asset
does not erase active usage. Changing the duration starts a period at the
current timestamp and carries forward any unexpired usage.

Duration must be nonzero. A zero maximum disables funding, and policies
and connectors without a configured budget cannot spend. The connector's
`assetLimits(asset)` and policy's `assetLimit()` expose configuration and usage;
`remainingAssets(asset)` and `remainingAssets()` include any elapsed period reset.
Failed transactions restore usage, including failures after
Executor liquidity preparation. Finalizing a 3F position does not refund the
period's funding budget.

#### Per-leaf asset budgets

The adapter owner calls `setLeafLimits(leaf, [{asset, maxAssets, duration}, ...])`.
`getLeafLimits(leaf)` returns this configuration array; `leafAssetLimits(leaf, asset)`
returns its saved maximum, duration, period start, and spending. These settings are
separate from leaf membership and caller roles.

For each managed call, the adapter snapshots the listed balances, executes the
call, and charges each net decrease to that leaf's fixed-period budget. Multiple
calls and callers share the leaf's budget. A balance increase does not refund
usage. Zero asset means native currency; zero maximum prohibits net outflows.
Limits use token base units. Reconfiguration and removal/readdition preserve
unexpired usage; changing duration carries usage into a period starting now.

Unlisted assets are unmonitored; an empty array removes the leaf's limits. These
checks measure synchronous balance changes only. An `approve` or signature leaf
has no token outflow at that moment, so it does not budget a later external fill.
Curators must constrain those authorizations through granular leaf permissions
and the authorized order amounts, and monitor outstanding approvals and orders.

Any failed budget check reverts the entire batch and its usage. At the end of
`manage`, vault-asset balance must also cover `deallocatable` plus pending
allocations for the current and next oracle epochs. Temporary shortfalls inside
the batch are allowed if restored before completion.

#### NAV Oracle

`periphery/Oracle.sol` implements the adapter's existing `nonce()` and
`totalAssets()` interface. Its implementation constructor takes
`(factory, forwarder, workflowId, maxReportAge)`; the existing oracle factory
creates a proxy initialized with `abi.encode(adapter)`. The factory owner approves
the implementation, and the oracle owner can migrate to a newly approved version.
Forwarder, exact workflow ID, and maximum snapshot age are fixed in implementation
code. There is no direct curator NAV submission override.

[Chainlink's KeystoneForwarder](https://github.com/smartcontractkit/chainlink-evm/blob/b6427ea1f4847d640abdf24dbd6c6f01d7799d59/contracts/cre/src/v1/KeystoneForwarder.sol)
verifies DON signatures and invokes `onReport(metadata, report)`. The Oracle checks
the forwarder and workflow identity and supports the CRE `IReceiver` ERC-165 ID.
It accepts production's 64-byte metadata and the 62-byte workflow identity format;
see [Chainlink's receiver documentation](https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts).

The payload is `abi.encode(IOracle.Report)`:

| Field               | Source / meaning                                                    |
| ------------------- | ------------------------------------------------------------------- |
| `chainId`           | Destination EVM chain ID                                            |
| `oracle`            | Destination oracle proxy                                            |
| `adapter`           | Valued MerkleAdapter                                                |
| `nonce`             | NAV report's `oracleUpdate.nextNonce`; must equal current nonce + 1 |
| `totalAssets`       | `oracleUpdate.oracleAssets`, in vault-asset base units              |
| `snapshotBlock`     | Report's finalized `block.number`                                   |
| `snapshotTimestamp` | Report's finalized `block.timestamp`                                |

Wrong destinations, malformed payloads, duplicate/skipped epochs, nonadvancing
snapshots, future snapshots, and snapshots older than `maxReportAge` revert.
The approved workflow is responsible for valuation and snapshot correctness;
the Oracle only authenticates and stores its result. NAV already excludes the
pending allocations and matured deallocation reserves that the adapter adds back.

Accounting remains in [merkle-adapter-nav](https://github.com/symbioticfi/merkle-adapter-nav).
Its submission client is currently an in-memory mock. This PR supplies the on-chain
receiver and wire format; live CRE report generation/submission still needs wiring
in that repository. Tests exercise signed reports through the pinned forwarder
source, including its actual signature verification, ERC-165 probe, and callback.

#### CoW Swap orders

CoW uses ordinary Merkle leaves. The adapter calls the settlement's
`setPreSignature(orderUid, true)` to authorize an order and
`setPreSignature(orderUid, false)` to cancel it. Token allowances are separate
`approve(vaultRelayer, amount)` leaves. No capability installation or adapter-local
order registry is required. The client computes the GPv2 order UID and submits the
order to CoW's order book.

The UID contains a 32-byte order digest, 20-byte owner, and 4-byte expiry. A reusable
leaf fixes the owner to the adapter, the settlement, boolean, ABI layout and padding;
only digest and expiry vary. This grants authority over all hashed order fields,
including token pair, receiver, amounts and order kind. A leaf with the entire UID
fixed instead authorizes one exact order. Token allowance permissions do not restrict
the order-signing role to a pair. Cancellation has its own leaf role.

Orders remain valid until filled, expired or explicitly cancelled. Signing another
order, replacing the root or revoking a role does not revoke existing signatures.
Cancellation does not clear token allowances; use the token approval leaf separately.
CoW settlement is asynchronous and runs outside `manage`. Its later spending is not
charged by the per-leaf before/after balance check or covered by that call's final
idle-reserve check.

#### Liquid Lane consumer redemptions

Deploy `LiquidLaneSignatureValidator(reactor, protocol)` directly. The validator
has no mutable state and needs no capability installation. The **MerkleAdapter is
the consumer/swapper** and stores its own approved signatures:

```solidity
bytes32 digest = validator.hashRequest(request);
bytes memory signature = abi.encode(address(validator), abi.encode(request));
// Execute this adapter self-call through manage with the required proof and role.
adapter.setSignature(digest, signature);
```

The setter's Merkle leaf must fix the validator address and request policy fields,
including permitted input/output tokens, recipients and protocol. Amounts, nonce,
deadline and digest may vary only where the approved mask permits. The validator
recomputes the Reactor's EIP-712 digest and checks positive amounts, adapter-owned
outputs, protocol, deadline and the adapter's Reactor nonce. Submit the exact saved
envelope as the consumer signature to the Liquid Lane API and Reactor.

Tokens remain on the adapter. Reactor allowances use separate ERC-20 `approve`
leaves. Saving or clearing signatures neither transfers funds nor changes
allowances. Funding is checked at settlement; asynchronous spending is outside
`manage`'s per-leaf balance accounting and final idle-reserve check.

Several requests for the same token may coexist. Clear an authorization with
`setSignature(digest, bytes(""))` through its own approved self-call. Permanently
cancel its nonce through a direct `Reactor.invalidateNonce(nonce)` leaf. Filling
or cancelling a nonce invalidates all requests using it; expired requests are
also invalid. No finalize transaction is needed. Saved envelopes remain readable
until explicitly cleared, and changing roles or roots does not revoke them.

#### Guarded protocol calls

Deploy one constructorless, stateless `GuardedCallsCapability` and install its
`execute` selector. Add protocol calls and conditions through proposed, accepted Merkle leaves.

`execute(Call[] calls, Check[] checks)` performs ordinary calls as the adapter,
with preconditions, postconditions, or checked balance increases/decreases. Each
condition reads one unsigned word from a static query, then applies `==`, `>=` or
`<=` to a literal value or a word of the approved call's calldata. Delta baselines
are captured before writes. Failed conditions revert all calls. Empty checks permit
the explicitly approved unguarded sequence.

For borrowing, use one native lending call followed by an `After` / `GreaterOrEqual`
health check with a literal minimum, for example `1.2e18`. The leaf commits this
threshold along with the query. Changing the threshold requires a new accepted
leaf and its role; it cannot be changed by an execution-time input or setter.

Leaves must pin all targets, selectors, accounts, ABI layout, full checks and query
calldata. Only intended call amounts vary through the Merkle mask. Calls have no
native value and no calldata substitution. The capability has no storage, VM,
arithmetic, protocol-specific state or intermediate-call checks. Approvals are
ordinary calls and must also be approved by the leaf.

The existing `AaveHealthFactor`, Morpho and Euler scalar helpers remain reusable.
Aave's raw `getUserAccountData` can also be queried at return offset `160`.
Automation recipes execute these same approved guarded leaves; they never bypass
the capability to perform an unchecked borrow. See [guard configuration](docs/GUARDED-CALLS.md).

#### Liquidity executors

`Executor` is an abstract base. Deploy `ThreeFExecutor` through an
`ImmutableFactory(type(ThreeFExecutor).creationCode)` with
`create(abi.encode(owner, adapter, requestsFactory))`. It creates its own
`ThreeFPolicy(owner, executor)`. Deploy `LiquidLaneExecutor` through its own
factory with `create(abi.encode(owner, adapter, connector))`. The adapter and LL
connector and 3F requests factory are immutable. Neither executor holds funds or positions.

The owner selects the sole submitting account with `setCaller(caller)`; zero
pauses execution. Ownership alone does not grant execution permission. The owner
calls `setActions(sources, approvalLeaf, operationLeaf)` to configure:

- Ordered funding sources, each `{ liquidityTarget, liquidityCalldata, leaf }`.
- The funding-token approval leaf for the request or connector. Mask its amount
  so that the executor can reset an existing allowance to zero and approve the
  exact funding amount. LL fixes the connector spender. 3F masks the request
  spender as well; the executor checks that request against its factory.
- The adapter's guarded native 3F `mint` call or connector's `swap` leaf.

Read sources using `actions(index)` and `actionsLength()`. Empty sources allow
operations funded entirely by spendable idle assets. Calls, masks and proofs are
supplied at execution using `IExecutor.Execution`:

```solidity
struct Execution {
    IMerkleAdapter.Action[] actions;
    Permission approval;
    Permission operation;
}
struct Permission {
    bytes dataMask;
    bytes32[] proof;
}
```

Every configured funding call must be supplied in order, including skipped
sources. The executor checks their leaves before execution, then uses idle funds
first and queries each needed source immediately before calling it. A source
must supply exactly `min(shortfall, availableLiquidity)`. Amounts remain encoded
by the caller; the executor does not rewrite source calldata. Each step protects
the adapter's pending-allocation and deallocation reserves. Queries run as
`STATICCALL` from the executor, so encode the adapter account explicitly.

Approval is executed **through MerkleAdapter**, never from the executor's token
account. A nonzero allowance is reset before approving the exact amount; false
ERC-20 return values revert, and no-return approvals are supported. Approval and
operation calldata are constructed from typed arguments, matched to the
configured leaves and executed with current proofs and executor roles.

`ThreeFExecutor.mint(request, amount, minYield, deadline, execution)` checks
`requestsFactory.isRequest(request)` and the adapter's live mint authorization.
It charges the policy's period budget and checks its minimum yield, then prepares
exactly `amount` principal. The adapter calls the native request's `mint` through
`GuardedCallsCapability.execute` with one call and no checks. The executor requires
exact spending and at least the snapshotted authorized yield. Any failure rolls
back funding and policy usage. No request whitelist or facility lookup is used.

`LiquidLaneExecutor.swap(discountSwap, protocolSignature, recipient, amountIn,
execution, postActions)` uses the same `Discount` and `DiscountSwap` typed
structures as `LiquidLaneAdapter`. The first signer must be the executor owner
(curator) or the current owner-configured `signer`. The `discount.protocol`
account countersigns the discount hash, the first signature and its own deadline.
Both EOA and ERC-1271 signatures are supported. Sign with the EIP-712 domain
`LiquidLaneExecutor`, version `1`, current chain ID and the executor address;
signatures for another executor or the standalone adapter are not valid here.

Discounts are reusable until expiry or `invalidateNonce(token, nonce)`, callable
by the owner or configured signer. They are not consumed on each swap. The owner
may set a minimum discount per RWA with `setMinDiscount(token, ppm)` and rotate or
clear the delegated signer with `setSigner`. The two signatures do not commit a
fill size or recipient; these remain constrained by the configured caller and
Merkle operation permission, as well as the connector's inventory and funding
budget. The executor calculates the discounted funding amount from the bound
connector's quote, prepares it and checks the quote again before swapping.

Only `LiquidLaneExecutor` stores post-swap policies. The owner calls
`setPostActionLeaves(token, leaves)` for each RWA. An empty list prohibits posts;
a nonempty list requires at least one. The caller chooses any subset, order or
repetition of the permitted leaves and supplies current calldata, masks and
proofs. Read with `postActionLeaves(token, index)` and
`postActionLeavesLength(token)`.

The executor checks the swap's exact funding spend before running post-actions,
then requires their complete batch to reduce the adapter's RWA balance by
exactly `amountIn`. This supports direct redemption, approval plus redemption,
and multiple issuer requests. Existing inventory remains protected on a net
basis. Instant redemption may return funding tokens; a cooldown that retains
the RWA cannot satisfy the check. The check proves token consumption, not issuer
proceeds or completed settlement. See the [RWA integration matrix](docs/EXECUTOR-POST-ACTIONS.md).

Source order, approval/operation permissions, caller and LL policy settings cannot
change during execution. Any liquidity, signature, proof, role or balance failure
reverts the entire transaction. Configuration never grants Merkle permissions by
itself: grant all executed leaf roles to the specialized executor.

#### Configurable strategy recipes

`RecipeExecutor` adds curator-defined reads, ordered calls and numeric checks to
the adapter's leaf permissions. The owner stores the steps with `setRecipe`
and selects its provider caller. `execute(inputs, runtime)` reads the stored
steps; the provider supplies bounded inputs, concrete calls and current proofs.
Any failed postcondition rolls back the entire recipe. Deploy through
`ImmutableFactory(type(RecipeExecutor).creationCode)` with
`create(abi.encode(curator, adapter))`.

The [recipe guide](docs/RECIPE-EXECUTOR.md) includes executable definitions for
LBTC supply → checked USDC borrowing → RWA purchase, and ordered liquidity →
signed Liquid Lane swap → optional issuer redemption, and ordered liquidity →
3F request mint. `LLExecuting` and `ThreeFExecuting` build complete adapter-call
recipes without specialized liquidity executors; `LiquidityRecipe.liquidLane`
also supports composition with the dedicated LL executor. JSON examples and offline encoding commands are in
the guide. Resulting debt/claim limits constrain repeated runs; grant the required
leaf roles only to the recipe executor, with the provider as its caller.

The [health-recovery recipe](docs/HEALTH-RECOVERY-RECIPE.md) provides JSON
configurations for a health-factor trigger, ordered Morpho/Aave withdrawals and
RWA requests, followed by a separate claim-and-repay recipe. Amounts come from
live debt, liquidity and pending-entitlement reads; existing pending requests
prevent duplicate queuing.

#### 3F push offers

Create `ThreeFExecutor(owner, adapter, requestsFactory)` and configure the
resulting policy's period budget and minimum request yield. Yield is measured as
`yieldAssets * 1e6 / principal`, not an annualized APY. Only the bound executor can
consume its policy; the policy owner can update its settings immediately.

The Strategy action compiles three permissions: funding-token approval with a
variable request spender, guarded native `mint(uint128,uint128)` with a variable
request target and amounts, and guarded `burnAll(adapter, adapter)` with a variable
request target. Both operations execute in the adapter's context through `manage`.
Claims pay the adapter. The shared GuardedCalls implementation only dispatches
these calls; no dedicated 3F capability or adapter-side request registry remains.

For push offers, use the **adapter address** as `offerAddress` and `maker`, disable
callbacks, and wait for the native request's mint authorization before submitting
execution. The executor's request check is factory membership only. A curator's
direct `manage` permissions intentionally bypass the executor's funding and yield
policy; grant automation roles to the executor and configure its submitting caller.

`ThreeFExecuting` supplies the same complete flow through `RecipeExecutor`. Deploy
`ThreeFPolicy(curator, recipeExecutor)` and include its address in the recipe.
Its principal/yield charge is bound to the live authorization before funding;
post-checks verify exact adapter cash and native PT/YT changes. Native request
balances and events replace capability-specific tracking and valuation getters.

The focused tests cover authorization, reserve accounting, connector migrations and capability replacement,
and compatibility with the off-chain Merkle tree fixture:

```sh
forge test --match-path 'test/adapters/{MerkleAdapter.t.sol,merkle-adapter/*.t.sol}'
```

`ThreeFExecutorMainnetTest` validates factory membership, adapter-context native minting
and owner yield updates against deployed 3F contracts at Ethereum block `25_892_000`.
`GuardedCallsMainnetTest` uses the real Aave V3 pool at the same block.
`CoWSwapLeavesMainnetTest` settles orders through deployed GPv2 contracts at
block `25_982_370`. Set `ETH_RPC_URL` to an archive-capable endpoint to run these
tests. Liquid Lane consumer tests run the Reactor source pinned to RFQ commit
`22b04a850ca3680103e797bfae0e1a3b997fac83` against the repository's
`LiquidLaneAdapter`; their source fixture adapts compiler and import paths only.

## Layout

```text
src/contracts/            Adapter implementations, factories, accounts, oracles
src/contracts/periphery/  Permissioned liquidity preparation and execution
src/interfaces/           Adapter APIs and external protocol interfaces
test/adapters/            Unit, fuzz, accounting, Mainnet, and Benchmark suites
test/invariant/           Stateful AppAdapter invariant coverage
test/deploy/              Deployment and integration tests
script/adapters/          Direct adapter instance deployment and administration
script/deploy/            Factory and composed adapter deployment entrypoints
script/actions/           Vault and adapter administration actions
script/utils/             Shared script and formatting helpers
lib/core/                 Pinned public Symbiotic core dependency
```

The `script/adapters/` entrypoints deploy or register an adapter instance using an existing factory and configured addresses. The `script/deploy/adapters/` entrypoints use specialized base scripts for deploying adapter factories and composed protocol integrations. Choose the path that matches the deployment you are performing.

## Setup

Install Foundry `v1.8.1`, Node.js `24.20.0` from `.nvmrc`, pnpm `11.25.0`, uv
`0.12.1`, and pre-commit `4.6.2`. Initialize the pinned dependencies:

```sh
git submodule update --init --recursive
uv tool install pre-commit==4.6.2
uvx --from pre-commit==4.6.2 pre-commit install
```

Implementation contracts use `pragma solidity ^0.8.28;`. Interfaces, libraries, tests, mocks, and scripts use the lowest `0.8.x` caret pragma supported by their own language features; imports can require a newer compiler. Foundry pins the compiler to `0.8.37` and targets the Osaka EVM. Root remappings
use OpenZeppelin `5.7.0`; imports from the pinned `@symbioticfi/core` dependency
use its nested libraries where required for core compatibility. The npm package
declares the same core commit and OpenZeppelin `5.7.0` dependencies.

## Build, test, and format

Run the fast local checks first:

```sh
forge build
forge fmt --check
forge test --no-match-contract '.*(Mainnet|Benchmark).*'
```

For mainnet and benchmark suites, set `ETH_RPC_URL` in a local, Git-ignored
`.env` file. `MAINNET_FORK_BLOCK` optionally selects a fixed block. These suites
run in separate CI jobs:

```sh
forge test --isolate --match-contract '.*Mainnet.*' --no-match-contract '.*Benchmark.*'
forge test --isolate --match-contract '.*Benchmark.*'
```

Run the complete pre-commit set with:

```sh
uvx --from pre-commit==4.6.2 pre-commit run --all-files
```

The snapshot hook builds the contracts and writes size and gas reports under
`snapshots/`. It excludes Mainnet/Benchmark suites and uses one thread with a
fixed fuzz seed. Invariant tests run separately and must pass; their variable
gas measurements and handler statistics are excluded from the saved reports.
After an intentional snapshot update, review and stage the generated files.
Repeating the hook without code changes should leave those files unchanged.

## Developing adapters

Put externally visible functions, errors, events, and structs in
the relevant interface under `src/interfaces/`, then implement that interface
under `src/contracts/`. Keep Liquid Lane protocol interfaces in the matching
`src/interfaces/ll-adapter/<protocol>/` directory. Reuse the existing account, oracle,
converter, registry, and factory bases before introducing a new pattern.

New behavior needs focused unit or fuzz tests. Changes to stateful accounting,
allocation, redemption, or limits should include invariant coverage where
appropriate. Fork tests provide integration evidence only when they execute
against the intended live state; skipped fork tests do not verify an integration.

Keep dependency revisions synchronized across `.gitmodules`, `foundry.lock`,
`remappings.txt`, and `package.json`. Changes affecting compiler or dependency
bytecode can change CREATE2-derived deployment addresses; update assertions and
document that impact.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for style, testing, dependency, and pull
request requirements. The project is licensed under the [Business Source
License 1.1](LICENSE); individual files and interface subtrees retain their
own SPDX identifiers and license notices.
