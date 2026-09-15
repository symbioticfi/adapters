// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {IBorrowCapability} from "src/interfaces/merkle_adapter/IBorrowCapability.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";

/// @title BorrowCapability
/// @notice Adapter-bound borrowing guarded by a fixed final health-factor query.
contract BorrowCapability is MigratableEntity, IBorrowCapability {
    using Address for address;
    using SafeERC20 for IERC20;

    /// @inheritdoc IBorrowCapability
    address public adapter;

    /// @inheritdoc IBorrowCapability
    address public borrowTarget;

    /// @inheritdoc IBorrowCapability
    bytes4 public borrowSelector;

    /// @inheritdoc IBorrowCapability
    address public borrowAsset;

    /// @inheritdoc IBorrowCapability
    address public healthFactorTarget;

    /// @inheritdoc IBorrowCapability
    bytes public healthFactorData;

    /// @inheritdoc IBorrowCapability
    uint256 public healthFactorOffset;

    /// @inheritdoc IBorrowCapability
    uint256 public minHealthFactor;

    /// @dev Restricts borrowing and risk configuration to the bound adapter's authorized call path.
    modifier onlyAdapter() {
        if (msg.sender != adapter) {
            revert InvalidCaller();
        }
        _;
    }

    /// @dev Initializes the factory used for this implementation's proxy lifecycle.
    constructor(address factory) MigratableEntity(factory) {}

    /// @inheritdoc IBorrowCapability
    function borrow(bytes calldata data) external nonReentrant onlyAdapter returns (bytes memory result) {
        if (data.length < 4 || bytes4(data[:4]) != borrowSelector) {
            revert InvalidBorrowData();
        }

        IERC20 asset = IERC20(borrowAsset);
        uint256 minimum = minHealthFactor;
        uint256 balanceBefore = asset.balanceOf(address(this));
        result = borrowTarget.functionCall(data);
        uint256 forwardedAssets = asset.balanceOf(address(this)) - balanceBefore;
        if (forwardedAssets != 0) {
            asset.safeTransfer(adapter, forwardedAssets);
        }

        // Check the completed flow, including any effects of forwarding the borrowed assets.
        uint256 healthFactor = getHealthFactor();
        if (healthFactor < minimum) {
            revert HealthFactorTooLow(healthFactor, minimum);
        }
        emit Borrow(data, forwardedAssets, healthFactor);
    }

    /// @inheritdoc IBorrowCapability
    function setMinHealthFactor(uint256 minHealthFactor_) external nonReentrant onlyAdapter {
        if (minHealthFactor_ == 0) {
            revert InvalidMinHealthFactor();
        }
        minHealthFactor = minHealthFactor_;
        emit SetMinHealthFactor(minHealthFactor_);
    }

    /// @inheritdoc IBorrowCapability
    function getHealthFactor() public view returns (uint256 healthFactor) {
        bytes memory response = healthFactorTarget.functionStaticCall(healthFactorData);
        uint256 offset = healthFactorOffset;
        if (response.length < 32 || response.length % 32 != 0 || offset > response.length - 32) {
            revert InvalidHealthFactorResponse();
        }
        assembly ("memory-safe") {
            healthFactor := mload(add(add(response, 32), offset))
        }
    }

    /// @dev Permanently binds the protocol function and account query, validating their configuration.
    function _initialize(uint64, address, bytes memory data) internal override {
        InitParams memory params = abi.decode(data, (InitParams));
        if (params.adapter == address(0)) {
            revert InvalidAdapter();
        }
        if (params.borrowTarget.code.length == 0) {
            revert InvalidBorrowTarget();
        }
        if (params.borrowAsset.code.length == 0) {
            revert InvalidBorrowAsset();
        }
        if (params.healthFactorTarget.code.length == 0) {
            revert InvalidHealthFactorTarget();
        }
        if (params.healthFactorData.length < 4) {
            revert InvalidHealthFactorData();
        }
        if (params.healthFactorOffset % 32 != 0) {
            revert InvalidHealthFactorOffset();
        }
        if (params.minHealthFactor == 0) {
            revert InvalidMinHealthFactor();
        }

        adapter = params.adapter;
        borrowTarget = params.borrowTarget;
        borrowSelector = params.borrowSelector;
        borrowAsset = params.borrowAsset;
        healthFactorTarget = params.healthFactorTarget;
        healthFactorData = params.healthFactorData;
        healthFactorOffset = params.healthFactorOffset;
        minHealthFactor = params.minHealthFactor;

        // An existing account may be below the floor until collateral is supplied or debt is repaid.
        // Initialization checks the fixed query's validity; borrowing enforces the minimum.
        getHealthFactor();
    }

    /// @dev Allows state-preserving upgrades without replacing the fixed borrow or health configuration.
    function _migrate(uint64, uint64, bytes calldata data) internal pure override {
        if (data.length != 0) {
            revert InvalidMigrationData();
        }
    }
}
