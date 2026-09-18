// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {Capability} from "./Capability.sol";

import {IBorrowCapability, IBorrowCapabilityConstants} from "../../interfaces/merkle_adapter/IBorrowCapability.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title BorrowCapability
/// @notice Contract for executing Merkle-approved lending calls and enforcing the curator's minimum health factor.
contract BorrowCapability is Capability, IBorrowCapabilityConstants, IBorrowCapability {
    using Address for address;

    /* STATE VARIABLES */

    /// @custom:storage-location erc7201:symbiotic.storage.BorrowCapability
    struct BorrowStorage {
        mapping(bytes32 healthFactorId => uint256 minimum) minHealthFactor;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IBorrowCapability
    function borrow(address target, address healthFactorTarget, bytes calldata data, bytes calldata healthFactorData)
        public
        onlyMyself
        returns (bytes memory result)
    {
        uint256 minimum = minHealthFactor(keccak256(abi.encode(healthFactorTarget, healthFactorData)));
        if (minimum == 0) revert MinHealthFactorNotSet();

        result = target.functionCall(data);
        uint256 value = getHealthFactor(healthFactorTarget, healthFactorData);
        if (value < minimum) revert HealthFactorTooLow();

        emit Borrow(target, healthFactorTarget, data, healthFactorData, value);
    }

    /// @inheritdoc IBorrowCapability
    function setHealthFactor(bytes32 healthFactorId, uint256 newMinHealthFactor) public onlyMyself {
        if (newMinHealthFactor == 0) revert InvalidMinHealthFactor();

        _getBorrowStorage().minHealthFactor[healthFactorId] = newMinHealthFactor;
        emit SetHealthFactor(healthFactorId, newMinHealthFactor);
    }

    /// @inheritdoc IBorrowCapability
    function minHealthFactor(bytes32 healthFactorId) public view returns (uint256) {
        return _getBorrowStorage().minHealthFactor[healthFactorId];
    }

    /// @inheritdoc IBorrowCapability
    function getHealthFactor(address healthFactorTarget, bytes calldata healthFactorData)
        public
        view
        returns (uint256)
    {
        bytes memory result = healthFactorTarget.functionStaticCall(healthFactorData);
        if (result.length != 32) revert InvalidHealthFactorResponse();

        return abi.decode(result, (uint256));
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Resolves the calling adapter's independently configured health-call minimums.
    function _getBorrowStorage() internal pure returns (BorrowStorage storage $) {
        assembly ("memory-safe") {
            $.slot := BORROW_STORAGE_LOCATION
        }
    }
}
