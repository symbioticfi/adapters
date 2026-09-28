# Merkle Adapter

`MerkleAccount` holds strategy positions and authorizes protocol calls using Merkle proofs and enumerable roles. `MerkleAdapter` bridges the account to its vault, holds reserves and supplies oracle-backed accounting.
Each leaf binds the target, a zero/nonzero native-value byte, calldata mask, and
masked calldata. The leaf hash is also the access-control role: the administrator
uses `grantRole(leafHash, executor)` and `revokeRole(leafHash, executor)` to control
who can execute that permission. Every action requires its leaf role, including
calls from the administrator. The account checks all proofs and leaf roles before
executing any call. The protocol publishes candidate roots through `RootRegistry`,
and the account owner accepts the active root.

The leaf encoding is
`keccak256(bytes.concat(keccak256(abi.encode(target, valueByte, keccak256(dataMask), keccak256(maskedData)))))`,
where `valueByte` is `bytes1(0x00)` when `value == 0` and `bytes1(0xff)` otherwise.
Callers supply `Action(target, value, data, dataMask, proof)`; its role is derived
from those constraints. All 96 bits of native-currency `value` are forwarded unchanged.
Mask bits are `0` for fixed data and `1` for variable data; `maskedData = data & ~dataMask`.
Callers can change a nonzero `value` to another nonzero amount and change variable
calldata bits while reusing the same proof and leaf role. Zero-value calls have a
separate leaf and role.

Regenerate the committed fixture with `python3 script/utils/update_merkle_fixture.py`;
add `--check` to verify that its hashes and proofs match the action constraints.

An oracle created through the configured factory reports the whole portfolio's
NAV at a finalized block. The adapter records completed vault capital flows and
adjusts that snapshot to the present; internal transfers need no oracle update.
Allocations are usable immediately. Requested cash is staged, covered by an
accepted snapshot and released by `syncReport()`, which anyone may call. Allocation
and deallocation also synchronize automatically. Outstanding requests, staged cash
and released cash are protected from `push(amount)`.
`push` and `pull` move underlying between the adapter and paired account, with
that account as caller through approved actions. The account grants the adapter
unlimited underlying allowance during initialization.

## Installed capability implementations

`CapabilitiesRegistry(protocolOwner)` stores approved selectors for each account
and capability. The protocol owner replaces the complete list with:

```solidity
registry.whitelistCapability(account, implementation, selectors);
```

An empty list unwhitelists the capability. No separate proposer, acceptance
contract, or immutable registry manifest is required. The account owner chooses
when to install an approved implementation with `addCapability(implementation)`.
See [capability governance](capability-governance.md).

Deploy `MerkleAccount(accountFactory, merkleAdapterFactory, rootRegistry, capabilitiesRegistry)` and whitelist
its implementation in the migratable account factory. Deploy the adapter with
`(vaultFactory, adapterFactory, oracleFactory, accountFactory)`. On initialization,
the adapter creates the latest account version with its own owner and passes the
initial default admin into the account. The account requires its adapter to be registered
in the immutable `MERKLE_ADAPTER_FACTORY` before approving the underlying asset.
The adapter also creates the latest oracle version.

The account owns its root, roles, capabilities, positions and signatures. Root and
capability registries are keyed by account address. An account owner may migrate
through its factory to a whitelisted newer version; compatible migrations preserve
strategy state and custody at the same address. Account, adapter and oracle
ownership start equal but can subsequently be transferred independently.

Installation copies the current selectors into the account and reverts atomically
on duplicate selectors or a collision with another installed capability. Native
account functions retain dispatch precedence. Discover implementations
through `getCapabilities()`, installed selectors through the account's indexed
`capabilitySelectors(implementation, index)` getter, and routes through
`capabilityBySelector(selector)`. The registry instead returns a whole list from
`selectors(account, implementation)`, which is what installation copies in one read.

The account uses OpenZeppelin's `Proxy` to delegate calls to installed capability
code. Caller, value, account storage, return data, and revert data are preserved.
Dispatch only reads state, so view callbacks work under `STATICCALL`. Empty
calldata uses the payable receive function; incomplete or unknown selectors revert.

Registry edits affect future installations only. Installed functions remain active
until the account owner calls `removeCapability(implementation)`, which clears the
locally copied selector list without consulting the registry. To adopt a changed
list, remove and reinstall the capability. These calls can be batched atomically
with the account's `multicall`. Only reviewed direct implementations fit this model;
upgradeable capability proxies are outside it.

Adding and removing routes do not execute initialization or migration hooks,
clear capability storage, cancel orders, or revoke token allowances. Capability
configuration functions must enforce their own authorization and initialization
rules; an owner can include them in an atomic multicall where appropriate.
Implementations must use compatible namespaced storage, preserve or resolve
outstanding obligations before replacement, and authenticate their protocol
callbacks. Delegatecall grants full access to account storage: selector
registration is an entrypoint list, not a storage or custody sandbox. Callback
implementations must enforce their own protocol invariants. Adapter reserves stay outside capability custody; `push` always checks their coverage.

Fallback routes preserve the original caller so external protocol callbacks can
reach their installed capability. State-changing execution entry points must
check the caller: `RecipeCapability.execute` requires an account self-call reached
through Merkle-authorized `manage`. A universal self-call restriction in the
fallback would disable protocol callbacks; each callback must authenticate its
protocol caller and active execution context.

## Immutable deployment factory

`ImmutableFactory` inherits the core `Registry`. Its constructor fixes the
implementation's **creation bytecode**. Anyone can call `create(bytes data)`;
this deploys an ordinary contract with `CREATE(creationBytecode ++ data)` and
registers the returned address. `data` contains ABI-encoded constructor arguments.
Repeated calls create distinct instances, including when their arguments match.
The factory has no bytecode setter or owner.

Creation bytecode uses Solady `SSTORE2`. The EVM code-size limit allows 24,575 bytes
plus SSTORE2's one-byte prefix; SSTORE2 reverts with `DeploymentFailed` when that
deployment fails. `implementationPointer()` returns the storage-contract address;
`SSTORE2.read(pointer)` returns the original bytes.
The storage contract consumes a factory nonce during construction, so predict
instance addresses from the factory's actual nonce, not a fixed starting value.

Use separate factory instances for each logical type:

```solidity
address recipeCapabilityFactory = address(new ImmutableFactory(type(RecipeCapability).creationCode));
address executorFactory = address(new ImmutableFactory(type(RecipeExecutor).creationCode));

address recipeCapability = IImmutableFactory(recipeCapabilityFactory).create("");
address executor = IImmutableFactory(executorFactory).create(abi.encode(owner, account));
```

The deployed constructor sees the factory as `msg.sender`, so ownership must be
passed explicitly, as it is for Executor. `isEntity`, `totalEntities`, `entity`,
and `AddEntity` provide deployment discovery. Failed deployments or empty runtime
code revert with `DeploymentFailed` and leave the registry unchanged.

Factory registration records deployment provenance. RecipeCapability goes
through registry whitelisting and account installation. Its calls and health
thresholds are fixed in accepted Merkle leaves; the capability has no storage.

## Capabilities and Liquid Lane connector

`RecipeCapability` is a directly deployed implementation installed through
its capability registry. Merkle leaves target the account itself; its fallback
reads its locally installed route and delegates to the implementation, so protocol calls, funds and positions belong
to the account. The self-call check requires Merkle-authorized account calls.
The capability is stateless; its health minimums belong to the leaves.

Signature validation is native to `MerkleAccount`. Authorized self-calls approve
EIP-712 digests computed from a domain separator and explicit encoded fields.
The leaves fix each protocol's domain, token pair, recipient and order type.
Token approval calls require their own accepted leaves or a fully approved
guarded sequence.

`LiquidLaneConnector` remains a factory-created, account-bound proxy called normally.
Its immutable `MERKLE_ACCOUNT_FACTORY` must register the account: initialization
requires `isEntity(account)` from that factory.
It holds RWA inventory separately, checks the saved oracle and asset budget, sends
RWA to the account, and transfers payment directly from the account to the recipient.
RWA must already be delivered to the connector before `swap` executes. Migration
into this connector implementation always reverts.

## Liquid Lane token and oracle configuration

The registry owner calls `OracleRegistry.setOracle(connector, tokenToRedeem, oracle)`
with the **LiquidLaneConnector proxy address**: the connector looks up
`OracleRegistry.oracles(address(this), tokenToRedeem)`. Each approval is scoped to
that connector and token. Oracles are deployed separately and must price the RWA in
the connector's configured `outputAsset`.

The curator calls `addTokenToRedeem(tokenToRedeem)` through an authorized Merkle
leaf. The connector requires a nonzero registry entry and saves it in its own
`oracles(tokenToRedeem)` mapping. Adding a configured token reverts.
`removeTokenToRedeem(tokenToRedeem)` clears its saved oracle. Both functions require calls from the bound MerkleAccount; grant
their leaf roles only to the curator or its configuration executor.

Replacing or clearing the registry entry leaves an already-saved oracle active.
To accept a replacement, submit removal followed by addition in **one
`MerkleAccount.manage` transaction**. If addition fails, removal is rolled back.
Removal and re-addition preserve budget configuration, current usage, and token
inventory. Removed tokens cannot be quoted or swapped. `oracles(token)` is the membership
source; track additions and removals through events.

Initialization uses `abi.encode(account, outputAsset)`. Create the connector,
register its oracles, then add tokens through Merkle leaves. Budgets can be
configured before the token oracle is added or while a token is removed.

## Curator asset budgets

For 3F, one `ThreeFPolicy` is charged by exactly one consumer at a time. The owner calls
`setConsumer(consumer)`, `setMaxAssetsPerDuration(asset, maxAssets, duration)` and
`setMinYieldPerRequest(asset, minimum)` directly; these settings do not require Merkle
leaves or root updates. Budgets are keyed by asset and charge cumulative request principal
in that asset's base units. Claims do not refund them.

`ThreeFExecuting` supports both policy-consumption paths. With `guardedMint: true`,
set the account as consumer: `ThreeFGuardedMint` charges the policy beside the mint,
and direct managers using that leaf share its budget. With `guardedMint: false`, set
the executor as consumer: a committed `Call` charges the policy and the recipe checks
factory membership plus exact cash, principal and yield movements around a native mint
leaf. Restrict that leaf's roles to the executor so execution cannot bypass its policy.
Both paths revert the charge if minting or its checks fail. Repointing the sole consumer
blocks the previous caller and preserves current period usage; zero disables consumption.
A bare `consume` leaf only charges budget and does not enforce an accompanying mint.

`ThreeFPolicy` is a `MigratableEntity`, so its address is stable across implementation
upgrades and a migration carries the consumer, every asset budget, every minimum and the
current period's usage. The owner migrates through the factory; the inherited
migration hook ignores payloads and leaves policy storage unchanged.

LiquidLaneConnector retains `setMaxAssetsPerDuration(asset, maxAssets, duration)`
through a dedicated Merkle leaf. Its asset key is the **RWA token** and the budget
charges `swap.amountOut` in `outputAsset` base units. For either policy, a USDC
budget of `1_000_000e6` with duration `1 days` permits one million USDC per period.

Periods start at configuration and retain fixed boundaries. Spending at the
exact end of a period uses the next period's budget; unused capacity does not
accumulate. Adjacent periods each have their full budget. Repeating the same
configuration, changing the maximum, or disabling and reenabling an asset
does not erase active usage. Changing the duration starts a period at the
current timestamp and carries forward any unexpired usage.

Duration and period start use `uint48`; duration must be nonzero. A zero maximum disables funding, and policies
and connectors without a configured budget cannot spend. Both expose configuration
and usage through `assetLimits(asset)`; `remainingAssets(asset)` includes any elapsed
period reset.
Failed transactions restore usage, including failures after
Executor liquidity preparation. Finalizing a 3F position does not refund the
period's funding budget.

## Managed cash and NAV

`push(amount)` transfers underlying to the bound account only when the adapter
retains `max(pendingDeallocation, releasedLiquidity + stagedLiquidity)`. The account cannot transfer or
approve tokens held by the adapter. Delayed protocol settlements can spend only
account balances. `pull(amount)` returns funds; neither operation changes NAV.

The workflow values adapter cash, account cash, positions and pending claims,
minus external liabilities, at one finalized block. Capital moves across the
vault boundary are recorded by the adapter:

```text
netFlow = completed vault allocations - completed returns to the vault
currentAssets = reportedNAV - netFlowAt(snapshotBlock) + netFlow()
```

For a report valuing 1,000 assets, a later 150 return produces 850 current assets.
Remaining withdrawal cash is already included. Allocations do not wait for a
report. Withdrawals require cash to be staged before an accepted snapshot covers
it: request, unwind, stage, snapshot, acceptance, synchronization, release, return. Account `pull` stages cash
automatically; anyone can call `stageLiquidity()` after a direct payout. Request
updates, allocation and deallocation attempts also stage cash. Staged cash needs
a subsequent covering report.
A fixed existing stage cannot be reset by later callers; later cash may wait one
additional report. A liquidity shortage does not reject NAV. Requests, staging
and release do not change portfolio value; only actual vault transfers change flow.
The oracle only reads adapter flow history. Allocation and deallocation internally
call `syncReport()` before changing capital flows; anyone can also call it directly.
Each snapshot is applied once; intermediate report caps are not replayed if several
reports arrive between synchronization calls. Deallocation caps the payout by the requested
amount, released liquidity and fresh NAV; released liquidity remains cash-backed.
With stale NAV, `pull` can still recover cash and stage it against existing demand.
The production delegator requires fresh NAV to create or update requests.

## NAV CREOracle

`CREOracle(factory, workflowRegistry, maxReportAge)`
stores the accepted report's raw NAV in public `totalAssets`. Its `latestSnapshot()` returns
`(uint48 snapshotBlock, uint256 assets)` and reverts when the accepted valuation
is missing or older than `MAX_REPORT_AGE`, the same age bound used for delivery
and curator review. An age exactly equal to the bound remains valid.
This getter only reads oracle state;
the scalar `totalAssets()` getter returns raw NAV without checking expiry.
Adapter `totalAssets()` reconciles that NAV with its own historical and current
net flow using checked signed arithmetic.
`CREOracle` handles forwarder/workflow authentication, `setOracleLimits` and
role configuration. It initializes these fields from `ICREOracle.InitParams`,
requires the signed metadata's workflow owner to equal its immutable
`WORKFLOW_REGISTRY` and its nonzero workflow ID to match
`registry.workflowId(oracle)`, and checks movement limits during report acceptance using
checked multiplication and floor division.
Growth and loss limits use `uint32` in initialization, `setOracleLimits` and
`SetOracleLimits`; tolerance uses `uint128`.

The signed report is exactly five ABI words (160 bytes):

| Field               | Meaning                                                            |
| ------------------- | ------------------------------------------------------------------ |
| `chainId`           | Destination EVM chain                                              |
| `adapter`           | Valued adapter                                                     |
| `totalAssets`       | Whole portfolio NAV, net of liabilities, in vault-asset base units |
| `snapshotBlock`     | Finalized completed block, `uint48`                                |
| `snapshotTimestamp` | Timestamp of that same block, `uint48`                             |

The oracle reads snapshot capital flows from the adapter's checkpoints. Blocks and
timestamps must strictly advance. Snapshot blocks must be completed, timestamps
cannot be in the future, and snapshot age must not exceed `MAX_REPORT_AGE`.
The workflow chooses its reporting cadence within that freshness budget.
There is no nonce, cutoff, buffer or excluded-reserve field. One staged
cash amount/block replaces cutoff-based allocation and withdrawal batches.
Movement limits compare portfolio values after reconciling capital flows.

The provider proposes workflow artifacts and the current oracle owner accepts
through `CREWorkflowRegistry`, which stores the accepted ID in `workflowId(oracle)`.
Acceptance validates the current oracle owner and exact proposal. Normal rotation uses an atomic upstream upsert
with a fresh ID on the same DON. Existing paused records, DON changes and
already registered IDs are rejected upstream. The wrapper exposes no workflow
removal. Registry and oracle owners can rotate independently.

An otherwise valid authenticated report outside the movement limits leaves the last
accepted NAV usable until expiry, subject to valid flow reconciliation. The oracle stores the rejected
payload's hash and emits `OnReport(Report report, bool isRejected)` with the full
five-field report and `isRejected = true`; accepted reports use `false`. Both
event parameters are unindexed. Subsequent reports within the movement
limits can be accepted normally, including after a limits update. Normal acceptance
and workflow changes retain the latest rejected hash. An `ORACLE_GUARD_ROLE` holder can accept that exact
payload through `acceptReport(encodedReport)` if it is still fresh and strictly newer
than the active snapshot, bypassing movement limits only. Successful curator acceptance
clears the hash and emits `AcceptReport(bytes report)` with the full encoded
payload; another deviation rejection replaces the hash.
Stale or invalid NAV can halt the whole vault through its
NAV reads. Approved account management remains available. Monitor `OnReport` with
`isRejected = false` and snapshot progress; successful forwarder
delivery alone does not prove acceptance.
Other invalid reports revert, preserving the active valuation, rejected candidate
and liquidity reserves.

See [oracle accounting and controls](MERKLE-ORACLE.md) and
[deployment](MERKLE-DEPLOYMENT.md). The
[audit handoff](MERKLE-AUDIT-HANDOFF.md) identifies the 15-file contract scope,
reviewed-input manifest and explicitly excluded sibling NAV producer. A mandatory
follow-up integration review must validate its five-field ABI, whole-portfolio
valuation and real CRE delivery before production activation; this contract
change does not update or deploy it. The historical cutoff research is
superseded by flow accounting and snapshot-covered liquidity release. The release
gate does not change stale pricing of vault idle cash or new deposits; that
requires vault-layer settlement changes.

## CoW Swap orders

The account uses two ordinary leaves, without a validator deployment or capability:

```solidity
token.approve(vaultRelayer, amount);
account.sign(domainSeparator, encodedStruct, plan); // One step covering the whole buffer.
```

`encodedStruct` is `abi.encode(GPv2Order.TYPE_HASH, order)` (416 bytes).
The authorization leaf fixes the chain/settlement domain, Order type hash,
sell token, buy token, account receiver, sell kind, both ERC-20 balance modes,
zero explicit fee and full-fill flag. Only sell/buy amounts, expiry and app data
vary. ABI lengths, offsets and padding are fixed too. The account computes
`MessageHashUtils.toTypedDataHash(domain, keccak256(encodedStruct))` and stores
`signatures[digest] = true`; no caller-supplied digest can mismatch the fields.

Submit the order to CoW's order book using `eip1271`, signature `0x`, and the
account as owner. Settlement supplies its independently computed digest to
`isValidSignature`; the callback only reads its approval flag. CoW checks expiry
and fill status. `cowOrderSignature` in the frontend/backend catalog returns the
same domain, preimage, digest, empty callback signature and order UID.

An approval remains until explicitly revoked, including after a root or role
change. A filled or expired order remains approved but cannot settle again.
The account owner calls `account.revokeSignature(digest)` directly, even after the
root or roles are cleared. Revocation does not clear token allowances. Settlement
is asynchronous but only spends account funds; vault reserves remain in the adapter. Restricting
a swap to newly withdrawn funds or enforcing post-settlement health still needs
an atomic execution design.

## Liquid Lane consumer redemptions

The **MerkleAccount is the consumer/swapper**. Its generic setter hashes explicit
byte ranges; the Liquid Lane leaf supplies this preimage and fixed hash program:

```solidity
// Words 0-6 are the request; word 3 is reserved for the outputs hash.
// Words 7-10 are the scratch encoding of the single Output.
bytes memory buffer = abi.encode(
    LIQUID_LANE_REQUEST_TYPEHASH, tokenIn, amountIn,
    bytes32(0), deadline, nonce, protocol,
    LIQUID_LANE_OUTPUT_TYPEHASH, outputToken, minimumOutput, account
);
IMerkleAccount.Hash[] memory plan = new IMerkleAccount.Hash[](3);
plan[0] = IMerkleAccount.Hash({offset: 224, length: 128, destination: 224}); // Hash the Output struct.
plan[1] = IMerkleAccount.Hash({offset: 224, length: 32, destination: 96}); // Hash the singleton Output[].
plan[2] = IMerkleAccount.Hash({offset: 0, length: 224, destination: 0}); // Hash the request itself.
account.sign(reactorDomainSeparator, buffer, plan);
```

Each step hashes its range and overwrites the word at its destination, so a later step
reads the earlier result as an already-hashed field. The buffer never changes length, so
every offset refers to the original layout, and the final step's result is the struct hash.
The account then applies `toTypedDataHash(domainSeparator, structHash)`. There is no
protocol-specific branch, type hash, output count or recipient rule in the setter.
The leaf fixes the domain, both type hashes, input token, sole output token,
account recipient, protocol, complete plan, and all ABI lengths and offsets.
Amounts, deadline and nonce are variable. A second output or altered hash program
cannot match this leaf. The catalog rejects a recipient other than the account.
`liquidLaneRequestSignature` returns the request and matching approval fields,
including the two hash ranges.

Execute this self-call through `manage` with its proof and role, then submit
signature `0x00` to the Liquid Lane API/Reactor (the API requires nonempty hex). No validator or capability needs
to be installed. Reactor independently computes the digest, checks the request
nonce and deadline, validates settlement outputs and consumes the nonce.

Reactor allowance uses a separate token approval leaf. Approving or revoking a
digest changes no balances or allowances; asynchronous spending cannot reach reserves held by the adapter. Several requests may coexist. The account owner calls
`revokeSignature(digest)` directly to revoke approval. An approved account call to
`Reactor.invalidateNonce(nonce)` cancels the nonce permanently. Root/role changes do not revoke saved approvals,
and the callback does not check nonce or expiry; Reactor enforces both at settlement.

## Account recipe capability

Deploy one constructorless, stateless `RecipeCapability` and install its
`execute(bytes[] queries, bytes[] steps, uint256[] inputs)` selector.
It executes the shared `Recipes` interpreter in the account's context, with an
account self-call check. The accepted Merkle leaf commits the program and its
safety conditions; only intended variable inputs or amount words are masked.

Recipes combine static reads, arithmetic, bound call templates and assertions in
instruction order. Place reads before and after calls to check balance deltas with
checked subtraction. A failed call or assertion rolls back the whole sequence.
`Call` uses the account as sender, carries no native value, and discards raw return
data. The result contains numerical values indexed by step.

For borrowing, call the native lending method, read the resulting health factor,
and assert that a pinned literal minimum is at most the result. Pin every target,
selector, account, ABI layout, binding and threshold. Changing a floor requires a
new accepted leaf and role. The existing Aave, Morpho and Euler helpers remain
reusable; Aave's raw `getUserAccountData` can also be read at offset `160`.

`Manage` and `Approve` instructions remain exclusive to `RecipeExecutor`; they
cannot reenter account management from inside a capability. The capability uses
the account's existing reentrancy guard and has no configuration storage. See the
[capability recipe guide](RECIPE-CAPABILITY.md) for encoding and authorization.

## Automation and connector layout

Merkle components live under `src/contracts/merkle-adapter/`, with mirrored interfaces:

- `Recipes.sol`: the stateless interpreter shared by both recipe wrappers.
- `automations/`: `RecipeExecutor`, with `policies/` for the migratable `ThreeFPolicy`,
  `liquidity/` for withdrawal capacity queries and `health-factors/` for scalar health helpers.
- `oracle/`: CREOracle report authentication and NAV accounting, and immutable CREWorkflowRegistry.
- `connectors/OracleRegistry.sol`: approved RWA price oracles for Liquid Lane connectors.
- `connectors/`: `LiquidLaneConnector`.
- `capabilities/`: the stateless `RecipeCapability` with its account self-call check.

`LiquidLaneConnector` exposes both approved fixed swaps and
`swap(DiscountSwap, protocolSignature, recipient, amountIn)`. Both must be called
by the bound account through an authorized leaf. Its owner or the single configured
`signer` signs the discount, and the named protocol countersigns it. EIP-712 uses
`LiquidLaneConnector`, version `1`, the current chain and connector proxy address.
The connector defines its swap and discount structs and signing constants in
`ILiquidLaneConnector`. Off-chain readers track token additions and removals from events
and confirm membership through `oracles(token)`. No token array or enumeration getter is
maintained.

The owner configures `setSigner` and `setMinDiscount(token, discount)`, with discounts
scaled by `1e8` (`1_000_000` = 1%). The owner or
signer can invalidate a reusable discount with `invalidateNonce(token, nonce)`.
Signatures bind neither fill size nor recipient; the connector bounds only the price
it pays. The connector checks both
deadlines, signatures, nonce, minimum discount and the shared per-token spending
budget before transferring its RWA to the account and funding tokens to the recipient.
Liquid Lane leaves may leave `recipient`, `discount.protocol` and the fixed-swap
`amountOut` variable. No rule here requires pinning those fields. The owner's or
configured signer's discount signature still binds `discount.protocol`, whose
countersignature must verify. Discount-swap `amountOut` is computed from the oracle
quote and signed discount; fixed-swap `amountOut` cannot exceed the oracle quote.

`AaveV3Liquidity`, `AaveV4Liquidity` and `MorphoLiquidity` provide stateless source
capacity queries. Deploy only the ones a strategy uses; each covers one protocol and
exposes `liquidity`, with `liquidityWithBorrow` added on Aave V3. Recipes
read those capacities, obtain funds through approved account leaves and verify
actual balance deltas. See [liquidity sources](LIQUIDITY-SOURCES.md)
and the [native RWA integration matrix](RECIPE-REDEMPTIONS.md).

## Configurable strategy recipes

`RecipeExecutor` adds curator-defined reads, ordered calls and numeric checks to
the account's leaf permissions. The owner commits the recipe with `setRecipe`
and selects its provider caller. Only the hash and event block are stored;
the full recipe is emitted. `execute(queries, steps, inputs, runtime)` authenticates
that recipe before running it. The provider supplies bounded inputs, concrete
calls and current proofs.
Any failed postcondition rolls back the entire recipe. Deploy through
`ImmutableFactory(type(RecipeExecutor).creationCode)` with
`create(abi.encode(curator, account))`.

The [recipe guide](RECIPE-EXECUTOR.md) includes executable definitions for
LBTC supply → checked USDC borrowing → RWA purchase, and ordered liquidity →
signed Liquid Lane swap → optional issuer redemption, and ordered liquidity →
3F request mint. `LLExecuting` and `ThreeFExecuting` build complete account-call
recipes. JSON examples and encoding commands are in
the guide. Resulting debt/claim limits constrain repeated runs; grant the required
leaf roles only to the recipe executor, with the provider as its caller.

The [health-recovery recipe](HEALTH-RECOVERY-RECIPE.md) provides JSON
configurations for a health-factor trigger, ordered Morpho/Aave withdrawals and
RWA requests, followed by a separate claim-and-repay recipe. Amounts come from
live debt, liquidity and pending-entitlement reads; existing pending requests
prevent duplicate queuing.

## 3F push offers

Create `RecipeExecutor(curator, account)` through its `ImmutableFactory`, and create
`ThreeFPolicy` through its `MigratablesFactory`. Use the account as policy consumer for
guarded mint leaves, or the executor for direct policy calls. Configure the asset's period
budget and minimum request yield. Yield is `yieldAssets * 1e8 / principal`, not annualized APY.

`ThreeFExecuting` supports both routes. With `guardedMint: true`, `ThreeFGuardedMint`
builds the leaf that charges the policy beside native `mint(uint128,uint128)`. The leaf
checks factory membership and exact cash, principal and yield movements, so direct account
managers using it also enforce the policy. With `guardedMint: false`, the recipe performs
those checks and consumes the policy through `Call`, then executes a native mint leaf
through the account. This route needs no capability; its native mint leaf roles must be
restricted to the executor to enforce the recipe's policy.

For push offers, use the **account address** as `offerAddress` and `maker`, disable
callbacks, and wait for the native request's mint authorization. Both recipes read and
recheck this authorization, fund the account, mint, and clear the approval atomically.
A failed mint or check restores the consumed budget. Claims pay the account; native request
balances and events provide position tracking. No dedicated 3F capability is required.

The JSON builder defaults to guarded minting. Set `.policy.guardedMint` to `false` and
supply `.executor` to build the direct route and its policy-consumer configuration.
Use the output's mint target, calldata and mask to publish the leaf, then set `.leaves.mint`
to its hash when generating the final recipe.

The focused tests cover authorization, reserve accounting, connector migrations and capability replacement,
and compatibility with the off-chain Merkle tree fixture:

```sh
forge test --match-path 'test/adapters/{MerkleAdapter.t.sol,merkle-adapter/*.t.sol}'
```

`ThreeFExecutingMainnetTest` and `ThreeFDirectExecutingMainnetTest` validate factory membership, account-context native minting
and owner yield updates against deployed 3F contracts at Ethereum block `25_892_000`.
`RecipeMainnetTest` uses the real Aave V3 pool at the same block.
`CoWSwapLeavesMainnetTest` authorizes ERC-1271 orders and settles them through deployed GPv2 contracts at
block `25_982_370`. Set `ETH_RPC_URL` to an archive-capable endpoint to run these
tests. Liquid Lane consumer tests run the Reactor source pinned to RFQ commit
`22b04a850ca3680103e797bfae0e1a3b997fac83` against the repository's
`LiquidLaneAdapter`; their source fixture adapts compiler and import paths only.
