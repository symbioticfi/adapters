**[Symbiotic Protocol](https://symbiotic.fi) is an extremely flexible and permissionless shared security system.**

This repository contains adapters that connect Symbiotic vaults to lending, yield, restaking, and tokenized-asset protocols.

Symbiotic adapters consist of:

- **Adapters**: integrations for Aave V3, Euler, ERC-4626, Morpho Vault V2, App, Restaking App, ThreeF, Liquid Lane, and Merkle strategies.
- **Accounts and oracles**: protocol-specific custody, redemption, settlement, and valuation contracts, including Liquid Lane integrations.
- **Merkle strategies**: account permissions, capabilities, recipes, and oracle accounting for strategies managed through approved protocol calls.
- **Factories**: deployment and registration of adapters, accounts, oracles, and automation contracts.
- **Helpers**: token conversion, reward claiming, liquidity queries, and health-factor checks.

## Documentation

- [What is Symbiotic?](https://docs.symbiotic.fi/)
- [Merkle adapter](docs/MERKLE-ADAPTER.md)
- [Merkle deployment and operations](docs/MERKLE-DEPLOYMENT.md)
- [Oracle accounting and controls](docs/MERKLE-ORACLE.md)
- [Capability governance](docs/capability-governance.md)
- [Recipe capability](docs/RECIPE-CAPABILITY.md) and [recipe executor](docs/RECIPE-EXECUTOR.md)
- [Liquidity sources](docs/LIQUIDITY-SOURCES.md), [health factors](docs/BORROW-HEALTH-FACTORS.md), and [health recovery](docs/HEALTH-RECOVERY-RECIPE.md)
- [Redemption integrations](docs/RECIPE-REDEMPTIONS.md)
- [Contributing](CONTRIBUTING.md)

## Usage

### Dependencies

- Git ([installation](https://git-scm.com/downloads))
- Foundry `v1.8.1` ([installation](https://getfoundry.sh/introduction/installation/))
- Node.js from [.nvmrc](.nvmrc) and pnpm `11.25.0`
- Python 3, uv `0.12.1`, and pre-commit `4.6.2` for development hooks

See [installation instructions](CONTRIBUTING.md#install) for the development environment.

### Prerequisites

**Clone the repository**

```sh
git clone --recurse-submodules https://github.com/symbioticfi/adapters.git
cd adapters
```

For an existing checkout, initialize the pinned dependencies:

```sh
git submodule update --init --recursive
```

### Deploy Your Adapter

The [adapter deployment scripts](script/adapters/) create instances through an existing adapter factory.

For example, open [DeployAaveV3Adapter.s.sol](script/adapters/DeployAaveV3Adapter.s.sol) and configure:

```solidity
address public constant ADAPTER_FACTORY = address(0);
uint64 public constant VERSION = 1;
address public constant OWNER = address(0);
address public constant VAULT = address(0);
address public constant CONVERTER = address(0);
```

Set the factory and version for your chain, the intended owner, and the vault. A zero `CONVERTER` creates the adapter without a converter.

Simulate deployment using a configured Foundry keystore:

```sh
forge script script/adapters/DeployAaveV3Adapter.s.sol:DeployAaveV3AdapterScript \
  --rpc-url "$ETH_RPC_URL" --account deployer
```

After reviewing the simulation, add `--broadcast` to deploy. The script logs the adapter, factory, version, owner, and vault addresses.

[Factory and composed deployment scripts](script/deploy/adapters/) deploy the supporting contracts for an integration. For the Merkle adapter, follow the [deployment guide](docs/MERKLE-DEPLOYMENT.md) to configure its factories, account, oracle, and workflow.

### Interact with Vaults

The [V2 action scripts](script/actions/v2/) manage adapters through a vault's delegator:

- [AddAdapter](script/actions/v2/AddAdapter.s.sol), [RemoveAdapter](script/actions/v2/RemoveAdapter.s.sol), and [SwapAdapters](script/actions/v2/SwapAdapters.s.sol): manage the vault's adapter list.
- [AllocateAdapter](script/actions/v2/AllocateAdapter.s.sol), [AllocateAdapterExact](script/actions/v2/AllocateAdapterExact.s.sol), and [AllocateAdapters](script/actions/v2/AllocateAdapters.s.sol): allocate vault assets.
- [DeallocateAdapter](script/actions/v2/DeallocateAdapter.s.sol), [DeallocateAdapters](script/actions/v2/DeallocateAdapters.s.sol), and [DeallocateAdaptersExact](script/actions/v2/DeallocateAdaptersExact.s.sol): return assets to the vault.
- [ForceDeallocateAdapter](script/actions/v2/ForceDeallocateAdapter.s.sol) and [SweepPending](script/actions/v2/SweepPending.s.sol): request an exit or settle pending returns.
- [SetAdapterLimit](script/actions/v2/SetAdapterLimit.s.sol) and [SetAdapterLimits](script/actions/v2/SetAdapterLimits.s.sol): set allocation limits.
- [SetAutoAllocateAdapters](script/actions/v2/SetAutoAllocateAdapters.s.sol): configure automatic allocation.

For example, open [SetAdapterLimits.s.sol](script/actions/v2/SetAdapterLimits.s.sol) and configure:

```solidity
address constant VAULT = address(0);
address constant ADAPTER = address(0);
uint256 constant ABSOLUTE_LIMIT = 0;
uint256 constant SHARE_LIMIT = 0;
```

Use a signer with the required delegator role. To execute through a Foundry keystore:

```sh
forge script script/actions/v2/SetAdapterLimits.s.sol \
  --rpc-url "$ETH_RPC_URL" --account operator --broadcast
```

For a Safe multisig, simulate from its address to obtain the transaction fields:

```sh
forge script script/actions/v2/SetAdapterLimits.s.sol \
  --rpc-url "$ETH_RPC_URL" --sender <MULTISIG_ADDRESS> --unlocked
```

The script prints the configured limits and a Tenderly simulation link. In Safe Transaction Builder, enable **Custom data**, use the link's `contractAddress` as the target, and its `rawFunctionInput` as the calldata.

### Build, Test, and Format

```sh
forge build
forge test --no-match-contract '.*(Mainnet|Benchmark).*'
forge fmt --check
```

The build uses Solidity `0.8.37`, `via_ir = true`, optimizer 200, and the Osaka EVM target. Implementation contracts use `^0.8.28`; interfaces, libraries, tests, and scripts use the lowest compatible `0.8.x` caret pragma.

**Configure environment**

Create a local, Git-ignored `.env` with the values needed for your commands:

```dotenv
ETH_RPC_URL=
ETHERSCAN_API_KEY=
```

Mainnet tests and benchmarks require an archive-capable `ETH_RPC_URL`. `MAINNET_FORK_BLOCK` optionally selects the fork block for suites that support it:

```sh
forge test --isolate --match-contract '.*Mainnet.*' --no-match-contract '.*Benchmark.*'
forge test --isolate --match-contract '.*Benchmark.*'
```

Set `TENDERLY_USERNAME` and `TENDERLY_PROJECT` to populate action scripts' simulation links. The [contributing guide](CONTRIBUTING.md) covers formatting hooks, gas snapshots, dependency updates, and pull request requirements.

## Security

This repository does not currently publish audit reports. The [Merkle audit handoff](docs/MERKLE-AUDIT-HANDOFF.md) documents the contract review scope and the NAV integration work required before production activation.

The project is licensed under the [Business Source License 1.1](LICENSE). Individual files retain their SPDX identifiers and license notices.
