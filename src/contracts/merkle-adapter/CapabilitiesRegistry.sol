// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ICapabilitiesRegistry} from "../../interfaces/merkle-adapter/ICapabilitiesRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CapabilitiesRegistry
/// @notice Contract for whitelisting capability selectors for individual adapters.
contract CapabilitiesRegistry is Ownable, ICapabilitiesRegistry {
    /* STATE VARIABLES */

    /// @inheritdoc ICapabilitiesRegistry
    mapping(address adapter => mapping(address capability => bytes4[] selectors)) public capabilitySelectors;

    /* CONSTRUCTOR */

    constructor(address newOwner) Ownable(newOwner) {}

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ICapabilitiesRegistry
    function whitelistCapability(address adapter, address capability, bytes4[] calldata signatures) public onlyOwner {
        if (signatures.length > 0 && capability.code.length == 0) revert InvalidCapabilityCode();

        capabilitySelectors[adapter][capability] = signatures;
        emit WhitelistCapability(adapter, capability, signatures);
    }

    /// @inheritdoc ICapabilitiesRegistry
    function capabilitySelectorsLength(address adapter, address capability) public view returns (uint256) {
        return capabilitySelectors[adapter][capability].length;
    }
}
