# Contributing

- [Install](#install)
- [Pre-commit Hooks](#pre-commit-hooks)
- [Requirements for merge](#requirements-for-merge)
- [Branching](#branching)
  - [Main](#main)
  - [Audit](#audit)
- [Code Practices](#code-practices)
  - [Code Style](#code-style)
  - [Solidity Versioning](#solidity-versioning)
  - [Interfaces](#interfaces)
  - [NatSpec \& Comments](#natspec--comments)
- [Testing](#testing)
  - [Best Practices](#best-practices)
  - [IR Compilation](#ir-compilation)
  - [Gas Metering](#gas-metering)
- [Bytecode Hash](#bytecode-hash)
- [Dependency Management](#dependency-management)
- [Releases](#releases)

## Install

Follow these steps to set up your local environment for development:

- [Install Foundry](https://book.getfoundry.sh/getting-started/installation) v1.8.5 with `foundryup -i v1.8.5`
- Install Solidity library dependencies: `forge install`
- Install Node.js with `nvm install` (using `.nvmrc`) and [pnpm 12.10.1](https://pnpm.io/installation).
- Install Python 3.14.8 and uv 0.12.23.
- [Install pre-commit](https://pre-commit.com/#installation): `python3 -m pip install --upgrade pre-commit==4.6.2`
- Install pre-commit hooks: `pre-commit install`

Copy `.env.example` to `.env` and fill in values locally. Foundry and the scripting helpers load runtime variables from `.env`. Do not commit `.env` or other secret env files.

## Pre-commit Hooks

Follow the [installation steps](#install) to enable pre-commit hooks. To ensure consistency in our formatting `pre-commit` is used to check whether code was formatted properly. Whenever a commit does not meet the checks implemented by pre-commit, the commit will fail and the pre-commit checks will modify the files to make the commits pass. Include these changes in your commit for the next commit attempt to succeed. On pull requests the CI checks whether tests, formatting, and secret scanning pass.

This repo includes the following pre-commit hooks that are defined in the `.pre-commit-config.yaml`:

- `mixed-line-ending`: This hook ensures that all files have the same line endings (LF).
- `trailing-whitespace`: Strips trailing spaces from lines so that diffs remain clean and editors don't introduce noise.
- `end-of-file-fixer`: Ensures every file ends with a single newline and removes extra blank lines at the end of files.
- `check-merge-conflict`: Fails when Git merge conflict markers are present to avoid committing unresolved conflicts.
- `check-json`: Validates JSON files and fails fast on malformed syntax.
- `check-yaml`: Parses YAML files to verify they are syntactically valid.
- `sort-imports`: Normalises and sorts imports according to the rules mentioned in the [Code Style](#code-style) below. Invoked with `python3`.
- `sort-errors`: Sorts errors according to the rules mentioned in the [Code Style](#code-style) below. Invoked with `python3`.
- `format`: This hook uses `forge fmt` to format all Solidity files.
- `forge-snapshots`: Rebuilds stable size and gas reports under `snapshots/` and runs the local invariant suite. Forge failures stop the hook. Requires the pinned Foundry version (`foundryup -i v1.8.5`) before generating.
- `prettier`: All remaining files are formatted using Prettier 3.9.9 through pnpm.

## Requirements for merge

In order for a PR to be merged, it must pass the following requirements:

- All commits within the PR must be signed
- CI must pass (tests, linting, secret scanning)
- New features must be merged with associated tests
- Bug fixes must have a corresponding test that fails without the fix
- The PR must be approved by at least one maintainer

## Branching

This section outlines the branching strategy of this repo.

### Main

`main` (or `master` while the repository is bootstrapping) is the default integration branch. Conventional Commits should be used for commit messages: https://www.conventionalcommits.org/en/v1.0.0/. Do not treat this branch as a statement of production deployment.

### Audit

If an audit is scheduled, freeze the code on a dedicated branch named `audit/<provider>`. Each fix in response to an audit finding should be developed as a separate commit. The commit message should look similar to `fix: <provider> - <issue title>`. This repository does not currently publish audit reports.

## Code Practices

### Code Style

The repo follows the official [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html). In addition to that, this repo also borrows the following rules from [OpenZeppelin](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/GUIDELINES.md#solidity-conventions):

- Internal or private state variables or functions should have an underscore prefix. Non-private library functions are exempt: library methods use a leading underscore only when they are `private`.

  ```solidity
  contract TestContract {
      uint256 private _privateVar;
      uint256 internal _internalVar;
      function _testInternal() internal { ... }
      function _testPrivate() private { ... }
  }
  ```

- Name incoming constructor values and replacement values with a `new` prefix, such as `newMinDepositLimit`. Do not use trailing underscores such as `minDepositLimit_`. Use descriptive names for other parameters.

  ```solidity
  contract TestContract {
      uint256 public foo;

      constructor(uint256 newFoo) {
        foo = newFoo;
      }
  }
  ```

- Do not create an internal function or a local variable for logic that is used only once; inline it at its use site. Keep required override hooks and locals needed for snapshots, evaluation order, tuple decoding, or memory/assembly access.

- Prefer public state variables and their compiler-generated getters over handwritten getters that only return a state variable. Public arrays expose indexed getters, so account for that ABI when readers need the complete list.

- Cache storage-array lengths before loops instead of loading them from storage on every iteration. Calldata lengths do not need caching.

- Use `using Math for uint256` and extension syntax for `mulDiv` and `saturatingSub`: `a.mulDiv(b, c)` and `a.saturatingSub(b)`, rather than `Math.mulDiv(a, b, c)` and `Math.saturatingSub(a, b)`.

- Call `Math.min(a, b)` and `Math.max(a, b)` using library syntax, rather than extension syntax.

- Initialize structs with named fields in braces, for example `Value({source: Source.Literal, value: amount})`, rather than positional arguments. This applies to contracts, libraries, scripts, and tests.

- Store and pass other contracts as `address`. Typecast to the interface or contract type inline at the call site. Do not declare state variables, constructor parameters, function parameters, or local variables with interface or contract types. Struct types defined on an interface (for example `IManagedVault.Call`) are not contract instances and stay typed as the struct.

  ```solidity
  address public immutable token;

  constructor(address newToken) {
      token = newToken;
  }

  function _mint(address to, uint256 amount) internal {
      IToken(token).mint(to, amount);
  }
  ```

- Interface names should have a capital I prefix.

  ```solidity
  interface IERC777 {
  ```

- Contracts not intended to be used standalone should be marked abstract, so they are required to be inherited by other contracts.

  ```solidity
  abstract contract AccessControl is ..., {
  ```

- Inheritance lists put concrete and abstract implementation bases first, then interfaces. Preserve relative order within each group.

  ```solidity
  contract Vault is AccessControl, Pausable, ReentrancyGuardTransient, IVault, IManagedVault {
  ```

- Unchecked arithmetic blocks should contain comments explaining why overflow is guaranteed not to happen or is permissible. If the reason is immediately apparent from the line above the unchecked block, the comment may be omitted.

Also, such exceptions/additions exist:

- Functions should be grouped according to their visibility and ordered:

  1. constructor

  2. external

  3. public

  4. internal

  5. private

  6. receive function (if exists)

  7. fallback function (if exists)

- Each contract should be virtually divided into sections by using such separators:

  1. /\* CONSTANTS \*/
  2. /\* IMMUTABLES \*/
  3. /\* STATE VARIABLES \*/
  4. /\* MODIFIERS \*/
  5. /\* CONSTRUCTOR \*/
  6. /\* EXTERNAL FUNCTIONS \*/
  7. /\* PUBLIC FUNCTIONS \*/
  8. /\* INTERNAL FUNCTIONS \*/
  9. /\* PRIVATE FUNCTIONS \*/
  10. /\* RECEIVE FUNCTION \*/
  11. /\* FALLBACK FUNCTION \*/

- Each interface should be virtually divided into sections by using such separators:

  1. /\* ERRORS \*/
  2. /\* STRUCTS \*/
  3. /\* EVENTS \*/
  4. /\* FUNCTIONS \*/

- Do not use external and private visibilities in most cases.

- Events should generally be emitted immediately after the state change that they
  represent, and should be named the same as the function's name. Some exceptions may be made for gas
  efficiency if the result doesn't affect the observable ordering of events.

  ```solidity
  function _burn(address who, uint256 value) internal {
      super._burn(who, value);
      emit Burn(who, value);
  }
  ```

- Repository-owned custom errors must have no arguments: `error NotOwner();`. Revert using `if (condition) revert NotOwner();`, without braces around a single revert. Keep error names concise and update selector assertions whenever an error signature changes. Third-party dependency errors and bubbled revert data keep their upstream signatures.

- Define production constants in the corresponding file under `src/interfaces/`, using uppercase names
  without a leading underscore. Declare them at file level, above the interface and outside it, rather
  than inside the type. Role identifiers follow the same rule and belong to the interface of the contract
  that checks them. Import the names a contract uses; do not inherit a constants-only base, which would
  add public getters to every inheritor and, on a contract that routes unknown selectors, permanently
  reserve those selectors.

  ```solidity
  /**
   * @dev Role allowed to freeze, unfreeze, and review an exact oracle report.
   */
  bytes32 constant ORACLE_GUARD_ROLE = keccak256("ORACLE_GUARD_ROLE");

  interface IOracle is ... {
  ```

- Imports should be divided into separate groups and ordered alphabetically ascending inside each group:

  1. contracts

  2. libraries

  3. interfaces

  4. external files separately

  ```solidity
  import {NetworkManager} from "../base/NetworkManager.sol";
  import {OzEIP712} from "../base/OzEIP712.sol";
  import {PermissionManager} from "../base/PermissionManager.sol";

  import {Checkpoints} from "../../libraries/structs/Checkpoints.sol";
  import {KeyTags} from "../../libraries/utils/KeyTags.sol";

  import {ISettlement} from "../interfaces/modules/settlement/ISettlement.sol";
  import {ISigVerifier} from "../interfaces/modules/settlement/sig-verifiers/ISigVerifier.sol";

  import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
  ```

- Use `value > 0` instead of `value != 0` for unsigned integer nonzero checks. Do not apply this rewrite to signed integers, where negative values are also nonzero.

- In case of comparison with `msg.sender` or `tx.origin`, these keywords should be on the right side of the inequality.

  ```solidity
  modifier onlyOwner() internal {
      if (owner != msg.sender) revert NotOwner();
  }
  ```

- Errors should be ordered alphabetically ascending.

  ```solidity
  error InsufficientFunds();
  error NoAccess();
  error NotOwner();
  ```

### Solidity Versioning

Implementation contracts under `src/contracts/` use:

```solidity
pragma solidity ^0.8.28;
```

Interfaces, libraries (including those under `src/contracts/`), tests, mocks, and scripts use a caret pragma with the lowest Solidity `0.8.x` version supporting the language features used in that file. Start at `^0.8.0` and raise it only when needed, for example to `^0.8.4` for custom errors, `^0.8.12` for `abi.encodeCall` with a contract type, `^0.8.13` for memory-safe assembly, `^0.8.18` for named mapping parameters, or `^0.8.21` for qualified event access.

The build compiler remains pinned to Solidity `0.8.37` in `foundry.toml`. Compile with that version; capabilities use the newer `erc7201` builtin. A file's minimum pragma describes its own language features; imported files can impose a higher compiler requirement.

### Interfaces

Every contract MUST implement its corresponding interface that includes all externally callable functions, errors and events. Getters that expose another contract MUST return `address`, not the interface type.

Implementation-only helper contracts and externally visible helpers used solely by their parent or through self-calls do not need separate interface declarations.

### NatSpec & Comments

Interfaces should be the entry point for all contracts. When exploring a contract within the repository, the interface MUST contain all relevant information to understand the functionality of the contract in the form of NatSpec comments. This includes all externally callable functions, structs, errors and events. The NatSpec documentation MUST be added to the functions, structs, errors and events within the interface. This allows a reader to understand the functionality of a function before moving on to the implementation. The implementing functions MUST point to the NatSpec documentation in the interface using `@inheritdoc`. Internal and private functions shouldn't have NatSpec documentation except for `@dev` comments, whenever more context is needed. Additional comments within a function should only be used to give more context to more complex operations; otherwise, the code should be kept readable and self-explanatory. NatSpec comments in contracts should use a triple slash (`///`) to bring less noise to the implementation, while libraries and interfaces should use `/* */` wrappers.

The comments should respect the following rules:

- For read functions: `@notice Returns <...>`
- For write functions: `@notice <What it does, starts with verb>`
- For structs: `@notice <What it is>`
- For errors: `@notice Raised when <...>`
- For events: `@notice Emitted when <...>`

Each contract/library/interface should have a title comment that should follow such a structure:

1. `@title <Name>` (e.g., `Vault`)
2. `@notice Contract/Library/Interface for <...>.` - also, other variations are possible, e.g.:
   - `@notice Interface for the Vault contract.`
   - `@notice Base contract for <...>.`
   - `@notice Library-logic for <...>.`
3. `@dev <...>` (optional)

## Testing

The following testing practices should be followed when writing unit tests for new code. All functions, lines and branches should be tested to result in 100% testing coverage. Fuzz parameters and conditions whenever possible. Extremes should be tested in dedicated edge case and corner case tests. Invariants should be tested in dedicated invariant tests.

Differential testing should be used to compare assembly implementations with implementations in Solidity or testing alternative implementations against existing Solidity or non-Solidity code using ffi.

New features must be merged with associated tests. Bug fixes should have a corresponding test that fails without the bug fix.

CI runs contract and recipe-execution tests, including the local invariant and mainnet fork suites. The `pr`, `ci`, and `snapshots` profiles exclude deployment scripts and recipe CLI tests. Python tooling tests are local-only. The default Foundry profile still includes script tests; prepare their upstream artifacts with `python3 script/deploy/testnet/upstream/prepare.py` before running them locally.

### Best Practices

Best practices and naming conventions should be followed as outlined in the [Foundry Book](https://getfoundry.sh/forge/tests/overview).

### IR Compilation

The default build uses `via_ir = true` with Solidity `0.8.37`, optimizer 200 and the Osaka EVM target. Contracts, tests and scripts use this shared configuration, including Chainlink dependencies. Keep the IR pipeline enabled when building release artifacts and regenerating gas or size snapshots. Non-IR compilation is an optional comparison, not a merge requirement.

CI and snapshot generation use `python3 script/utils/build.py` to compile groups of source files before the final complete build. This reduces peak compiler memory while preserving the compiler settings.

### Gas Metering

Gas for function calls should be metered using the built-in `vm.snapshotGasLastCall` function in forge. To meter across multiple calls `vm.startSnapshotGas` and `vm.stopSnapshotGas` can be used. Tests that measure gas should be annotated with `/// forge-config: default.isolate = true` and not be fuzzed to ensure that the gas snapshot is accurate and consistent for CI verification. All external functions should have a gas snapshot test, and diverging paths within a function should have appropriate gas snapshot tests.
For more information on gas metering, see the [Forge cheatcodes reference](https://getfoundry.sh/reference/cheatcodes/gas-snapshots/#snapshotgas-cheatcodes).

## Bytecode Hash

Bytecode hash should be set to `none` in the `foundry.toml` file to ensure that the bytecode is consistent.

## Dependency Management

The preferred way to manage Solidity dependencies is using [`forge install`](https://book.getfoundry.sh/forge/dependencies). This ensures that your project uses the correct versions and structure for all external libraries. Python helpers are invoked with `python3`.

## Releases

Tag GitHub releases when contracts are published. This repository does not currently claim a production deployment.
