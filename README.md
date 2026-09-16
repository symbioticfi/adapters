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

#### Standalone integrations called by Merkle actions

Ordinary adapter-call integrations use the `Action` suffix: `BorrowAction`,
`ThreeFAction`, `CoWSwapAction`, and `LiquidLaneAction`. Callback integrations
retain `Capability`, such as `LiquidLaneRedeemCapability` with its ERC-1271
`isValidSignature` entrypoint.

The existing factory-created integrations below use ordinary calls and separate
storage; they are not delegatecall implementations for the selector registry.
`LiquidLaneAction` exchanges configured RWA inventory using saved oracle approvals
from `OracleRegistry`, while `ThreeFAction` funds whitelisted 3F requests and returns recovered principal and
yield. Both support state-preserving implementation migrations.

#### Liquid Lane token and oracle configuration

The registry owner calls `OracleRegistry.setOracle(adapter, tokenToRedeem, oracle)`.
Here `adapter` is the **LiquidLaneAction proxy address**: the action looks up
`OracleRegistry.oracles(address(this), tokenToRedeem)`. Each approval is scoped to
that action and token. Oracles are deployed separately and must price the RWA in
the action's configured `inputAsset`.

The curator calls `addTokenToRedeem(tokenToRedeem)` through an authorized Merkle
leaf. The action requires a nonzero registry entry and saves it in its own
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
now permits an empty list: create the action, register its oracles, then add its
tokens and configure budgets through Merkle leaves. A nonempty initial list
requires approvals for the action's predicted address before creation. Existing
action storage and saved oracles survive migration; the new implementation must
point to a registry using the new direct-oracle interface.

#### Curator asset budgets

The curator configures both actions with
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

Duration must be nonzero. A zero maximum disables the asset, and new or migrated
actions without a configured budget cannot spend. `assetLimits(asset)` exposes
configuration and recorded usage; `remainingAssets(asset)` includes any elapsed
period reset. Failed transactions restore usage, including failures after
Executor liquidity preparation. Finalizing a 3F position does not refund the
period's funding budget.

#### CoW Swap orders

`CoWSwapAction` uses the same GPv2 order encoding and pre-signing flow as
`CoWSwapConverter`. Deploy the implementation with `(factory, settlement)` and
initialize its proxy with `abi.encode(adapter)`. Through Merkle leaves, approve
the action and call `convert(tokenIn, amountIn, tokenOut, params)`, where
`params` contains `buyAmount`, `validTo`, and `appData`.

Orders sell an exact funded amount, allow partial fills, charge no explicit fee,
expire within 30 minutes, and send bought tokens directly to the adapter. The
action grants the CoW relayer only the funded allowance. It tracks one order
per sell token; replacement cancels the old order and returns unspent tokens
before funding the new order. `invalidateConvert(tokenIn)` revokes authorization;
`recover(token)` clears allowance and returns the token balance to the adapter.
Revocation does not call the token and remains available while token operations
are paused; the residual allowance is cleared during recovery or replacement.
Unfilled
sell tokens held by the action must remain included in portfolio valuation.

#### Liquid Lane consumer redemptions

`LiquidLaneRedeemCapability` lets the adapter sell tokens as a Liquid Lane
consumer. It signs the Reactor's EIP-712 `Request` format. Deploy with
`(factory, reactor)` and initialize with `abi.encode(adapter, protocol)`, binding
the protocol signer that authorizes the fill.

Approve the capability's input funding and call
`signRequest(request, signature)` through Merkle leaves. This stores the exact
signature bytes under the domain-separated request digest and funds the
capability, which becomes the Reactor order's `swapper`. Use those same bytes as
the order's consumer signature; ERC-1271 validation checks the saved
authorization. Every requested output recipient is fixed to the adapter.
Requests bind the input amount, minimum outputs, nonce, expiry, and protocol.

There is one active request per input token. `revokeRequest(digest)` removes its
signature and invalidates its Reactor nonce. `finalizeRequest(digest)` clears
allowance and returns unused input tokens after filling, cancellation, or expiry.
Include outstanding input balances in portfolio valuation until settlement or
recovery. The existing `LiquidLaneAction` continues to serve the supplier
inventory-swap flow.

#### Health-checked borrowing

Deploy `BorrowAction(factory)` and initialize with
`abi.encode(IBorrowAction.InitParams(...))`. Initialization fixes the adapter,
borrow target and selector, borrowed token, and health query target/calldata.
`healthFactorOffset` selects a uint256 word in the response: use `0` for a scalar
or `160` for Aave's `getUserAccountData(account)` health factor. The nonzero minimum
uses the query's own units; Aave health factors use `1e18` precision.

The curator changes the floor through a leaf for `setMinHealthFactor(minimum)`.
`borrow(protocolCalldata)` calls the configured function, forwards newly received
borrowed tokens to the adapter, and checks the final health factor. A value below
the floor reverts the complete transaction. Protocol calls that pay the adapter
directly also work. Existing action token balances are preserved.

Bind the asset, debt owner, and recipient arguments in the borrow leaf to the
account named by the fixed health query. For Aave borrowing on behalf of the
adapter, first supply collateral and delegate debt to the action through
separate authorized leaves. Include the position's collateral and debt in the
portfolio oracle.

#### Liquidity Executor

`src/contracts/periphery/Executor.sol` exposes
`execute(adapter, liquiditySteps, actions)`. Each step pairs a static liquidity
query `(target, calldata)` with a normal withdrawal/borrow leaf and an
`amountOffset`. The query returns available funding-token base units. Executor
uses spendable idle assets first, then requests
`min(remaining shortfall, reported liquidity)` from each source in order. It
inserts that amount into the leaf's 32-byte word; every byte of that word must
have a zero mask. For `withdraw(address,uint256)`, the offset is `36`. For
`BorrowAction.borrow(bytes)` wrapping Aave `borrow(address,uint256,uint256,uint16,address)`,
the nested amount offset is `104`.

The final action must be either `LiquidLaneAction.swap(Swap)` or
`ThreeFAction.mintRequest(address,uint128,uint128,uint256)`. Their selectors
are recognized explicitly: Liquid Lane needs `swap.amountOut`; 3F needs the
Request's **current principal authorization for the action**, bounded by the
operation's arguments. Earlier final actions can approve the action. The
final batch must spend exactly that required amount.

Grant every supplied leaf to the caller and every executed leaf to Executor. It
checks all proofs, caller roles, and amount masks before dispatch, including
skipped liquidity candidates. `MerkleAdapter.manage` checks Executor's role when
each leaf executes. Each executed liquidity leaf must increase the adapter's actual token balance
by exactly the requested amount; a mismatch or insufficient funding rolls back
all steps. The funding requirement is read again before the final batch.

Pending allocations and deallocation reserves remain protected. Each step uses
its own `MerkleAdapter.manage` call, so each intermediate balance must also cover
the reserve. If idle assets already fall below that reserve, the first nonzero
step must restore it. Executor holds no tokens and grants no additional caller
permissions.

#### 3F push offers

Configure `ThreeFAction.setMinYieldPerRequest(asset, minimum)` and
`setMaxAssetsPerDuration(asset, maxAssets, duration)` through the adapter for each
collateral underlying. The action resolves that key from the trusted 3F
facility's intent, its position manager, and the collateral token's `underlying()`.
Yield is measured in parts per million of principal. Principal has a cumulative
period budget; there are no configured minimum or maximum amounts per request.
The caller's `maxPrincipalAssets` argument remains an execution slippage bound.

Follow the [3F push-offer setup](https://docs.3f.xyz/bridge-facilitator/console/push-offers/)
to bind the action as the facilitator's `offerAddress`. Submit an unsigned
offer using the facilitator API key and the action as `maker`, with
`useCallback: false` and no `signature` or `chainId`, then wait for `AWAITING_MINT`.
API keys are off-chain credentials. Existing action addresses that previously
submitted offers need onboarding coordinated with 3F: the self-service API rejects
binding an address with prior offers.

The keeper prepares liquidity, approves the action, and calls
`mintRequest(request, maxPrincipalAssets, minYieldAssets, deadline)` through
`MerkleAdapter.manage`. The action reads its own live mint authorization,
checks its bounds and collateral-specific limits, funds the principal, and calls
the request's `mint`. The action receives the PT/YT and clears the request's
token allowance. The adapter's final reserve check protects the whole batch.

This replaces the legacy callback capability's pull flow, offer signer, and
request-nonce configuration. Upgrades preserve existing request accounting and finalization;
the deprecated signer, global-limit, and per-request-limit storage slots remain
reserved. Existing per-asset minimum yields remain in place. Configure the period
budget after upgrading from an implementation without duration budgets before
minting new requests; upgrades from the legacy global-limit capability also need
per-asset minimum yields.
Liquid Lane also starts with disabled budgets when upgrading an older implementation.
Later migrations preserve existing budget configuration and usage.
The implementation constructor now also takes the trusted facility address.

The focused tests cover authorization, reserve accounting, action and capability migrations,
and compatibility with the off-chain Merkle tree fixture:

```sh
forge test --match-path 'test/adapters/{MerkleAdapter.t.sol,merkle-adapter/*.t.sol}'
```

`ThreeFActionMainnetTest` exercises Merkle batches and Executor funding against
deployed 3F contracts at Ethereum block `25_892_000`, including reserve rollback.
`BorrowActionMainnetTest` uses the real Aave V3 pool at the same block.
`CoWSwapActionMainnetTest` settles orders through deployed GPv2 contracts at
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
