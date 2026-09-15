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

Factory-created capabilities extend the adapter: `LiquidLaneCapability` exchanges
configured RWA inventory using oracles created by factories registered in
`OracleRegistry`, while `ThreeFCapability` funds whitelisted 3F requests and returns recovered principal and
yield. Both support state-preserving implementation migrations.

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

`ThreeFCapabilityMainnetTest` exercises the complete Merkle batch against deployed
3F contracts at Ethereum block `25_892_000`, including rollback when minting would
consume reserved assets. Set `ETH_RPC_URL` to an archive-capable endpoint to run it.

## Layout

```text
src/contracts/       Adapter implementations, factories, accounts, oracles
src/interfaces/      Adapter APIs and external protocol interfaces
test/adapters/       Unit, fuzz, accounting, Mainnet, and Benchmark suites
test/invariant/      Stateful AppAdapter invariant coverage
test/deploy/         Deployment and integration tests
script/adapters/     Direct adapter instance deployment and administration
script/deploy/       Factory and composed adapter deployment entrypoints
script/actions/      Vault and adapter administration actions
script/utils/        Shared script and formatting helpers
lib/core/            Pinned public Symbiotic core dependency
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
