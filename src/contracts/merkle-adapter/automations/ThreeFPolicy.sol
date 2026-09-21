// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {AssetRateLimits} from "../libraries/AssetRateLimits.sol";

import {IAssetRateLimits} from "../../../interfaces/merkle-adapter/IAssetRateLimits.sol";
import {IThreeFPolicy} from "../../../interfaces/merkle-adapter/automations/IThreeFPolicy.sol";
import {YIELD_PRECISION} from "../../../interfaces/3f-adapter/ThreeFTypes.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {Multicallable} from "@symbioticfi/core/src/contracts/common/Multicallable.sol";

/// @title ThreeFPolicy
/// @notice Migratable contract storing one curator-controlled request funding policy for its consumer.
contract ThreeFPolicy is MigratableEntity, Multicallable, IThreeFPolicy {
    using AssetRateLimits for IAssetRateLimits.AssetLimit;
    using Math for uint256;

    /* STATE VARIABLES */

    /// @inheritdoc IThreeFPolicy
    address public consumer;

    /// @inheritdoc IThreeFPolicy
    mapping(address asset => uint256) public minYieldPerRequest;

    /// @inheritdoc IAssetRateLimits
    mapping(address asset => IAssetRateLimits.AssetLimit) public assetLimits;

    /* CONSTRUCTOR */

    constructor(address newFactory) MigratableEntity(newFactory) {}

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IThreeFPolicy
    function setConsumer(address newConsumer) public onlyOwner {
        consumer = newConsumer;
        emit SetConsumer(newConsumer);
    }

    /// @inheritdoc IAssetRateLimits
    function setMaxAssetsPerDuration(address asset, uint256 newMaxAssets, uint256 newDuration) public onlyOwner {
        assetLimits[asset].configure(newMaxAssets, newDuration);
        emit SetMaxAssetsPerDuration(asset, newMaxAssets, newDuration);
    }

    /// @inheritdoc IThreeFPolicy
    function setMinYieldPerRequest(address asset, uint256 newMinimum) public onlyOwner {
        minYieldPerRequest[asset] = newMinimum;
        emit SetMinYieldPerRequest(asset, newMinimum);
    }

    /// @inheritdoc IAssetRateLimits
    function remainingAssets(address asset) public view returns (uint256) {
        return assetLimits[asset].remaining();
    }

    /// @inheritdoc IThreeFPolicy
    function consume(address asset, uint256 assets, uint256 yieldAssets) public {
        if (consumer != msg.sender) revert InvalidCaller();
        if (assets == 0) revert InvalidAssets();
        if (yieldAssets.mulDiv(YIELD_PRECISION, assets) < minYieldPerRequest[asset]) revert TooLowYield();
        assetLimits[asset].consume(assets);
        emit Consume(asset, assets);
    }

    /* INTERNAL FUNCTIONS */

    function _initialize(uint64, address, bytes memory data) internal override {
        consumer = abi.decode(data, (address));
    }

    /// @dev Budgets, minimums and the current period's usage are storage, so migration carries them over.
    function _migrate(uint64, uint64, bytes calldata data) internal pure override {
        if (data.length > 0) revert InvalidMigrationData();
    }
}
