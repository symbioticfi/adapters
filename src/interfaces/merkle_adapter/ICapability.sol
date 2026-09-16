// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ICapability
 * @notice Interface for capability code executed in a Merkle adapter's context.
 */
interface ICapability {
    /* ERRORS */

    /**
     * @notice Raised when a capability operation is not called by the adapter itself.
     */
    error InvalidCaller();
}
