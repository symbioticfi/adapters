// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.37;

import {IAssetRateLimits} from "../../../interfaces/merkle_adapter/IAssetRateLimits.sol";

/**
 * @title AssetRateLimits
 * @notice Library for fixed-period asset budgets shared by adapter actions.
 */
library AssetRateLimits {
    /* INTERNAL FUNCTIONS */

    /**
     * @dev Updates configuration without granting a fresh budget during an active period.
     */
    function configure(IAssetRateLimits.AssetLimit storage limit, uint256 newMaxAssets, uint256 newDuration) internal {
        if (newDuration == 0) revert IAssetRateLimits.InvalidDuration();

        if (limit.duration == 0) {
            limit.periodStart = block.timestamp;
        } else {
            _rollPeriod(limit);
            if (newDuration != limit.duration) {
                limit.periodStart = block.timestamp;
            }
        }
        limit.maxAssets = newMaxAssets;
        limit.duration = newDuration;
    }

    /**
     * @dev Charges funding before external transfers; an outer revert restores all usage.
     */
    function consume(IAssetRateLimits.AssetLimit storage limit, uint256 assets) internal {
        if (limit.maxAssets == 0 || limit.duration == 0) revert IAssetRateLimits.UnconfiguredAsset();

        _rollPeriod(limit);
        if (limit.spent > limit.maxAssets || assets > limit.maxAssets - limit.spent) {
            revert IAssetRateLimits.AssetLimitExceeded();
        }

        limit.spent += assets;
    }

    /**
     * @dev Computes the current capacity without mutating an expired period.
     */
    function remaining(IAssetRateLimits.AssetLimit storage limit) internal view returns (uint256) {
        if (limit.maxAssets == 0 || limit.duration == 0) {
            return 0;
        }
        if (block.timestamp - limit.periodStart >= limit.duration) {
            return limit.maxAssets;
        }
        return limit.spent >= limit.maxAssets ? 0 : limit.maxAssets - limit.spent;
    }

    /* PRIVATE FUNCTIONS */

    /**
     * @dev Advances whole periods without accruing unused capacity or drifting the period boundaries.
     */
    function _rollPeriod(IAssetRateLimits.AssetLimit storage limit) private {
        uint256 periods = (block.timestamp - limit.periodStart) / limit.duration;
        if (periods != 0) {
            limit.periodStart += periods * limit.duration;
            limit.spent = 0;
        }
    }
}
