// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {Capability} from "./Capability.sol";

import {IBorrowCapability, IBorrowCapabilityConstants} from "../../interfaces/merkle_adapter/IBorrowCapability.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title BorrowCapability
/// @notice Contract for borrowing from the adapter with a fixed final health-factor query.
contract BorrowCapability is Capability, IBorrowCapabilityConstants, IBorrowCapability {
    using Address for address;

    /* STATE VARIABLES */

    /// @custom:storage-location erc7201:symbiotic.storage.BorrowCapability
    struct BorrowStorage {
        address borrowTarget;
        bytes4 borrowSelector;
        address borrowAsset;
        address healthFactorTarget;
        bytes healthFactorData;
        uint256 healthFactorOffset;
        uint256 minHealthFactor;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IBorrowCapability
    function initializeBorrow(InitParams calldata params) public onlyMyself {
        BorrowStorage storage $ = _getBorrowStorage();
        if ($.borrowTarget != address(0)) revert AlreadyInitialized();

        if (params.borrowTarget.code.length == 0) revert InvalidBorrowTarget();

        if (params.borrowAsset.code.length == 0) revert InvalidBorrowAsset();

        if (params.healthFactorTarget.code.length == 0) revert InvalidHealthFactorTarget();

        if (params.healthFactorData.length < 4) revert InvalidHealthFactorData();

        if (params.healthFactorOffset % 32 != 0) revert InvalidHealthFactorOffset();

        if (params.minHealthFactor == 0) revert InvalidMinHealthFactor();

        $.borrowTarget = params.borrowTarget;
        $.borrowSelector = params.borrowSelector;
        $.borrowAsset = params.borrowAsset;
        $.healthFactorTarget = params.healthFactorTarget;
        $.healthFactorData = params.healthFactorData;
        $.healthFactorOffset = params.healthFactorOffset;
        $.minHealthFactor = params.minHealthFactor;

        // Validate the fixed query; its minimum is enforced after each borrow.
        getHealthFactor();
        emit InitializeBorrow(params);
    }

    /// @inheritdoc IBorrowCapability
    function borrow(bytes calldata data) public onlyMyself returns (bytes memory result) {
        BorrowStorage storage $ = _getBorrowStorage();
        if ($.borrowTarget == address(0)) revert NotInitialized();

        if (data.length < 4 || bytes4(data[:4]) != $.borrowSelector) revert InvalidBorrowData();

        uint256 balanceBefore = IERC20($.borrowAsset).balanceOf(address(this));
        result = $.borrowTarget.functionCall(data);
        uint256 borrowedAssets = IERC20($.borrowAsset).balanceOf(address(this)) - balanceBefore;
        uint256 healthFactor = getHealthFactor();
        if (healthFactor < $.minHealthFactor) revert HealthFactorTooLow();

        emit Borrow(data, borrowedAssets, healthFactor);
    }

    /// @inheritdoc IBorrowCapability
    function setMinHealthFactor(uint256 newMinHealthFactor) public onlyMyself {
        BorrowStorage storage $ = _getBorrowStorage();
        if ($.borrowTarget == address(0)) revert NotInitialized();

        if (newMinHealthFactor == 0) revert InvalidMinHealthFactor();

        $.minHealthFactor = newMinHealthFactor;
        emit SetMinHealthFactor(newMinHealthFactor);
    }

    /// @inheritdoc IBorrowCapability
    function borrowTarget() public view returns (address) {
        return _getBorrowStorage().borrowTarget;
    }

    /// @inheritdoc IBorrowCapability
    function borrowSelector() public view returns (bytes4) {
        return _getBorrowStorage().borrowSelector;
    }

    /// @inheritdoc IBorrowCapability
    function borrowAsset() public view returns (address) {
        return _getBorrowStorage().borrowAsset;
    }

    /// @inheritdoc IBorrowCapability
    function healthFactorTarget() public view returns (address) {
        return _getBorrowStorage().healthFactorTarget;
    }

    /// @inheritdoc IBorrowCapability
    function healthFactorData() public view returns (bytes memory) {
        return _getBorrowStorage().healthFactorData;
    }

    /// @inheritdoc IBorrowCapability
    function healthFactorOffset() public view returns (uint256) {
        return _getBorrowStorage().healthFactorOffset;
    }

    /// @inheritdoc IBorrowCapability
    function minHealthFactor() public view returns (uint256) {
        return _getBorrowStorage().minHealthFactor;
    }

    /// @inheritdoc IBorrowCapability
    function getHealthFactor() public view returns (uint256 healthFactor) {
        BorrowStorage storage $ = _getBorrowStorage();
        if ($.borrowTarget == address(0)) revert NotInitialized();

        bytes memory response = $.healthFactorTarget.functionStaticCall($.healthFactorData);
        uint256 offset = $.healthFactorOffset;
        // forgefmt: disable-next-item
        if (
            response.length < 32 || response.length % 32 != 0 || offset > response.length - 32
        ) revert InvalidHealthFactorResponse();

        assembly ("memory-safe") {
            healthFactor := mload(add(add(response, 32), offset))
        }
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Resolves this capability's configuration in the calling adapter.
    function _getBorrowStorage() internal pure returns (BorrowStorage storage $) {
        assembly ("memory-safe") {
            $.slot := BORROW_STORAGE_LOCATION
        }
    }
}
