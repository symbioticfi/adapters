// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";
import {AssetRateLimits} from "src/contracts/merkle-adapter/libraries/AssetRateLimits.sol";
import {IAssetRateLimits} from "src/interfaces/merkle-adapter/IAssetRateLimits.sol";

contract AssetRateLimitsTest is Test {
    AssetRateLimitsHarness internal limiter;

    function setUp() public {
        vm.warp(1000);
        limiter = new AssetRateLimitsHarness();
    }

    function test_UnconfiguredAndDisabledAssetsCannotSpend() public {
        assertEq(limiter.remaining(), 0);
        vm.expectRevert(IAssetRateLimits.UnconfiguredAsset.selector);
        limiter.consume(0);
        limiter.configure(0, 100);
        assertEq(limiter.remaining(), 0);
        vm.expectRevert(IAssetRateLimits.UnconfiguredAsset.selector);
        limiter.consume(1);
    }

    function test_ZeroDurationRevertsWithoutChangingBudget() public {
        limiter.configure(100, 100);
        limiter.consume(40);
        vm.expectRevert(IAssetRateLimits.InvalidDuration.selector);
        limiter.configure(200, 0);
        assertEq(limiter.remaining(), 60);
    }

    function test_ReconfigurationAndDisableDoNotResetActiveUsage() public {
        limiter.configure(100, 100);
        limiter.consume(60);
        vm.warp(1020);
        limiter.configure(100, 100);
        assertEq(limiter.remaining(), 40);
        limiter.configure(0, 100);
        limiter.configure(100, 100);
        assertEq(limiter.remaining(), 40);
        limiter.configure(50, 100);
        assertEq(limiter.remaining(), 0);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        limiter.consume(0);
        limiter.configure(80, 100);
        assertEq(limiter.remaining(), 20);
        (,, uint256 start, uint256 spent) = limiter.limit();
        assertEq(start, 1000);
        assertEq(spent, 60);
    }

    function test_ShorterDurationCarriesSpentIntoNewPeriod() public {
        limiter.configure(100, 100);
        limiter.consume(60);
        vm.warp(1090);
        limiter.configure(100, 10);
        assertEq(limiter.remaining(), 40);
        vm.warp(1099);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        limiter.consume(41);
        vm.warp(1100);
        assertEq(limiter.remaining(), 100);
        limiter.consume(100);
        assertEq(limiter.remaining(), 0);
    }

    function test_LongerDurationCarriesSpentWithoutPrematureReset() public {
        limiter.configure(100, 100);
        limiter.consume(100);
        vm.warp(1050);
        limiter.configure(100, 200);
        vm.warp(1100);
        assertEq(limiter.remaining(), 0);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        limiter.consume(1);
        vm.warp(1250);
        limiter.consume(100);
        assertEq(limiter.remaining(), 0);
    }

    function test_ExpiredReconfigurationDiscardsOldUsage() public {
        limiter.configure(100, 100);
        limiter.consume(100);
        vm.warp(1100);
        limiter.configure(50, 200);
        assertEq(limiter.remaining(), 50);
        limiter.consume(50);
        (,, uint256 start, uint256 spent) = limiter.limit();
        assertEq(start, 1100);
        assertEq(spent, 50);
    }

    function test_PeriodBoundaryResetsOnceAndDoesNotAccumulateCapacity() public {
        limiter.configure(100, 100);
        limiter.consume(100);
        vm.warp(1099);
        assertEq(limiter.remaining(), 0);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        limiter.consume(1);
        vm.warp(1355);
        assertEq(limiter.remaining(), 100);
        (,, uint256 oldStart, uint256 oldSpent) = limiter.limit();
        assertEq(oldStart, 1000);
        assertEq(oldSpent, 100);
        limiter.consume(70);
        (,, uint256 start, uint256 spent) = limiter.limit();
        assertEq(start, 1300);
        assertEq(spent, 70);
        vm.warp(1399);
        assertEq(limiter.remaining(), 30);
        vm.warp(1400);
        assertEq(limiter.remaining(), 100);
    }

    function test_MaximumUintBudgetAndDurationDoNotOverflow() public {
        limiter.configure(type(uint256).max, type(uint256).max);
        limiter.consume(type(uint256).max - 1);
        assertEq(limiter.remaining(), 1);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        limiter.consume(2);
        limiter.consume(1);
        assertEq(limiter.remaining(), 0);
    }

    /// @dev Independent absolute-period accounting catches overspending across a sequence of time jumps.
    function testFuzz_AggregateSpendingNeverExceedsPeriodBudget(
        uint256 maximum,
        uint256 duration,
        uint256[16] memory amounts,
        uint256[16] memory delays
    ) public {
        maximum = bound(maximum, 1, 1e24);
        duration = bound(duration, 1, 30 days);
        limiter.configure(maximum, duration);
        uint256 time = 1000;
        uint256 period;
        uint256 spent;
        for (uint256 i; i < amounts.length; ++i) {
            time += delays[i] % (duration * 2);
            vm.warp(time);
            uint256 nextPeriod = (time - 1000) / duration;
            if (nextPeriod != period) {
                period = nextPeriod;
                spent = 0;
            }
            uint256 amount = amounts[i] % (maximum * 2 + 1);
            if (amount > maximum - spent) {
                vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
                limiter.consume(amount);
            } else {
                limiter.consume(amount);
                spent += amount;
            }
            assertEq(limiter.remaining(), maximum - spent);
        }
    }
}

/// @dev Exposes the production library without adding token or authorization behavior.
contract AssetRateLimitsHarness {
    using AssetRateLimits for IAssetRateLimits.AssetLimit;
    IAssetRateLimits.AssetLimit public limit;

    function configure(uint256 maximum, uint256 duration) external {
        limit.configure(maximum, duration);
    }

    function consume(uint256 assets) external {
        limit.consume(assets);
    }

    function remaining() external view returns (uint256) {
        return limit.remaining();
    }
}
