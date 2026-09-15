// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {ICapabilityRegistry} from "src/interfaces/merkle_adapter/ICapabilityRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CapabilityRegistry
/// @notice Owned registry of immutable capability selectors and adapter-scoped implementation approvals.
contract CapabilityRegistry is Ownable, ICapabilityRegistry {
    /// @inheritdoc ICapabilityRegistry
    mapping(address adapter => mapping(address capability => bool status)) public isWhitelisted;

    /// @dev Nonempty selector lists also mark implementations as initialized.
    mapping(address capability => bytes4[] selectors) private _capabilitySelectors;

    /// @dev Sets the owner that initializes capability selectors and manages adapter-specific approvals.
    constructor(address newOwner) Ownable(newOwner) {}

    /// @inheritdoc ICapabilityRegistry
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

        emit InitCapability(capability, selectors);
    }

    /// @inheritdoc ICapabilityRegistry
    function setWhitelistedStatus(address adapter, address capability, bool status) public onlyOwner {
        if (status && !isInitialized(capability)) {
            revert CapabilityNotInitialized();
        }

        isWhitelisted[adapter][capability] = status;

        emit SetWhitelistedStatus(adapter, capability, status);
    }

    /// @inheritdoc ICapabilityRegistry
    function isInitialized(address capability) public view returns (bool initialized) {
        return _capabilitySelectors[capability].length != 0;
    }

    /// @inheritdoc ICapabilityRegistry
    function getCapabilitySelectors(address capability) public view returns (bytes4[] memory selectors) {
        return _capabilitySelectors[capability];
    }
}
