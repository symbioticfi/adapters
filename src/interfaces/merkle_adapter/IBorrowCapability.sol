// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";

/// @title IBorrowCapability
/// @notice Adapter-bound borrowing with a fixed protocol call and a checked final health factor.
interface IBorrowCapability is IMigratableEntity {
    /// @notice Reverts when the final health factor is below the configured minimum.
    error HealthFactorTooLow(uint256 healthFactor, uint256 minimum);

    /// @notice Reverts when initialization specifies a zero adapter.
    error InvalidAdapter();

    /// @notice Reverts when the configured borrowed asset has no code.
    error InvalidBorrowAsset();

    /// @notice Reverts when borrow calldata does not contain the configured selector.
    error InvalidBorrowData();

    /// @notice Reverts when the configured borrow target has no code.
    error InvalidBorrowTarget();

    /// @notice Reverts when a state-changing function is not called by the bound adapter.
    error InvalidCaller();

    /// @notice Reverts when the health query contains no function selector.
    error InvalidHealthFactorData();

    /// @notice Reverts when the health factor byte offset is not a multiple of 32.
    error InvalidHealthFactorOffset();

    /// @notice Reverts when the health query does not return complete ABI words including the configured word.
    error InvalidHealthFactorResponse();

    /// @notice Reverts when the configured health query target has no code.
    error InvalidHealthFactorTarget();

    /// @notice Reverts when an implementation migration tries to reconfigure the capability.
    error InvalidMigrationData();

    /// @notice Reverts when the minimum health factor is zero.
    error InvalidMinHealthFactor();

    /// @notice Fixed configuration passed to factory initialization as `abi.encode(params)`.
    /// @param adapter The adapter allowed to borrow and update the minimum health factor.
    /// @param borrowTarget The sole protocol target the capability can call to borrow.
    /// @param borrowSelector The sole function selector accepted by `borrow`.
    /// @param borrowAsset ERC-20 whose newly received balance is forwarded to the adapter.
    /// @param healthFactorTarget Contract queried after borrowing and forwarding proceeds.
    /// @param healthFactorData Complete fixed query calldata, including the account to check.
    /// @param healthFactorOffset Byte offset of the uint256 health factor in the query response.
    /// @param minHealthFactor Nonzero minimum in the health query's native units.
    struct InitParams {
        address adapter;
        address borrowTarget;
        bytes4 borrowSelector;
        address borrowAsset;
        address healthFactorTarget;
        bytes healthFactorData;
        uint256 healthFactorOffset;
        uint256 minHealthFactor;
    }

    /// @notice Emitted after the borrow and token forwarding pass the final health check.
    /// @param data Protocol calldata executed by the capability.
    /// @param forwardedAssets Newly received borrowed assets forwarded to the adapter.
    /// @param healthFactor Final health factor in the configured query's native units.
    event Borrow(bytes data, uint256 forwardedAssets, uint256 healthFactor);

    /// @notice Emitted when the adapter changes the nonzero minimum health factor.
    /// @param minHealthFactor New minimum in the configured query's native units.
    event SetMinHealthFactor(uint256 minHealthFactor);

    /// @notice Returns the only adapter authorized to borrow and set the minimum health factor.
    function adapter() external view returns (address);

    /// @notice Returns the fixed protocol target called by the capability.
    function borrowTarget() external view returns (address);

    /// @notice Returns the fixed borrowing function selector.
    function borrowSelector() external view returns (bytes4);

    /// @notice Returns the ERC-20 whose newly received balance is forwarded to the adapter.
    function borrowAsset() external view returns (address);

    /// @notice Returns the fixed target queried for the account's health factor.
    function healthFactorTarget() external view returns (address);

    /// @notice Returns the complete fixed health query calldata, including its account arguments.
    function healthFactorData() external view returns (bytes memory);

    /// @notice Returns the aligned byte offset of the health factor in the query response.
    function healthFactorOffset() external view returns (uint256);

    /// @notice Returns the minimum allowed health factor in the query's native units.
    function minHealthFactor() external view returns (uint256);

    /// @notice Executes the fixed borrow function, forwards newly received assets, and checks final health.
    /// @dev Only the adapter can call. The adapter's Merkle permissions must bind protocol arguments,
    ///      including the borrowed asset, debt owner and recipient, to the configured health query.
    ///      The protocol sees this capability as its caller. Aave-style borrowing for the adapter
    ///      therefore requires the adapter to delegate debt to the capability beforehand.
    ///      Direct transfers from the protocol to the adapter are also supported. Existing capability
    ///      token balances are preserved. Native-currency borrowing is not supported.
    /// @param data Full protocol calldata beginning with the configured borrow selector.
    /// @return result Unmodified protocol return data.
    function borrow(bytes calldata data) external returns (bytes memory result);

    /// @notice Changes the minimum health factor through the adapter's curator-authorized call path.
    /// @dev The query and all protocol configuration remain fixed. Does not execute a borrow.
    /// @param minHealthFactor_ Nonzero minimum in the configured query's native units.
    function setMinHealthFactor(uint256 minHealthFactor_) external;

    /// @notice Reads the configured account's current health factor without enforcing the minimum.
    /// @dev Supports a single uint256 or an ABI tuple; for Aave `getUserAccountData`, use byte offset 160.
    /// @return healthFactor Current uint256 at the fixed response offset.
    function getHealthFactor() external view returns (uint256 healthFactor);
}
