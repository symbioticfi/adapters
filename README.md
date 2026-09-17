# Symbiotic Adapters

This repository hosts adapters for Symbiotic vaults, connecting them to lending, yield, restaking, and tokenized-asset protocols. It includes adapter factories, protocol accounts and oracles, conversion and reward helpers, deployment scripts, and their test suites.

## Adapter families

- Adapters: Aave V3, Euler, ERC-4626, Morpho Vault V2, App, Restaking App, ThreeF, Liquid Lane, and Merkle.
- Liquid Lane accounts and oracles: async redemption, cooldown/cutoff, settlement, Chainlink, ERC-4626, and integrations for Lido, EtherFi, Midas, Makina, OpenEden, Pareto, Spiko, Superstate, and other supported protocols.
- Shared helpers: CoW Swap conversion, Merkl claiming, account registries, and token-to-redeem account implementations.

### Merkle adapter

`MerkleAdapter` executes batches of ordinary calls authorized by Merkle proofs.
Each leaf binds the target, native-currency value constraint, calldata mask, and
masked calldata. The leaf hash is also the access-control role: the administrator
uses `grantRole(leafHash, executor)` and `revokeRole(leafHash, executor)` to control
who can execute that permission. Every action requires its leaf role, including
calls from the administrator. The adapter checks all proofs and leaf roles before
executing any call. The protocol publishes candidate roots through `RootRegistry`,
and the adapter owner accepts the active root.

The leaf encoding is
`keccak256(bytes.concat(keccak256(abi.encode(target, valueConstraint, keccak256(dataMask), keccak256(maskedData)))))`.
Callers supply `Action(target, flagsAndValue, data, dataMask, proof)`; its role is
derived from those constraints. Wildcard values and unmasked calldata bits reuse
the same leaf role. Earlier trees containing a separate role field must be rebuilt
and their leaf hashes granted to executors before accepting the replacement root.

Regenerate the committed fixture with `python3 script/utils/update_merkle_fixture.py`;
add `--check` to verify that its hashes and proofs match the action constraints.

An oracle created through the configured oracle factory reports portfolio assets
and an accounting nonce. The adapter tracks pending allocations and deallocation
reserves across those oracle epochs, and managed calls must preserve reserved idle
assets. The oracle implementation is supplied separately.

#### Installed capability implementations

`CapabilitiesRegistryProposer` is owned by Symbiotic. Each curator deploys a
`CapabilitiesRegistry(curatorOwner, proposer)` to accept implementation code for
their adapters. The names follow Chainlink CRE's capability catalog; the proposal
and curator acceptance flow is specific to this repository. See the
[CRE research and governance design](docs/capability-governance.md).

Deploy the Merkle adapter implementation with `(vaultFactory, adapterFactory,
oracleFactory, rootRegistry, capabilitiesRegistry)`. The registry remains fixed
for that implementation and is exposed as `CAPABILITIES_REGISTRY()`. Multiple
adapters can share the same curator registry and adapter implementation. A
separate registry requires a separately deployed, factory-whitelisted adapter
implementation. Adapter creation still uses the existing adapter factory.

The protocol owner first commits the implementation's deployed runtime code hash
and immutable selectors, then proposes that exact code to a specific registry
and adapter:

```solidity
proposer.initCapability(implementation, selectors);
proposer.setProposedStatus(address(curatorRegistry), adapter, implementation, true);
```

The curator owner accepts the proposal into their registry:

```solidity
curatorRegistry.acceptCapability(adapter, implementation);
```

Acceptance copies the manifest locally and records explicit curator consent.
The two-step `initCapability(implementation, selectors)` followed by
`setWhitelistedStatus(adapter, implementation, true)` is also available. The
selectors must exactly match the protocol's manifest, including their order.
Neither publishing a proposal nor copying selectors authorizes installation
without curator consent for that adapter.

The protocol's selector registration requires deployed code, a nonempty list,
and unique nonzero selectors. Code hashes and selector lists are immutable;
updated code or selectors require a new implementation address and new consent.
Capabilities are direct implementations written for delegatecall execution;
they do not require a capability factory or proxy. Runtime code hashes identify
the deployed bytecode, not mutable proxy targets or external dependencies;
upgradeable capability proxies are outside this model.

The adapter owner calls `addCapability(implementation)` to install every registered
selector. Addition reverts atomically if any selector belongs to another installed
capability, a native adapter function, or the adapter proxy. Discover installed
implementations through `getCapabilities()` and `isCapability(implementation)`,
and resolve a callback through `capabilityForSelector(selector)`.

External callers address the adapter. Its fallback delegates the calldata to the
installed implementation, preserving the caller, value, adapter address and
storage. Return data and revert data propagate unchanged. Dispatch only reads
state, so view callbacks such as ERC-1271 work under `STATICCALL`. Empty calldata
continues to use the adapter's payable receive function; incomplete or unknown
selectors revert.

Installation requires both current protocol proposal status and curator consent,
with unchanged runtime bytecode. Either Symbiotic withdrawing a proposal through
`setProposedStatus(..., false)` or the curator calling
`setWhitelistedStatus(..., false)` prevents future additions. Already-installed
functions remain active until the adapter owner calls
`removeCapability(implementation)`. Dispatch does not consult either registry.
Removal uses the locally copied immutable selectors and works even if the
proposer is unavailable.

Reproposal of the same immutable implementation preserves any existing curator
consent; it cannot restore consent the curator revoked. A new implementation
always needs its own proposal and acceptance. An owner can atomically replace
an implementation using the existing `multicall` with `removeCapability(old)`
followed by `addCapability(new)` after accepting the new proposal.

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
address borrowFactory = address(new ImmutableFactory(type(BorrowCapability).creationCode));
address executorFactory = address(new ImmutableFactory(type(Executor).creationCode));

IBorrowCapability.ConstructorParams memory borrowParams = IBorrowCapability.ConstructorParams({
    borrowTarget: pool,
    borrowSelector: borrowSelector,
    borrowAsset: asset,
    healthFactorTarget: healthReader,
    healthFactorData: healthQuery,
    healthFactorOffset: 0
});
address borrowCapability = IImmutableFactory(borrowFactory).create(abi.encode(borrowParams));
address executor = IImmutableFactory(executorFactory).create(abi.encode(owner, adapter));
```

The deployed constructor sees the factory as `msg.sender`, so ownership must be
passed explicitly, as it is for Executor. `isEntity`, `totalEntities`, `entity`,
and `AddEntity` provide deployment discovery. Constructor reverts are bubbled;
failed deployments or empty runtime code leave the registry unchanged.

Factory registration records deployment provenance. BorrowCapability still goes
through capability proposal, registry acceptance, and adapter installation, then
`setMinHealthFactor` sets the adapter's borrowing floor through a permitted self-call.

#### Capabilities and Liquid Lane connector

`BorrowCapability`, `ThreeFCapability`, `CoWSwapCapability`, and
`LiquidLaneRedeemCapability` are directly deployed implementations installed through
the capability registry. Merkle leaves for their operations target the adapter
itself. The adapter's fallback delegates to the implementation, so protocol calls,
funds, positions, and capability storage belong to the adapter.

The shared `Capability.onlyMyself` modifier protects every state-changing entrypoint.
View getters and ERC-1271 validation remain public. Each capability uses its own
ERC-7201 storage namespace. Removal and replacement preserve that storage and do
not revoke protocol orders or token approvals. Set and clear approvals through
separate token leaves; capabilities do not manage allowances.

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

The curator configures ThreeFCapability and LiquidLaneConnector with
`setMaxAssetsPerDuration(asset, maxAssets, duration)` through a dedicated Merkle
leaf. Grant that leaf's role only to the curator or its configuration executor;
ordinary mint/swap permissions do not grant configuration access.

Budgets are independent for each asset key. ThreeF uses the **collateral
underlying** and charges the principal funded in vault-asset base units.
Liquid Lane uses the **RWA token** and charges `swap.amountOut` in `inputAsset`
base units, regardless of the RWA token's decimals. For example, a USDC budget
of `1_000_000e6` with duration `1 days` caps cumulative funding for that asset
at one million USDC during each period.

Periods start at configuration and retain fixed boundaries. Spending at the
exact end of a period uses the next period's budget; unused capacity does not
accumulate. Adjacent periods each have their full budget. Repeating the same
configuration, changing the maximum, or disabling and reenabling an asset
does not erase active usage. Changing the duration starts a period at the
current timestamp and carries forward any unexpired usage.

Duration must be nonzero. A zero maximum disables the asset, and capabilities
and connectors without a configured budget cannot spend. `assetLimits(asset)` exposes
configuration and recorded usage; `remainingAssets(asset)` includes any elapsed
period reset. Failed transactions restore usage, including failures after
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

Deploy `CoWSwapCapability(settlement)` directly and install its selectors through
the registry. A self-targeted Merkle leaf calls
`convert(tokenIn, amountIn, tokenOut, params)`, where `params` contains `buyAmount`,
`validTo`, and `appData`. Approve the settlement's vault relayer through a separate
token leaf when settlement should be enabled.

The adapter owns the pre-signed order and receives its bought tokens. Sell tokens
stay on the adapter until settlement. Orders allow partial fills, charge no explicit
fee, and expire within 30 minutes. One order is tracked per sell token. Replacement
revokes the old pre-signature before authorizing the new order.
`invalidateConvert(tokenIn)` cancels at the order's original settlement, including
after an implementation replacement. Cancellation does not touch token balances or
allowances and works while token operations are paused. There is no recovery transfer;
unspent funds already belong to the adapter.

CoW settlement is asynchronous and runs outside `manage`. Its later spending is not
charged by the per-leaf before/after balance check or covered by that call's final
idle-reserve check. Curators must account for outstanding orders when allocating
idle funds and manage relayer allowances explicitly. Removing the capability does
not revoke outstanding pre-signatures.

#### Liquid Lane consumer redemptions

Deploy `LiquidLaneRedeemCapability(reactor, protocol)` directly. Symbiotic proposes
the exact implementation and its selectors; the curator accepts it and calls
`addCapability`. There is no capability factory. Register `REACTOR`, `PROTOCOL`,
`activeRequest`, `signatures`, `hashRequest`, `signRequest`, `revokeRequest`,
`finalizeRequest`, and `isValidSignature`.

The **MerkleAdapter is the consumer/swapper**. Call `signRequest(request, signature)`
through a Merkle leaf targeting the adapter itself. The capability stores the exact
signature bytes for the Reactor's EIP-712 request in namespaced adapter storage.
Every output recipient must be the adapter. Requests bind the input, minimum
outputs, nonce, expiry, and protocol signer; CoW/curator pricing remains a curator
responsibility. Grant signature-management leaf roles separately from execution roles.

Tokens stay on the adapter. The curator sets or clears the Reactor's ERC-20
allowance through separate token `approve` leaves. Signing, revoking, and finalizing
never transfer tokens or change allowances. No funding is required to save a
signature; settlement requires sufficient adapter balance and allowance.

One request per input token and nonce can remain outstanding. `revokeRequest`
removes its signature and invalidates its original Reactor nonce. `finalizeRequest`
clears metadata after a fill, revocation, or expiry. The curator may leave unfinished
orders stored. Removal also leaves storage and allowances in place; reinstalling a
compatible implementation restores unexpired signatures. A different Reactor or
protocol cannot validate old authorizations. Replacement code can revoke old
requests through their original Reactor. Revocation and finalization work while
token transfers or approvals are paused.

#### Health-checked borrowing

Deploy `BorrowCapability(IBorrowCapability.ConstructorParams(...))`, or use
`ImmutableFactory.create(abi.encode(params))`, and install its selectors. The
constructor fixes the borrow target and selector, borrowed token, and complete
health-query target/calldata. Scalar configuration is immutable; dynamic query
calldata is stored once on the implementation and read from there during
adapter delegatecalls. Only the minimum health factor lives in adapter storage.

`healthFactorOffset` selects a uint256 word: use `0` for a scalar or `160` for
Aave's `getUserAccountData(account)`. The minimum uses the query's units; Aave
and the included health helpers use `1e18` precision.

The curator sets the initial floor and changes it through a self-targeted Merkle
leaf for `setMinHealthFactor(minimum)`. The value must be nonzero; borrowing is
disabled until it is set. Configuration getters and the health query work before
setting the floor. Constructors do not query or validate external protocols;
invalid queries revert when read or used after borrowing.

`borrow(protocolCalldata)` calls the protocol from the adapter, measures its token
balance increase, and checks the final health factor. A value below the floor
reverts the transaction. The adapter holds both the position and borrowed tokens;
there is no intermediate funding address.

Removing or replacing the capability retains the adapter's minimum. Replacing it
uses the new implementation's constructor configuration and health query. Approve
each implementation only for adapters whose permitted borrowing matches its fixed
account/market query, and set a suitable minimum for any replacement query.

Bind the asset, debt owner, and recipient in the borrow leaf to the fixed health
query. For Aave, supply collateral for the adapter and borrow on its behalf; a
separate capability debt delegation is unnecessary. Include collateral and debt
in the portfolio oracle. Protocol-specific health-factor readers are still needed
where the protocol does not expose a comparable scalar.

#### Liquidity Executor

Deploy through an Executor `ImmutableFactory` using `create(abi.encode(owner, adapter))`.
The adapter is immutable. The owner calls
`setCaller(caller)` to select the sole account allowed to execute; zero disables
execution. Ownership alone grants no execution permission, and the caller does
not need adapter leaf roles.

The owner calls `setActions(actions)` with an ordered `IExecutor.Action[]`:

```solidity
struct Action {
    address liquidityTarget;
    bytes liquidityCalldata;
    bytes32 leaf;
}
```

Entries with a nonzero `liquidityTarget` are withdrawal/borrow sources, ordered by
funding priority. Their static queries return available funding-token base units;
encode the adapter explicitly when a query takes an account argument. These
entries must come first. Entries with a zero target form the final managed batch,
including approvals and the Liquid Lane swap or 3F mint. Every entry commits its
canonical masked Merkle leaf. `getActions()` returns this configuration. Empty
configuration disables execution. Neither configuration nor caller can change
during an execution callback.

The caller uses `execute(IMerkleAdapter.Action[] actions)`, supplying normal
Merkle calldata, masks, and proofs for **every configured entry in the same
order**. Executor checks every leaf before dispatch. The caller may vary only
wildcarded calldata and supply current proofs; it cannot insert, omit, reorder,
or replace leaves, including calls in the final batch.

Executor uses spendable idle assets first, then queries each needed source just
before executing it. The caller must encode amounts that produce exactly
`min(remaining shortfall, reported liquidity)`. For example, a shortfall of 100
and source capacities of 70 and 100 require withdrawals of 70, then 30. Withdrawing
30 from the first source and 70 from the second reverts. Executor does not rewrite
calldata. Zero-capacity and unneeded funding calls are skipped, but their supplied
leaves must still match the configured positions.

The last action must be `LiquidLaneConnector.swap(Swap)` or
`ThreeFCapability.mintRequest(address,uint128,uint128,uint256)`. Liquid Lane needs
`swap.amountOut`; 3F needs the Request's **current principal authorization for the
adapter**, bounded by the operation's arguments. The 3F leaf targets the bound
adapter; the Liquid Lane leaf targets its connector. Earlier final actions can
approve the 3F request or connector. The final batch must spend exactly the
required amount, which is checked again after liquidity preparation.

Grant the executed leaf roles to Executor. Configuration grants no adapter
permissions: `MerkleAdapter.manage` checks the current root, proofs, and Executor's
role whenever a leaf executes. A mismatch, insufficient funding, invalid executed
proof, or missing role rolls back the entire transaction.

Pending allocations and deallocation reserves remain protected. Each funding
step uses its own `MerkleAdapter.manage` call, so every intermediate balance must
cover the reserve. If idle assets fall below that reserve, the first nonzero
step must restore it. Executor holds no tokens.

#### 3F push offers

Deploy `ThreeFCapability(requestWhitelist, facility)` directly and install its
selectors. Configure `setMinYieldPerRequest(asset, minimum)` and
`setMaxAssetsPerDuration(asset, maxAssets, duration)` through self-targeted Merkle
leaves for each collateral underlying. The capability resolves the underlying from
the trusted facility's intent and position manager. Yield is measured in parts per
million; the cumulative budget charges principal in the vault asset's base units.
The caller's `maxPrincipalAssets` is an execution slippage bound.

Follow the [3F push-offer setup](https://docs.3f.xyz/bridge-facilitator/console/push-offers/)
with the **adapter address** as `offerAddress` and `maker`. Submit an unsigned offer
using the facilitator API key, with `useCallback: false` and no `signature` or
`chainId`, then wait for `AWAITING_MINT`. API keys are off-chain credentials.

Prepare liquidity, approve the request with a separate token leaf, and call
`mintRequest(request, maxPrincipalAssets, minYieldAssets, deadline)` on the adapter
through `manage`. The capability checks the adapter's live authorization and
collateral limits, calls the request directly, and verifies the exact principal
balance decrease. The request receives payment from the adapter and issues PT/YT
to it. The capability does not set or clear allowances.

`finalizeRequest(request)` also requires a self-targeted Merkle leaf. Redemption
pays directly to the adapter. `threeFPositionAssets()` values tracked requests and
excludes idle tokens; the adapter retains its own native `totalAssets()` accounting.
Compatible implementation replacement preserves tracked requests, budgets, and
usage in the adapter's namespace. Old standalone action proxies have different
custody and storage: installing capability code does not migrate those positions.
Wind down existing proxies separately before switching to adapter-owned positions.

The focused tests cover authorization, reserve accounting, connector migrations and capability replacement,
and compatibility with the off-chain Merkle tree fixture:

```sh
forge test --match-path 'test/adapters/{MerkleAdapter.t.sol,merkle-adapter/*.t.sol}'
```

`ThreeFCapabilityMainnetTest` exercises Merkle batches and Executor funding against
deployed 3F contracts at Ethereum block `25_892_000`, including reserve rollback.
`BorrowCapabilityMainnetTest` uses the real Aave V3 pool at the same block.
`CoWSwapCapabilityMainnetTest` settles orders through deployed GPv2 contracts at
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

Contracts under `src/contracts/` pin `pragma solidity 0.8.36;`. The Foundry build targets the Osaka EVM. Root remappings
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
