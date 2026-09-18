// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IRegistry} from "@symbioticfi/core/src/interfaces/common/IRegistry.sol";

/**
 * @title IImmutableFactory
 * @notice Interface for deploying and registering contracts from fixed creation bytecode.
 */
interface IImmutableFactory is IRegistry {
    /* ERRORS */

    /**
     * @notice Raised when deployment fails without revert data or produces no runtime code.
     */
    error DeploymentFailed();

    /* FUNCTIONS */

    /**
     * @notice Returns the creation bytecode fixed when the factory was constructed.
     * @dev This is creation bytecode, such as type(Executor).creationCode, without constructor arguments.
     * @return bytecode Fixed implementation creation bytecode.
     */
    function implementation() external view returns (bytes memory bytecode);

    /**
     * @notice Deploys a new contract and registers its address.
     * @dev Permissionless. Uses CREATE with implementation() concatenated with data and zero native value.
     * The constructor runs with the factory as msg.sender; encode any owner explicitly in data.
     * Repeated calls deploy distinct instances. Constructor revert data is bubbled, and failed or empty-code
     * deployments leave the registry unchanged. Registration emits the inherited AddEntity event after construction.
     * @param data ABI-encoded constructor arguments, or empty bytes for a constructor without arguments.
     * @return entityAddress Address of the deployed and registered contract.
     */
    function create(bytes calldata data) external returns (address entityAddress);
}
