// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ICapabilitiesRegistry} from "../../interfaces/merkle-adapter/ICapabilitiesRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CapabilitiesRegistry
/// @notice Contract for whitelisting capability selectors for individual accounts.
contract CapabilitiesRegistry is Ownable, ICapabilitiesRegistry {
    /* STATE VARIABLES */

    mapping(address account => mapping(address capability => bytes4[] selectors)) internal _selectors;

    /* CONSTRUCTOR */

    constructor(address newOwner) Ownable(newOwner) {}

    /* VIEW FUNCTIONS */

    /// @inheritdoc ICapabilitiesRegistry
    function selectors(address account, address capability) public view returns (bytes4[] memory) {
        return _selectors[account][capability];
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ICapabilitiesRegistry
    function whitelistCapability(address account, address capability, bytes4[] calldata signatures) public onlyOwner {
        if (signatures.length > 0 && capability.code.length == 0) revert InvalidCapabilityCode();

        _selectors[account][capability] = signatures;
        emit WhitelistCapability(account, capability, signatures);
    }
}
