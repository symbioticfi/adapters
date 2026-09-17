// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICapability} from "./ICapability.sol";

/**
 * @title IBorrowCapability
 * @notice Interface for adapter-context borrowing with a fixed protocol call and a checked final health factor.
 */
interface IBorrowCapability is ICapability {
    /* ERRORS */

    /**
     * @notice Raised when the final health factor is below the configured minimum.
     */
    error HealthFactorTooLow();

    /**
     * @notice Raised when borrow calldata does not contain the configured selector.
     */
    error InvalidBorrowData();

    /**
     * @notice Raised when the health query does not return complete ABI words including the configured aligned word.
     */
    error InvalidHealthFactorResponse();

    /**
     * @notice Raised when the minimum health factor is zero.
     */
    error InvalidMinHealthFactor();

    /**
     * @notice Raised when borrowing is attempted before the curator sets a minimum health factor.
     */
    error MinHealthFactorNotSet();

    /* STRUCTS */

    /**
     * @notice Fixed configuration supplied to the capability implementation's constructor.
     * @param borrowTarget The sole protocol target the capability can call to borrow.
     * @param borrowSelector The sole function selector accepted by `borrow`.
     * @param borrowAsset ERC-20 whose adapter balance increase is measured after borrowing.
     * @param healthFactorTarget Contract queried after borrowing.
     * @param healthFactorData Complete fixed query calldata, including the account to check.
     * @param healthFactorOffset Byte offset of the uint256 health factor in the query response.
     */
    struct ConstructorParams {
        address borrowTarget;
        bytes4 borrowSelector;
        address borrowAsset;
        address healthFactorTarget;
        bytes healthFactorData;
        uint256 healthFactorOffset;
    }

    /* EVENTS */

    /**
     * @notice Emitted when borrowing passes the final health check.
     * @param data Protocol calldata executed by the capability.
     * @param borrowedAssets Increase in the adapter's borrowed-token balance.
     * @param healthFactor Final health factor in the configured query's native units.
     */
    event Borrow(bytes data, uint256 borrowedAssets, uint256 healthFactor);

    /**
     * @notice Emitted when the adapter changes the nonzero minimum health factor.
     * @param minHealthFactor New minimum in the configured query's native units.
     */
    event SetMinHealthFactor(uint256 minHealthFactor);

    /* FUNCTIONS */

    /**
     * @notice Returns the fixed protocol target called by the capability.
     */
    function borrowTarget() external view returns (address);

    /**
     * @notice Returns the fixed borrowing function selector.
     */
    function borrowSelector() external view returns (bytes4);

    /**
     * @notice Returns the ERC-20 whose adapter balance increase is measured after borrowing.
     */
    function borrowAsset() external view returns (address);

    /**
     * @notice Returns the fixed target queried for the account's health factor.
     */
    function healthFactorTarget() external view returns (address);

    /**
     * @notice Returns the complete fixed health query calldata, including its account arguments.
     * @dev Reads the constructor-set calldata from the implementation, including through delegatecall.
     */
    function healthFactorData() external view returns (bytes memory);

    /**
     * @notice Returns the byte offset of the health factor in the query response.
     */
    function healthFactorOffset() external view returns (uint256);

    /**
     * @notice Returns the minimum allowed health factor in the query's native units.
     * @dev Adapter-local. Zero means borrowing is disabled until setMinHealthFactor is called.
     */
    function minHealthFactor() external view returns (uint256);

    /**
     * @notice Executes the fixed borrow function from the adapter and checks its final health factor.
     * @dev Requires an adapter self-call. Merkle permissions must bind the asset, debt owner and recipient
     * to the configured health query. The protocol sees the adapter as its caller, and borrowed tokens
     * stay on the adapter. Native-currency borrowing is not supported. The adapter's manage guard
     * prevents reentry into managed calls; all state-changing capability functions require onlyMyself.
     * Reverts until a nonzero minimum has been set through setMinHealthFactor.
     * @param data Full protocol calldata beginning with the configured borrow selector.
     * @return result Unmodified protocol return data.
     */
    function borrow(bytes calldata data) external returns (bytes memory result);

    /**
     * @notice Changes the minimum health factor through the adapter's curator-authorized call path.
     * @dev Sets the adapter-local minimum, including its initial value. The constructor-set protocol
     * configuration and query remain fixed. Replacement retains the minimum but uses the new implementation's query.
     * Does not execute a borrow or enforce current health.
     * @param newMinHealthFactor Nonzero minimum in the configured query's native units.
     */
    function setMinHealthFactor(uint256 newMinHealthFactor) external;

    /**
     * @notice Returns the configured account's current health factor without enforcing the minimum.
     * @dev Supports a single uint256 or an ABI tuple; for Aave `getUserAccountData`, use byte offset 160.
     * @return healthFactor Current uint256 at the fixed response offset.
     */
    function getHealthFactor() external view returns (uint256 healthFactor);
}

/**
 * @title IBorrowCapabilityConstants
 * @notice Constants for the BorrowCapability storage namespace.
 */
abstract contract IBorrowCapabilityConstants {
    /// @dev keccak256(abi.encode(uint256(keccak256("symbiotic.storage.BorrowCapability")) - 1)) & ~bytes32(uint256(0xff)).
    bytes32 internal constant BORROW_STORAGE_LOCATION =
        0x14594e0b2a6dcf0d335223cd7b83327c553fe4ff39745016f5460d86c7a0dd00;
}
