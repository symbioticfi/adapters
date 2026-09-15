// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {IRootRegistry} from "../../interfaces/merkle_adapter/IRootRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title RootRegistry
/// @notice Protocol-owned registry of proposed adapter Merkle roots.
contract RootRegistry is Ownable, IRootRegistry {
    /// @inheritdoc IRootRegistry
    mapping(address adapter => bytes32 root) public roots;

    /// @dev Sets the protocol owner that may publish roots.
    constructor(address owner_) Ownable(owner_) {}

    /// @inheritdoc IRootRegistry
    function setRoot(address adapter, bytes32 root) public onlyOwner {
        roots[adapter] = root;

        emit SetRoot(adapter, root);
    }
}
