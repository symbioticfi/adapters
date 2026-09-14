# Contributing

This repository hosts adapters for Symbiotic vaults. Keep changes scoped
to adapter contracts, interfaces, accounts, oracles, converters, deployment
scripts, and their tests. Shared core code is consumed through the pinned
`lib/core` submodule; do not copy a second local implementation into `src/`.

## Setup

Install and pin the repository toolchain:

- Foundry `v1.8.1` (`foundryup -i v1.8.1`)
- Node.js `24.20.0` from `.nvmrc`
- pnpm `11.25.0`
- uv `0.12.1`
- pre-commit `4.6.2`

Initialize all pinned dependencies with:

```sh
git submodule update --init --recursive
uv tool install pre-commit==4.6.2
uvx --from pre-commit==4.6.2 pre-commit install
```

The adapter contracts use the root OpenZeppelin `5.7.0` dependencies. Import
shared core contracts and interfaces through `@symbioticfi/core/src/...`.
Only core's `MigratableEntityProxy.sol` uses its nested OpenZeppelin imports;
shared inheritance uses the root version. Core's forge-std and Solady imports
also have contextual remappings. Preserve these boundaries when adding imports.

## Repository scope and extension patterns

Production adapter implementations live under `src/contracts/`, with
their public APIs under `src/interfaces/`. Liquid Lane accounts and
oracles are grouped under their adapter subtree. Follow the existing pattern:

1. Define externally visible functions, errors, events, and structs
   in the corresponding interface.
2. Implement the interface in the adapter contract and use `@inheritdoc` for
   implementation documentation.
3. Keep protocol-specific external interfaces under the matching
   `src/interfaces/ll-adapter/<protocol>/` directory for Liquid Lane integrations.
4. Add deployment entrypoints under `script/adapters/` or
   `script/deploy/adapters/`, reusing the existing adapter base scripts.
5. Add mocks and focused tests beside the relevant adapter test subtree.

Use the closest existing adapter as a reference for its base contracts and
allocation, deallocation, and asset valuation hooks. Check both success and failure paths,
zero amounts, access control, accounting, and token approval behavior. Keep
constructor and initialization behavior consistent with the surrounding adapter
family. Changes that affect CREATE2 bytecode or deterministic addresses must
update the relevant deployment assertions and explain the new addresses.

Pin contracts under `src/contracts/` to `pragma solidity 0.8.36;` without a caret.
Keep interface compatibility ranges separate from implementation compiler pins.
Use the repository Solidity style: ordered imports and errors, underscore prefixes for internal/private
members, custom errors, and comments for non-obvious unchecked arithmetic. The
repository compiler target is Solidity `0.8.36`. Keep interfaces complete and
ensure new public behavior has NatSpec documentation. Add comments above new
functions explaining their purpose, operation, and usage.

## Testing

Run the offline adapter suite during development:

```sh
forge build
forge fmt --check
forge test --no-match-contract '.*(Mainnet|Benchmark).*'
```

Run invariant coverage separately when changing stateful accounting or
allocation behavior:

```sh
forge test --isolate --threads 1 --fuzz-seed 0 --match-test '^invariant_' --no-match-contract '.*(Mainnet|Benchmark).*'
```

Mainnet and benchmark suites use `ETH_RPC_URL` from the local ignored `.env`;
`MAINNET_FORK_BLOCK` optionally selects the fork block. They run in separate CI
jobs. Run them locally with:

```sh
forge test --isolate --match-contract '.*Mainnet.*' --no-match-contract '.*Benchmark.*'
forge test --isolate --match-contract '.*Benchmark.*'
```

Fork tests are integration evidence only when they execute against the
intended live state. A skipped fork test does not verify the integration.

The snapshot hook uses Foundry `1.8.1`, serial execution, a fixed fuzz seed,
and excludes Mainnet/Benchmark tests. It validates invariant tests separately
and excludes their variable stateful gas measurements from the aggregate gas
report. Run it twice when changing gas-sensitive code and confirm the generated
reports are unchanged:

```sh
uvx --from pre-commit==4.6.2 pre-commit run forge-snapshots --all-files
shasum -a 256 snapshots/gas.txt snapshots/sizes.txt > /tmp/adapters-snapshot-hashes.txt
uvx --from pre-commit==4.6.2 pre-commit run forge-snapshots --all-files
shasum -a 256 -c /tmp/adapters-snapshot-hashes.txt
```

The first run may report files modified; review and include those generated
changes. The repeat must pass without modifying reports. Hooks operate on
Git-tracked files, so add intended new files before running the complete checks:

```sh
uvx --from pre-commit==4.6.2 pre-commit run --all-files
```

## Dependency and documentation changes

Keep `foundry.lock`, `.gitmodules`, `remappings.txt`, and `package.json`
consistent when changing a dependency. Record the exact commit or release and
explain any change in compiler, bytecode, or deployment-address behavior.
Keep the core submodule clean and do not introduce filesystem links or sibling
checkout assumptions.

Update README or relevant documentation when adding an adapter, deployment
flow, external protocol integration, or test suite. Do not include secrets in
commits or CI configuration.

## Pull requests

A pull request should describe the adapter behavior changed, the motivation,
and any dependency or deployment-address impact. Include tests for new
behavior and regression tests for fixes. Before requesting review, run the
offline suite, applicable fork or benchmark suites, formatting checks, and the
complete pre-commit hook set. Address the PR template's coverage, analyzer, and
fuzz/invariant checklist items when they apply. CI must pass, and the change
should receive maintainer review before merge.
