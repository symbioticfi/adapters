// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {AssetRateLimits} from "../libraries/AssetRateLimits.sol";

import {IAssetRateLimits} from "../../../interfaces/merkle-adapter/IAssetRateLimits.sol";
import {IThreeFPolicy} from "../../../interfaces/merkle-adapter/automations/IThreeFPolicy.sol";
import {YIELD_PRECISION} from "../../../interfaces/3f-adapter/ThreeFTypes.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Multicallable} from "@symbioticfi/core/src/contracts/common/Multicallable.sol";

/// @title ThreeFPolicy
/// @notice Contract storing one executor's curator-controlled request funding policy.
contract ThreeFPolicy is Multicallable, Ownable, IThreeFPolicy {
    using AssetRateLimits for IAssetRateLimits.AssetLimit;
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc IThreeFPolicy
    address public immutable executor;

    /* STATE VARIABLES */

    /// @inheritdoc IThreeFPolicy
    uint256 public minYieldPerRequest;

    /// @inheritdoc IThreeFPolicy
    IAssetRateLimits.AssetLimit public assetLimit;

    /* CONSTRUCTOR */

    constructor(address newOwner, address newExecutor) Ownable(newOwner) {
        executor = newExecutor;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IThreeFPolicy
    function setMaxAssetsPerDuration(uint256 newMaxAssets, uint256 newDuration) public onlyOwner {
        assetLimit.configure(newMaxAssets, newDuration);
        emit SetMaxAssetsPerDuration(newMaxAssets, newDuration);
    }

    /// @inheritdoc IThreeFPolicy
    function setMinYieldPerRequest(uint256 newMinimum) public onlyOwner {
        minYieldPerRequest = newMinimum;
        emit SetMinYieldPerRequest(newMinimum);
    }

    /// @inheritdoc IThreeFPolicy
    function remainingAssets() public view returns (uint256) {
        return assetLimit.remaining();
    }

    /// @inheritdoc IThreeFPolicy
    function consume(uint256 assets, uint256 yieldAssets) public {
        if (executor != msg.sender) revert InvalidCaller();
        if (yieldAssets.mulDiv(YIELD_PRECISION, assets) < minYieldPerRequest) revert TooLowYield();
        assetLimit.consume(assets);
        emit Consume(assets);
    }
}
