// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {IImmutableFactory} from "../../interfaces/common/IImmutableFactory.sol";

import {Registry} from "@symbioticfi/core/src/contracts/common/Registry.sol";

import {SSTORE2} from "solady/utils/SSTORE2.sol";

/// @title ImmutableFactory
/// @notice Factory contract for deploying and registering instances of fixed creation bytecode.
/// @dev Permissionless CREATE deployment; the next address is not reserved for any caller.
/// Grant permissions only after deployment to the returned instance and verification of its owner and bindings.
contract ImmutableFactory is Registry, IImmutableFactory {
    /* IMMUTABLES */

    /// @inheritdoc IImmutableFactory
    address public immutable implementationPointer;

    /* CONSTRUCTOR */

    constructor(bytes memory newImplementation) {
        implementationPointer = SSTORE2.write(newImplementation);
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IImmutableFactory
    function create(bytes calldata data) public returns (address entityAddress) {
        bytes memory bytecode = bytes.concat(SSTORE2.read(implementationPointer), data);
        assembly ("memory-safe") {
            entityAddress := create(0, add(bytecode, 32), mload(bytecode))
        }
        if (entityAddress.code.length == 0) revert DeploymentFailed();

        _addEntity(entityAddress);
    }
}
