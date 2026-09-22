// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.4;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title AssetRateLimits
 * @notice Library for fixed-period asset budgets shared by adapter actions.
 */
library AssetRateLimits {
    using Math for uint256;

    /* ERRORS */

    /// @notice Raised when an operation exceeds the remaining asset budget.
    error AssetLimitExceeded();

    /// @notice Raised when a configured period has zero duration.
    error InvalidDuration();

    /// @notice Raised when an asset has no enabled funding budget.
    error UnconfiguredAsset();

    /* STRUCTS */

    /**
     * @notice Funding budget and cumulative usage for one asset's fixed period.
     * @param maxAssets Maximum funding-token base units per period; zero disables spending.
     * @param duration Period length in seconds; nonzero after configuration.
     * @param periodStart Start of the last recorded period.
     * @param spent Funding-token base units spent in that period.
     */
    struct AssetLimit {
        uint256 maxAssets;
        uint256 duration;
        uint256 periodStart;
        uint256 spent;
    }

    /* INTERNAL FUNCTIONS */

    /**
     * @dev Updates configuration without granting a fresh budget during an active period.
     */
    function configure(AssetLimit storage limit, uint256 newMaxAssets, uint256 newDuration) internal {
        if (newDuration == 0) revert InvalidDuration();

        if (limit.duration > 0) _rollPeriod(limit);
        if (newDuration != limit.duration) limit.periodStart = block.timestamp;
        limit.maxAssets = newMaxAssets;
        limit.duration = newDuration;
    }

    /**
     * @dev Charges funding before external transfers; an outer revert restores all usage.
     */
    function consume(AssetLimit storage limit, uint256 assets) internal {
        if (limit.maxAssets == 0) revert UnconfiguredAsset();

        _rollPeriod(limit);

        limit.spent += assets;
        if (limit.spent > limit.maxAssets) revert AssetLimitExceeded();
    }

    /**
     * @dev Computes the current capacity without mutating an expired period.
     */
    function remaining(AssetLimit storage limit) internal view returns (uint256) {
        if (limit.maxAssets == 0) return 0;
        return block.timestamp - limit.periodStart < limit.duration
            ? limit.maxAssets.saturatingSub(limit.spent)
            : limit.maxAssets;
    }

    /* PRIVATE FUNCTIONS */

    /**
     * @dev Advances whole periods without accruing unused capacity or drifting the period boundaries.
     */
    function _rollPeriod(AssetLimit storage limit) private {
        uint256 periods = (block.timestamp - limit.periodStart) / limit.duration;
        if (periods > 0) {
            limit.periodStart += periods * limit.duration;
            limit.spent = 0;
        }
    }
}
