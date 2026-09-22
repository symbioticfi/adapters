# Symbiotic Adapters

This repository hosts adapters for Symbiotic vaults, connecting them to lending, yield, restaking, and tokenized-asset protocols. It includes adapter factories, protocol accounts and oracles, conversion and reward helpers, deployment scripts, and their test suites.

## Adapter families

- Adapters: Aave V3, Euler, ERC-4626, Morpho Vault V2, App, Restaking App, ThreeF, Liquid Lane, and Merkle.
- Liquid Lane accounts and oracles: async redemption, cooldown/cutoff, settlement, Chainlink, ERC-4626, and integrations for Lido, EtherFi, Midas, Makina, OpenEden, Pareto, Spiko, Superstate, and other supported protocols.
- Shared helpers: CoW Swap conversion, Merkl claiming, account registries, and token-to-redeem account implementations.

### Merkle adapter

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

An oracle created through the configured oracle factory reports portfolio assets
and a report nonce. The adapter keeps two batches and an immediately updated
`deallocatable` balance. `reservedAssets()` sums their pending allocations and
matured withdrawals. Allocations and withdrawal requests join `currentBatch`
before `oracle.cutoff()` and `nextBatch` from the cutoff onward. An accepted report
settles the current batch and promotes the next one; matching or cancelling
requests affects only the open batch. `push(amount)` transfers unreserved underlying to the paired account, and `pull(amount)` returns underlying from it. Both adapter functions require the account as caller, through approved account actions. The account grants the adapter unlimited underlying allowance during initialization. The oracle implementation is supplied separately.

#### Installed capability implementations

`CapabilitiesRegistry(protocolOwner)` stores approved selectors for each account
and capability. The protocol owner replaces the complete list with:

```solidity
registry.whitelistCapability(account, implementation, selectors);
```

An empty list unwhitelists the capability. No separate proposer, acceptance
contract, or immutable registry manifest is required. The account owner chooses
when to install an approved implementation with `addCapability(implementation)`.
See [capability governance](docs/capability-governance.md).

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

#### Immutable deployment factory

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
address guardedFactory = address(new ImmutableFactory(type(GuardedCallsCapability).creationCode));
address executorFactory = address(new ImmutableFactory(type(RecipeExecutor).creationCode));

address guardedCapability = IImmutableFactory(guardedFactory).create("");
address executor = IImmutableFactory(executorFactory).create(abi.encode(owner, account));
```

The deployed constructor sees the factory as `msg.sender`, so ownership must be
passed explicitly, as it is for Executor. `isEntity`, `totalEntities`, `entity`,
and `AddEntity` provide deployment discovery. Failed deployments or empty runtime
code revert with `DeploymentFailed` and leave the registry unchanged.

Factory registration records deployment provenance. GuardedCallsCapability goes
through registry whitelisting and account installation. Its calls and health
thresholds are fixed in accepted Merkle leaves; the capability has no storage.

#### Capabilities and Liquid Lane connector

`GuardedCallsCapability` is a directly deployed implementation installed through
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

#### Liquid Lane token and oracle configuration

The registry owner calls `OracleRegistry.setOracle(adapter, tokenToRedeem, oracle)`.
Here `adapter` is the **LiquidLaneConnector proxy address**: the connector looks up
`OracleRegistry.oracles(address(this), tokenToRedeem)`. Each approval is scoped to
that connector and token. Oracles are deployed separately and must price the RWA in
the connector's configured `inputAsset`.

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

Initialization uses `abi.encode(account, inputAsset)`. Create the connector,
register its oracles, then add tokens through Merkle leaves. Budgets can be
configured before the token oracle is added or while a token is removed.

#### Curator asset budgets

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
charges `swap.amountOut` in `inputAsset` base units. For either policy, a USDC
budget of `1_000_000e6` with duration `1 days` permits one million USDC per period.

Periods start at configuration and retain fixed boundaries. Spending at the
exact end of a period uses the next period's budget; unused capacity does not
accumulate. Adjacent periods each have their full budget. Repeating the same
configuration, changing the maximum, or disabling and reenabling an asset
does not erase active usage. Changing the duration starts a period at the
current timestamp and carries forward any unexpired usage.

Duration must be nonzero. A zero maximum disables funding, and policies
and connectors without a configured budget cannot spend. Both expose configuration
and usage through `assetLimits(asset)`; `remainingAssets(asset)` includes any elapsed
period reset.
Failed transactions restore usage, including failures after
Executor liquidity preparation. Finalizing a 3F position does not refund the
period's funding budget.

#### Managed-call reserves

`push(amount)` transfers underlying only to the bound account and reverts if
the adapter's remaining balance does not cover `reservedAssets()`. The account
cannot transfer or approve tokens from the adapter. A delayed CoW settlement can
spend account balances only. Returns use adapter `pull(amount)` leaves; no
order tracking, allowance reservation or settlement hook is required.

The NAV workflow values both addresses at one block: all account positions and
balances plus the adapter's underlying balance. The signed value includes the
closed batch's allocations entering NAV and withdrawals about to mature. It
excludes open-batch pending allocations and already matured reserves. CREOracle caps
the newly maturing withdrawals to the reported surviving NAV and subtracts the
actual release before storing NAV. Internal transfers do not change NAV. All
resulting reserves must be present on the adapter before acceptance.

#### NAV CREOracle

`merkle-adapter/oracle/CREOracle.sol` exposes raw `nonce()` / `totalAssets()` accounting and
`validate()` for freshness and freeze checks. Its constructor takes
`(factory, workflowRegistry, forwarder, maxReportAge, maxOracleAge, reportInterval, reportBuffer)`; the adapter
passes `abi.encode(address(this), oracleData)` to the oracle factory. CREOracle decodes
`oracleData` as `ICREOracle.InitParams`, configuring its role holders and movement limits.
The account receives `abi.encode(address(this), merkleAccountData)` and decodes its
own `IMerkleAccount.InitParams`. Each proxy stores its own workflow and guard policy.
Symbiotic owns the CRE organization and calls `proposeWorkflow(oracle, id, params)`
through the immutable `CREWorkflowRegistry` owner. The curator calls
`acceptWorkflow(oracle, id, params)` through `CREOracle.owner()` on that registry.
Acceptance registers the reviewed artifacts in Chainlink's on-chain registry and
updates the receiver atomically. The registry links to the CRE organization once
and stores one hash of the ID and registration data per proposal. Both owner addresses can rotate at
any time; proposal and acceptance authority follow their respective current owners.
Rotations preserve pending proposals, active workflows and the registry's CRE
organization link. Updating the workflow needs no migration and
affects no other adapter. CREOracle implementation migrations remain separately
controlled by the oracle owner and factory-approved implementations.

`REPORT_INTERVAL` and `REPORT_BUFFER` are immutable per implementation, in seconds;
the interval must be nonzero and the buffer smaller than the interval. After each
accepted report, CREOracle sets `cutoff = now + interval - (now + buffer) % interval`,
the next future cutoff on the interval grid offset by the buffer. `cutoff()` starts
at zero for the initial empty bootstrap report. Later report snapshots must be at
or after the stored cutoff. A delayed report settles the same closed batch and
sets a new future cutoff; it does not consume the open batch or replay missed
intervals. The workflow must obtain a finalized eligible snapshot, and the account
must return enough liquidity to cover the released withdrawals before acceptance.

[Chainlink's KeystoneForwarder](https://github.com/smartcontractkit/chainlink-evm/blob/b6427ea1f4847d640abdf24dbd6c6f01d7799d59/contracts/cre/src/v1/KeystoneForwarder.sol)
verifies DON signatures and invokes `onReport(metadata, report)`. The CREOracle checks
the forwarder and workflow identity and supports the CRE `IReceiver` ERC-165 ID.
It accepts the production 64-byte metadata layout;
see [Chainlink's receiver documentation](https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts).

The payload is `abi.encode(ICREOracle.Report)`:

| Field               | Source / meaning                                                    |
| ------------------- | ------------------------------------------------------------------- |
| `chainId`           | Destination EVM chain ID                                            |
| `oracle`            | Destination oracle proxy                                            |
| `adapter`           | Valued MerkleAdapter                                                |
| `nonce`             | NAV report's `oracleUpdate.nextNonce`; must equal current nonce + 1 |
| `totalAssets`       | `oracleUpdate.preReleaseAssets`, in vault-asset base units          |
| `snapshotBlock`     | Report's finalized `block.number`                                   |
| `snapshotTimestamp` | Report's finalized `block.timestamp`                                |

Wrong destinations, malformed payloads, duplicate/skipped epochs, nonadvancing
snapshots, snapshots before the batch cutoff, future snapshots, and snapshots older
than `maxReportAge` revert.
The approved workflow is responsible for valuation and snapshot correctness.
Before storing a report, CREOracle validates NAV and the adapter's reserves. Independent
growth/loss limits configured at initialization reconcile queued allocations and withdrawals;
the guard also checks freshness and idle reserves. Rejection latches a freeze and
preserves the accepted NAV and epoch. NAV-dependent vault operations then revert;
approved management actions remain available for recovery. Separate enumerable
roles stored on CREOracle authorize recovery and movement limits. Workflow
acceptance belongs to its owner through `CREWorkflowRegistry`.
`MAX_ORACLE_AGE` is fixed in the implementation constructor. CREOracle grants its
configured initial role holders independently of ownership and account roles. A rejected report delivery
returns successfully so its freeze persists; monitor `OnReport` versus `RejectReport`.
CREOracle caches the latest authenticated rejected report's `rejectedReportHash`.
A guard operator can call `unfreezeOracle(abi.encode(report))` to accept that exact
report immediately, bypassing only movement limits. Freshness, nonce, cutoff and
reserve checks still apply; a failed review changes nothing. No second CRE
delivery is needed. `unfreezeOracle("")` instead clears the freeze and cached hash
without changing the accepted NAV or its age.
See [oracle protection and bootstrap](docs/MERKLE-ORACLE.md) for roles, recovery and
the deployment sequence that binds a workflow after adapter creation.

Stored `totalAssets()` and `OnReport.totalAssets` exclude pending allocations and
all matured reserves, which the adapter adds back. The signed report value is
before the new withdrawal release and can therefore differ from stored NAV.

Accounting remains in [merkle-adapter-nav](https://github.com/symbioticfi/merkle-adapter-nav).
Its submission client is currently an in-memory mock. This PR supplies the on-chain
receiver and wire format; live CRE report generation/submission still needs wiring
in that repository. Tests exercise signed reports through the pinned forwarder
source, including its actual signature verification, ERC-165 probe, and callback.

#### CoW Swap orders

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

#### Liquid Lane consumer redemptions

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

#### Guarded protocol calls

Deploy one constructorless, stateless `GuardedCallsCapability` and install its
`execute` selector. Add protocol calls and conditions through proposed, accepted Merkle leaves.

`execute(Call[] calls, Check[] checks)` performs ordinary calls as the account,
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

#### Automation and connector layout

Merkle components live under `src/contracts/merkle-adapter/`, with mirrored interfaces:

- `automations/`: `RecipeExecutor`, with `policies/` for the migratable `ThreeFPolicy`,
  `liquidity/` for withdrawal capacity queries and `health-factors/` for scalar health helpers.
- `oracle/`: NAV CREOracle and immutable CREWorkflowRegistry.
- `connectors/OracleRegistry.sol`: approved RWA price oracles for Liquid Lane connectors.
- `connectors/`: `LiquidLaneConnector`.
- `capabilities/`: the stateless `GuardedCallsCapability` with its account self-call check.

`LiquidLaneConnector` exposes both approved fixed swaps and
`swap(DiscountSwap, protocolSignature, recipient, amountIn)`. Both must be called
by the bound account through an authorized leaf. Its owner or the single configured
`signer` signs the discount, and the named protocol countersigns it. EIP-712 uses
`LiquidLaneConnector`, version `1`, the current chain and connector proxy address.
The connector defines its swap and discount structs and signing constants in
`ILiquidLaneConnector`. Off-chain readers track token additions and removals from events
and confirm membership through `oracles(token)`. No token array or enumeration getter is
maintained.

The owner configures `setSigner` and `setMinDiscount(token, ppm)`. The owner or
signer can invalidate a reusable discount with `invalidateNonce(token, nonce)`.
Signatures do not bind fill size or recipient; the accepted swap leaf and recipe
must pin the intended recipient and bound amounts. The connector checks both
deadlines, signatures, nonce, minimum discount and the shared per-token spending
budget before transferring its RWA to the account and funding tokens to the recipient.

`AaveV3Liquidity`, `AaveV4Liquidity` and `MorphoLiquidity` provide stateless source
capacity queries. Deploy only the ones a strategy uses; each covers one protocol and
exposes `liquidity`, with `liquidityWithBorrow` added on Aave V3. Recipes
read those capacities, obtain funds through approved account leaves and verify
actual balance deltas. See [liquidity sources](docs/LIQUIDITY-SOURCES.md)
and the [native RWA integration matrix](docs/RECIPE-REDEMPTIONS.md).

#### Configurable strategy recipes

`RecipeExecutor` adds curator-defined reads, ordered calls and numeric checks to
the account's leaf permissions. The owner commits the recipe with `setRecipe`
and selects its provider caller. Only the hash and event block are stored;
the full recipe is emitted. `execute(queries, steps, inputs, runtime)` authenticates
that recipe before running it. The provider supplies bounded inputs, concrete
calls and current proofs.
Any failed postcondition rolls back the entire recipe. Deploy through
`ImmutableFactory(type(RecipeExecutor).creationCode)` with
`create(abi.encode(curator, account))`.

The [recipe guide](docs/RECIPE-EXECUTOR.md) includes executable definitions for
LBTC supply → checked USDC borrowing → RWA purchase, and ordered liquidity →
signed Liquid Lane swap → optional issuer redemption, and ordered liquidity →
3F request mint. `LLExecuting` and `ThreeFExecuting` build complete account-call
recipes. JSON examples and encoding commands are in
the guide. Resulting debt/claim limits constrain repeated runs; grant the required
leaf roles only to the recipe executor, with the provider as its caller.

The [health-recovery recipe](docs/HEALTH-RECOVERY-RECIPE.md) provides JSON
configurations for a health-factor trigger, ordered Morpho/Aave withdrawals and
RWA requests, followed by a separate claim-and-repay recipe. Amounts come from
live debt, liquidity and pending-entitlement reads; existing pending requests
prevent duplicate queuing.

#### 3F push offers

Create `RecipeExecutor(curator, account)` through its `ImmutableFactory`, and create
`ThreeFPolicy` through its `MigratablesFactory`. Use the account as policy consumer for
guarded mint leaves, or the executor for direct policy calls. Configure the asset's period
budget and minimum request yield. Yield is `yieldAssets * 1e6 / principal`, not annualized APY.

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
`GuardedCallsMainnetTest` uses the real Aave V3 pool at the same block.
`CoWSwapLeavesMainnetTest` authorizes ERC-1271 orders and settles them through deployed GPv2 contracts at
block `25_982_370`. Set `ETH_RPC_URL` to an archive-capable endpoint to run these
tests. Liquid Lane consumer tests run the Reactor source pinned to RFQ commit
`22b04a850ca3680103e797bfae0e1a3b997fac83` against the repository's
`LiquidLaneAdapter`; their source fixture adapts compiler and import paths only.

## Layout

```text
src/contracts/            Adapter implementations, factories, accounts, oracles
src/contracts/merkle-adapter/  Automation, connectors, capabilities and oracle infrastructure
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

For Merkle stack deployment, activation and recovery, see
[Deploying and operating the Merkle stack](docs/MERKLE-DEPLOYMENT.md).

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
