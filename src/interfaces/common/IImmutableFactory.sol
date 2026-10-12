// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IRegistry} from "@symbioticfi/core/src/interfaces/common/IRegistry.sol";

/**
 * @title IImmutableFactory
 * @notice Interface for deploying and registering contracts from fixed creation bytecode.
 * @dev Creation bytecode is stored using SSTORE2; the EVM code-size limit allows up to 24,575 bytes.
 */
interface IImmutableFactory is IRegistry {
    /* ERRORS */

    /**
     * @notice Raised when deployment fails or produces no runtime code.
     */
    error DeploymentFailed();

    /* FUNCTIONS */

    /**
     * @notice Returns the SSTORE2 pointer containing the fixed creation bytecode.
     * @dev SSTORE2.read(pointer) returns the creation bytecode without constructor arguments or the STOP prefix.
     * @return pointer Address of the bytecode-storage contract.
     */
    function implementationPointer() external view returns (address pointer);

    /**
     * @notice Deploys a new contract and registers its address.
     * @dev Permissionless. Uses CREATE with the stored creation bytecode concatenated with data and zero native value.
     * The constructor runs with the factory as msg.sender; encode any owner explicitly in data.
     * Registration proves only the creation code; constructor arguments such as owners are caller-chosen.
     * Repeated calls deploy distinct instances. Failed or empty-code deployments revert with DeploymentFailed
     * and leave the registry unchanged. Registration emits the inherited AddEntity event after construction.
     * The current factory nonce may change before a transaction executes; a predicted address is not reserved.
     * Deploy first, verify the returned instance's owner and account bindings, then grant permissions.
     * Never pre-grant permissions to a predicted CREATE address.
     * @param data ABI-encoded constructor arguments, or empty bytes for a constructor without arguments.
     * @return entityAddress Address of the deployed and registered contract.
     */
    function create(bytes calldata data) external returns (address entityAddress);
}
