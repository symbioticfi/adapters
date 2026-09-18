// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Capability} from "./Capability.sol";

import {IBorrowCapability} from "../../interfaces/merkle_adapter/IBorrowCapability.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title BorrowCapability
/// @notice Contract for executing Merkle-approved lending calls and enforcing the curator's minimum health factor.
contract BorrowCapability layout at erc7201("symbiotic.storage.BorrowCapability") is Capability, IBorrowCapability {
    using Address for address;

    /* STATE VARIABLES */

    /// @inheritdoc IBorrowCapability
    mapping(bytes32 healthFactorId => uint256 minimum) public minHealthFactor;

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IBorrowCapability
    function borrow(address target, address healthFactorTarget, bytes calldata data, bytes calldata healthFactorData)
        public
        onlyMyself
        returns (bytes memory result)
    {
        uint256 minimum = minHealthFactor[keccak256(abi.encode(healthFactorTarget, healthFactorData))];
        if (minimum == 0) revert MinHealthFactorNotSet();

        result = target.functionCall(data);
        uint256 value = getHealthFactor(healthFactorTarget, healthFactorData);
        if (value < minimum) revert HealthFactorTooLow();

        emit Borrow(target, healthFactorTarget, data, healthFactorData, value);
    }

    /// @inheritdoc IBorrowCapability
    function setHealthFactor(bytes32 healthFactorId, uint256 newMinHealthFactor) public onlyMyself {
        if (newMinHealthFactor == 0) revert InvalidMinHealthFactor();

        minHealthFactor[healthFactorId] = newMinHealthFactor;
        emit SetHealthFactor(healthFactorId, newMinHealthFactor);
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
}
