// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {ICapabilitiesRegistryProposer} from "src/interfaces/merkle_adapter/ICapabilitiesRegistryProposer.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CapabilitiesRegistryProposer
/// @notice Protocol-owned catalog of immutable capability code and registry/adapter-scoped proposals.
contract CapabilitiesRegistryProposer is Ownable, ICapabilitiesRegistryProposer {
    /// @inheritdoc ICapabilitiesRegistryProposer
    mapping(address capability => bytes32 codeHash) public capabilityCodeHash;

    /// @inheritdoc ICapabilitiesRegistryProposer
    mapping(address registry => mapping(address adapter => mapping(address capability => bool status))) public
        isProposed;

    /// @dev Nonempty selector lists also mark implementations as initialized.
    mapping(address capability => bytes4[] selectors) private _capabilitySelectors;

    /// @dev Sets the protocol owner that registers code and manages proposals.
    constructor(address newOwner) Ownable(newOwner) {}

    /// @inheritdoc ICapabilitiesRegistryProposer
    function initCapability(address capability, bytes4[] calldata selectors) public onlyOwner {
        if (isInitialized(capability)) {
            revert CapabilityAlreadyInitialized();
        }
        if (capability.code.length == 0) {
            revert InvalidCapability();
        }
        if (selectors.length == 0) {
            revert EmptySelectors();
        }
        for (uint256 i; i < selectors.length; ++i) {
            if (selectors[i] == bytes4(0)) {
                revert InvalidSelector();
            }
            for (uint256 j; j < i; ++j) {
                if (selectors[i] == selectors[j]) {
                    revert DuplicateSelector();
                }
            }
        }
        _capabilitySelectors[capability] = selectors;
        bytes32 codeHash = capability.codehash;
        capabilityCodeHash[capability] = codeHash;
        emit InitCapability(capability, codeHash, selectors);
    }

    /// @inheritdoc ICapabilitiesRegistryProposer
    function setProposedStatus(address registry, address adapter, address capability, bool status) public onlyOwner {
        if (status) {
            if (!isInitialized(capability)) {
                revert CapabilityNotInitialized();
            }
            if (capability.codehash != capabilityCodeHash[capability]) {
                revert InvalidCapabilityCode();
            }
            if (registry.code.length == 0) {
                revert InvalidRegistry();
            }
        }
        isProposed[registry][adapter][capability] = status;
        emit SetProposedStatus(registry, adapter, capability, status);
    }

    /// @inheritdoc ICapabilitiesRegistryProposer
    function isInitialized(address capability) public view returns (bool initialized) {
        return _capabilitySelectors[capability].length != 0;
    }

    /// @inheritdoc ICapabilitiesRegistryProposer
    function getCapabilitySelectors(address capability) public view returns (bytes4[] memory selectors) {
        return _capabilitySelectors[capability];
    }
}
