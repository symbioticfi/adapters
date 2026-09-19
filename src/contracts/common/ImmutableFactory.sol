// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {IImmutableFactory} from "../../interfaces/common/IImmutableFactory.sol";

import {LowLevelCall} from "@openzeppelin/contracts/utils/LowLevelCall.sol";

import {Registry} from "@symbioticfi/core/src/contracts/common/Registry.sol";

/// @title ImmutableFactory
/// @notice Factory contract for deploying and registering instances of fixed creation bytecode.
contract ImmutableFactory is Registry, IImmutableFactory {
    /* STATE VARIABLES */

    /// @inheritdoc IImmutableFactory
    bytes public implementation;

    /* CONSTRUCTOR */

    constructor(bytes memory newImplementation) {
        implementation = newImplementation;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IImmutableFactory
    function create(bytes calldata data) public returns (address entityAddress) {
        bytes memory bytecode = bytes.concat(implementation, data);
        assembly ("memory-safe") {
            entityAddress := create(0, add(bytecode, 32), mload(bytecode))
        }
        if (entityAddress == address(0) && LowLevelCall.returnDataSize() > 0) LowLevelCall.bubbleRevert();
        if (entityAddress.code.length == 0) revert DeploymentFailed();

        _addEntity(entityAddress);
    }
}
