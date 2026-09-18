// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {IRootRegistry} from "../../interfaces/merkle_adapter/IRootRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title RootRegistry
/// @notice Protocol-owned registry contract for proposed adapter Merkle roots.
contract RootRegistry is Ownable, IRootRegistry {
    /* STATE VARIABLES */

    /// @inheritdoc IRootRegistry
    mapping(address adapter => bytes32 root) public roots;

    /* CONSTRUCTOR */

    /// @dev Sets the protocol owner that may publish roots.
    constructor(address newOwner) Ownable(newOwner) {}

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IRootRegistry
    function setRoot(address adapter, bytes32 newRoot) public onlyOwner {
        roots[adapter] = newRoot;

        emit SetRoot(adapter, newRoot);
    }
}
