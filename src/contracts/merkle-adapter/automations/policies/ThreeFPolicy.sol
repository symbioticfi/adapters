// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {AssetRateLimits} from "../../libraries/AssetRateLimits.sol";

import {IThreeFPolicy} from "../../../../interfaces/merkle-adapter/automations/policies/IThreeFPolicy.sol";
import {YIELD_PRECISION} from "../../../../interfaces/3f-adapter/ThreeFTypes.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {Multicallable} from "@symbioticfi/core/src/contracts/common/Multicallable.sol";

/// @title ThreeFPolicy
/// @notice Migratable contract storing one curator-controlled request funding policy for its consumer.
contract ThreeFPolicy is MigratableEntity, Multicallable, IThreeFPolicy {
    using AssetRateLimits for AssetRateLimits.AssetLimit;

    /* STATE VARIABLES */

    /// @inheritdoc IThreeFPolicy
    address public consumer;

    /// @inheritdoc IThreeFPolicy
    mapping(address asset => uint256) public minYieldPerRequest;

    /// @inheritdoc IThreeFPolicy
    mapping(address asset => AssetRateLimits.AssetLimit) public assetLimits;

    /* CONSTRUCTOR */

    constructor(address newFactory) MigratableEntity(newFactory) {}

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IThreeFPolicy
    function setConsumer(address newConsumer) public onlyOwner {
        consumer = newConsumer;
        emit SetConsumer(newConsumer);
    }

    /// @inheritdoc IThreeFPolicy
    function setMaxAssetsPerDuration(address asset, uint256 newMaxAssets, uint48 newDuration) public onlyOwner {
        assetLimits[asset].configure(newMaxAssets, newDuration);
        emit SetMaxAssetsPerDuration(asset, newMaxAssets, newDuration);
    }

    /// @inheritdoc IThreeFPolicy
    function setMinYieldPerRequest(address asset, uint256 newMinimum) public onlyOwner {
        minYieldPerRequest[asset] = newMinimum;
        emit SetMinYieldPerRequest(asset, newMinimum);
    }

    /// @inheritdoc IThreeFPolicy
    function remainingAssets(address asset) public view returns (uint256) {
        return assetLimits[asset].remaining();
    }

    /// @inheritdoc IThreeFPolicy
    function consume(address asset, uint256 assets, uint256 yieldAssets) public {
        if (consumer != msg.sender) revert InvalidCaller();
        if (assets == 0) revert InvalidAssets();
        if (yieldAssets * YIELD_PRECISION / assets < minYieldPerRequest[asset]) revert TooLowYield();
        assetLimits[asset].consume(assets);
        emit Consume(asset, assets);
    }

    /* INTERNAL FUNCTIONS */

    function _initialize(uint64, address, bytes memory data) internal override {
        consumer = abi.decode(data, (address));
    }
}
