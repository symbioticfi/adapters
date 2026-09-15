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

`CapabilityRegistry` approves exact implementation addresses separately for each
Merkle adapter. Deploy it with the protocol owner, then deploy the Merkle adapter
implementation with `(vaultFactory, adapterFactory, oracleFactory, rootRegistry,
capabilityRegistry)`. Adapter creation still uses the existing adapter factory.

The protocol owner registers a capability's function selectors once and approves
its use by an adapter:

```solidity
capabilityRegistry.initCapability(implementation, selectors);
capabilityRegistry.setWhitelistedStatus(adapter, implementation, true);
```

Selector registration requires deployed code, a nonempty list, and unique nonzero
selectors. The list is immutable. Capabilities are direct implementations written
for delegatecall execution; they do not require a capability factory or proxy.

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

Setting whitelist status to `false` prevents future additions to that adapter;
already-installed functions remain active until the owner calls
`removeCapability(implementation)`. Removal releases exactly the immutable
registered selectors. Re-adding a removed implementation requires current approval.
An owner can atomically replace an implementation
using the existing `multicall` with `removeCapability(old)` followed by
`addCapability(new)`; the new implementation needs its own registration and
adapter-specific approval.

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

The existing factory-created integrations below use ordinary calls and separate
storage; they are not delegatecall implementations for the selector registry.
`LiquidLaneCapability` exchanges
configured RWA inventory using oracles created by factories registered in
`OracleRegistry`, while `ThreeFCapability` funds whitelisted 3F requests and returns recovered principal and
yield. Both support state-preserving implementation migrations.

#### CoW Swap orders

`CoWSwapCapability` uses the same GPv2 order encoding and pre-signing flow as
`CoWSwapConverter`. Deploy the implementation with `(factory, settlement)` and
initialize its proxy with `abi.encode(adapter)`. Through Merkle leaves, approve
the capability and call `convert(tokenIn, amountIn, tokenOut, params)`, where
`params` contains `buyAmount`, `validTo`, and `appData`.

Orders sell an exact funded amount, allow partial fills, charge no explicit fee,
expire within 30 minutes, and send bought tokens directly to the adapter. The
capability grants the CoW relayer only the funded allowance. It tracks one order
per sell token; replacement cancels the old order and returns unspent tokens
before funding the new order. `invalidateConvert(tokenIn)` revokes authorization;
`recover(token)` clears allowance and returns the token balance to the adapter.
Revocation does not call the token and remains available while token operations
are paused; the residual allowance is cleared during recovery or replacement.
Unfilled
sell tokens held by the capability must remain included in portfolio valuation.

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
recovery. The existing `LiquidLaneCapability` continues to serve the supplier
inventory-swap flow.

#### Health-checked borrowing

Deploy `BorrowCapability(factory)` and initialize with
`abi.encode(IBorrowCapability.InitParams(...))`. Initialization fixes the adapter,
borrow target and selector, borrowed token, and health query target/calldata.
`healthFactorOffset` selects a uint256 word in the response: use `0` for a scalar
or `160` for Aave's `getUserAccountData(account)` health factor. The nonzero minimum
uses the query's own units; Aave health factors use `1e18` precision.

The curator changes the floor through a leaf for `setMinHealthFactor(minimum)`.
`borrow(protocolCalldata)` calls the configured function, forwards newly received
borrowed tokens to the adapter, and checks the final health factor. A value below
the floor reverts the complete transaction. Protocol calls that pay the adapter
directly also work. Existing capability token balances are preserved.

Bind the asset, debt owner, and recipient arguments in the borrow leaf to the
account named by the fixed health query. For Aave borrowing on behalf of the
adapter, first supply collateral and delegate debt to the capability through
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
`BorrowCapability.borrow(bytes)` wrapping Aave `borrow(address,uint256,uint256,uint16,address)`,
the nested amount offset is `104`.

The final action must be either `LiquidLaneCapability.swap(Swap)` or
`ThreeFCapability.mintRequest(address,uint128,uint128,uint256)`. Their selectors
are recognized explicitly: Liquid Lane needs `swap.amountOut`; 3F needs the
Request's **current principal authorization for the capability**, bounded by the
operation's arguments. Earlier final actions can approve the capability. The
final batch must spend exactly that required amount.

Grant every supplied leaf to both the caller and Executor. It checks all proofs,
both sets of roles, and amount masks before dispatch, including skipped liquidity
candidates. Each executed leaf must increase the adapter's actual token balance
by exactly the requested amount; a mismatch or insufficient funding rolls back
all steps. The funding requirement is read again before the final batch.

Pending allocations and deallocation reserves remain protected. Each step uses
its own `MerkleAdapter.manage` call, so each intermediate balance must also cover
the reserve. If idle assets already fall below that reserve, the first nonzero
step must restore it. Executor holds no tokens and grants no additional caller
permissions.

#### 3F push offers

Configure `ThreeFCapability.setLimitsPerRequest` through the adapter for each
collateral underlying. The capability resolves that key from the trusted 3F
facility's intent, its position manager, and the collateral token's `underlying()`.
Principal bounds are denominated in the vault's funding asset; yield is measured
in parts per million of principal. A zero maximum disables the collateral asset.

Follow the [3F push-offer setup](https://docs.3f.xyz/bridge-facilitator/console/push-offers/)
to bind the capability as the facilitator's `offerAddress`. Submit an unsigned
offer using the facilitator API key and the capability as `maker`, with
`useCallback: false` and no `signature` or `chainId`, then wait for `AWAITING_MINT`.
API keys are off-chain credentials. Existing capability addresses that previously
submitted offers need onboarding coordinated with 3F: the self-service API rejects
binding an address with prior offers.

The keeper prepares liquidity, approves the capability, and calls
`mintRequest(request, maxPrincipalAssets, minYieldAssets, deadline)` through
`MerkleAdapter.manage`. The capability reads its own live mint authorization,
checks its bounds and collateral-specific limits, funds the principal, and calls
the request's `mint`. The capability receives the PT/YT and clears the request's
token allowance. The adapter's final reserve check protects the whole batch.

This replaces the capability's pull callback, offer signer, and request-nonce
configuration. Upgrades preserve existing request accounting and finalization;
the deprecated signer/global-limit storage slots remain reserved. Configure
per-asset limits after upgrading a legacy capability before minting new requests.
The implementation constructor now also takes the trusted facility address.

The focused tests cover authorization, reserve accounting, capability migrations,
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
