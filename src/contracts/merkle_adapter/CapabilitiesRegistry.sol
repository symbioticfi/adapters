// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {ICapabilitiesRegistryProposer} from "../../interfaces/merkle_adapter/ICapabilitiesRegistryProposer.sol";
import {ICapabilitiesRegistry} from "../../interfaces/merkle_adapter/ICapabilitiesRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CapabilitiesRegistry
/// @notice Curator-owned registry contract that accepts exact protocol-proposed code separately for each adapter.
contract CapabilitiesRegistry is Ownable, ICapabilitiesRegistry {
    /* IMMUTABLES */

    /// @inheritdoc ICapabilitiesRegistry
    address public immutable PROPOSER;

    /* STATE VARIABLES */

    /// @inheritdoc ICapabilitiesRegistry
    mapping(address capability => bytes32 codeHash) public capabilityCodeHash;

    /// @inheritdoc ICapabilitiesRegistry
    mapping(address adapter => mapping(address capability => bool accepted)) public isAccepted;

    /// @dev Local immutable manifests keep removal independent of the proposer and its current status.
    mapping(address capability => bytes4[] selectors) private _capabilitySelectors;

    /* CONSTRUCTOR */

    /// @dev Sets the curator owner and the fixed protocol proposer whose code it can accept.
    constructor(address newOwner, address newProposer) Ownable(newOwner) {
        PROPOSER = newProposer;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ICapabilitiesRegistry
    function acceptCapability(address adapter, address capability) public onlyOwner {
        if (!isInitialized(capability)) {
            _initCapability(capability, ICapabilitiesRegistryProposer(PROPOSER).getCapabilitySelectors(capability));
        }
        _setWhitelistedStatus(adapter, capability, true);
    }

    /// @inheritdoc ICapabilitiesRegistry
    function initCapability(address capability, bytes4[] calldata selectors) public onlyOwner {
        _initCapability(capability, selectors);
    }

    /// @inheritdoc ICapabilitiesRegistry
    function setWhitelistedStatus(address adapter, address capability, bool newStatus) public onlyOwner {
        _setWhitelistedStatus(adapter, capability, newStatus);
    }

    /// @inheritdoc ICapabilitiesRegistry
    function isWhitelisted(address adapter, address capability) public view returns (bool status) {
        return isAccepted[adapter][capability] && capability.codehash == capabilityCodeHash[capability]
            && ICapabilitiesRegistryProposer(PROPOSER).isProposed(address(this), adapter, capability);
    }

    /// @inheritdoc ICapabilitiesRegistry
    function isInitialized(address capability) public view returns (bool initialized) {
        return _capabilitySelectors[capability].length != 0;
    }

    /// @inheritdoc ICapabilitiesRegistry
    function getCapabilitySelectors(address capability) public view returns (bytes4[] memory selectors) {
        return _capabilitySelectors[capability];
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Validates the exact protocol manifest before copying it into curator-owned immutable storage.
    function _initCapability(address capability, bytes4[] memory selectors) internal {
        if (isInitialized(capability)) revert CapabilityAlreadyInitialized();

        bytes32 codeHash = ICapabilitiesRegistryProposer(PROPOSER).capabilityCodeHash(capability);
        if (codeHash == bytes32(0) || capability.codehash != codeHash) revert InvalidCapabilityCode();

        if (
            keccak256(abi.encode(selectors))
                != keccak256(abi.encode(ICapabilitiesRegistryProposer(PROPOSER).getCapabilitySelectors(capability)))
        ) revert InvalidCapabilitySelectors();

        _capabilitySelectors[capability] = selectors;
        capabilityCodeHash[capability] = codeHash;
        emit InitCapability(capability, codeHash, selectors);
    }

    /// @dev Combines explicit curator acceptance with the current protocol proposal for this exact pair.
    function _setWhitelistedStatus(address adapter, address capability, bool newStatus) internal {
        if (newStatus) {
            if (!isInitialized(capability)) revert CapabilityNotInitialized();

            if (!ICapabilitiesRegistryProposer(PROPOSER).isProposed(address(this), adapter, capability)) {
                revert CapabilityNotProposed();
            }

            if (capability.codehash != capabilityCodeHash[capability]) revert InvalidCapabilityCode();
        }
        isAccepted[adapter][capability] = newStatus;
        emit SetWhitelistedStatus(adapter, capability, newStatus);
    }
}
