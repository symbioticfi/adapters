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

    /* IMMUTABLES */

    /// @inheritdoc IBorrowCapability
    address public immutable borrowTarget;

    /// @inheritdoc IBorrowCapability
    bytes4 public immutable borrowSelector;

    /// @inheritdoc IBorrowCapability
    address public immutable borrowAsset;

    /// @inheritdoc IBorrowCapability
    address public immutable healthFactorTarget;

    /// @inheritdoc IBorrowCapability
    uint256 public immutable healthFactorOffset;

    address private immutable _implementation;

    /* STATE VARIABLES */

    // Dynamic calldata stays in implementation storage and is read there even during delegatecall.
    bytes private _healthFactorData;

    /// @custom:storage-location erc7201:symbiotic.storage.BorrowCapability
    struct BorrowStorage {
        uint256 minHealthFactor;
    }

    /* CONSTRUCTOR */

    constructor(ConstructorParams memory newParams) {
        borrowTarget = newParams.borrowTarget;
        borrowSelector = newParams.borrowSelector;
        borrowAsset = newParams.borrowAsset;
        healthFactorTarget = newParams.healthFactorTarget;
        healthFactorOffset = newParams.healthFactorOffset;
        _healthFactorData = newParams.healthFactorData;
        _implementation = address(this);
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IBorrowCapability
    function borrow(bytes calldata data) public onlyMyself returns (bytes memory result) {
        BorrowStorage storage $ = _getBorrowStorage();
        if ($.minHealthFactor == 0) revert MinHealthFactorNotSet();

        if (data.length < 4 || bytes4(data[:4]) != borrowSelector) revert InvalidBorrowData();

        uint256 balanceBefore = IERC20(borrowAsset).balanceOf(address(this));
        result = borrowTarget.functionCall(data);
        uint256 borrowedAssets = IERC20(borrowAsset).balanceOf(address(this)) - balanceBefore;
        uint256 healthFactor = getHealthFactor();
        if (healthFactor < $.minHealthFactor) revert HealthFactorTooLow();

        emit Borrow(data, borrowedAssets, healthFactor);
    }

    /// @inheritdoc IBorrowCapability
    function setMinHealthFactor(uint256 newMinHealthFactor) public onlyMyself {
        if (newMinHealthFactor == 0) revert InvalidMinHealthFactor();

        _getBorrowStorage().minHealthFactor = newMinHealthFactor;
        emit SetMinHealthFactor(newMinHealthFactor);
    }

    /// @inheritdoc IBorrowCapability
    function healthFactorData() public view returns (bytes memory) {
        if (address(this) == _implementation) return _healthFactorData;

        return IBorrowCapability(_implementation).healthFactorData();
    }

    /// @inheritdoc IBorrowCapability
    function minHealthFactor() public view returns (uint256) {
        return _getBorrowStorage().minHealthFactor;
    }

    /// @inheritdoc IBorrowCapability
    function getHealthFactor() public view returns (uint256 healthFactor) {
        bytes memory response = healthFactorTarget.functionStaticCall(healthFactorData());
        uint256 offset = healthFactorOffset;
        if (response.length < 32 || response.length % 32 != 0 || offset % 32 != 0 || offset > response.length - 32) {
            revert InvalidHealthFactorResponse();
        }

        assembly ("memory-safe") {
            healthFactor := mload(add(add(response, 32), offset))
        }
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Resolves the curator's minimum in the calling adapter.
    function _getBorrowStorage() internal pure returns (BorrowStorage storage $) {
        assembly ("memory-safe") {
            $.slot := BORROW_STORAGE_LOCATION
        }
    }
}
