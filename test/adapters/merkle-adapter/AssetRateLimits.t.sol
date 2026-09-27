// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {AssetRateLimits} from "src/contracts/merkle-adapter/libraries/AssetRateLimits.sol";

contract AssetRateLimitsTest is Test {
    AssetRateLimitsHarness internal limiter;

    function setUp() public {
        vm.warp(1000);
        limiter = new AssetRateLimitsHarness();
    }

    function test_TimestampOverflowCannotTruncateTheBudgetPeriod() public {
        uint256 timestamp = uint256(type(uint48).max) + 1;
        vm.warp(timestamp);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(48), timestamp));
        limiter.configure(100, 1);
        assertEq(limiter.remaining(), 0);
    }

    /// forge-config: default.isolate = true
    function test_UnconfiguredAndDisabledAssetsCannotSpend() public {
        uint256 remaining = limiter.remaining();
        vm.snapshotGasLastCall("AssetRateLimits", "remainingUnconfigured");
        assertEq(remaining, 0);
        vm.expectRevert(AssetRateLimits.UnconfiguredAsset.selector);
        vm.startSnapshotGas("AssetRateLimits", "consumeUnconfigured");
        limiter.consume(0);
        vm.stopSnapshotGas("AssetRateLimits", "consumeUnconfigured");
        limiter.configure(0, 100);
        assertEq(limiter.remaining(), 0);
        vm.expectRevert(AssetRateLimits.UnconfiguredAsset.selector);
        limiter.consume(1);
    }

    /// forge-config: default.isolate = true
    function test_ZeroDurationRevertsWithoutChangingBudget() public {
        limiter.configure(100, 100);
        limiter.consume(40);
        vm.expectRevert(AssetRateLimits.InvalidDuration.selector);
        vm.startSnapshotGas("AssetRateLimits", "configureInvalidDuration");
        limiter.configure(200, 0);
        vm.stopSnapshotGas("AssetRateLimits", "configureInvalidDuration");
        assertEq(limiter.remaining(), 60);
    }

    /// forge-config: default.isolate = true
    function test_ReconfigurationAndDisableDoNotResetActiveUsage() public {
        limiter.configure(100, 100);
        vm.snapshotGasLastCall("AssetRateLimits", "configure");
        limiter.consume(60);
        vm.snapshotGasLastCall("AssetRateLimits", "consume");
        vm.warp(1020);
        limiter.configure(100, 100);
        vm.snapshotGasLastCall("AssetRateLimits", "configureSameDuration");
        assertEq(limiter.remaining(), 40);
        limiter.configure(0, 100);
        vm.snapshotGasLastCall("AssetRateLimits", "configureDisable");
        limiter.configure(100, 100);
        vm.snapshotGasLastCall("AssetRateLimits", "configureReenable");
        assertEq(limiter.remaining(), 40);
        limiter.configure(50, 100);
        uint256 remaining = limiter.remaining();
        vm.snapshotGasLastCall("AssetRateLimits", "remainingExhausted");
        assertEq(remaining, 0);
        vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
        vm.startSnapshotGas("AssetRateLimits", "consumeBudgetExceeded");
        limiter.consume(0);
        vm.stopSnapshotGas("AssetRateLimits", "consumeBudgetExceeded");
        limiter.configure(80, 100);
        remaining = limiter.remaining();
        vm.snapshotGasLastCall("AssetRateLimits", "remaining");
        assertEq(remaining, 20);
        (,, uint256 start, uint256 spent) = limiter.limit();
        assertEq(start, 1000);
        assertEq(spent, 60);
    }

    /// forge-config: default.isolate = true
    function test_ShorterDurationCarriesSpentIntoNewPeriod() public {
        limiter.configure(100, 100);
        limiter.consume(60);
        vm.warp(1090);
        limiter.configure(100, 10);
        vm.snapshotGasLastCall("AssetRateLimits", "configureNewDuration");
        assertEq(limiter.remaining(), 40);
        vm.warp(1099);
        vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
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
        vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
        limiter.consume(1);
        vm.warp(1250);
        limiter.consume(100);
        assertEq(limiter.remaining(), 0);
    }

    /// forge-config: default.isolate = true
    function test_ExpiredReconfigurationDiscardsOldUsage() public {
        limiter.configure(100, 100);
        limiter.consume(100);
        vm.warp(1100);
        limiter.configure(50, 200);
        vm.snapshotGasLastCall("AssetRateLimits", "configureAfterRollover");
        assertEq(limiter.remaining(), 50);
        limiter.consume(50);
        (,, uint256 start, uint256 spent) = limiter.limit();
        assertEq(start, 1100);
        assertEq(spent, 50);
    }

    /// forge-config: default.isolate = true
    function test_PeriodBoundaryResetsOnceAndDoesNotAccumulateCapacity() public {
        limiter.configure(100, 100);
        limiter.consume(100);
        vm.warp(1099);
        assertEq(limiter.remaining(), 0);
        vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
        limiter.consume(1);
        vm.warp(1355);
        uint256 remaining = limiter.remaining();
        vm.snapshotGasLastCall("AssetRateLimits", "remainingExpired");
        assertEq(remaining, 100);
        (,, uint256 oldStart, uint256 oldSpent) = limiter.limit();
        assertEq(oldStart, 1000);
        assertEq(oldSpent, 100);
        limiter.consume(70);
        vm.snapshotGasLastCall("AssetRateLimits", "consumeRollover");
        (,, uint256 start, uint256 spent) = limiter.limit();
        assertEq(start, 1300);
        assertEq(spent, 70);
        limiter.consume(10);
        vm.snapshotGasLastCall("AssetRateLimits", "consumeSamePeriod");
        vm.warp(1399);
        assertEq(limiter.remaining(), 20);
        vm.warp(1400);
        assertEq(limiter.remaining(), 100);
    }

    function test_MaximumUintBudgetAndDurationRejectOverspending() public {
        limiter.configure(type(uint256).max, type(uint48).max);
        limiter.consume(type(uint256).max - 1);
        assertEq(limiter.remaining(), 1);
        vm.expectRevert(stdError.arithmeticError);
        limiter.consume(2);
        assertEq(limiter.remaining(), 1);
        limiter.consume(1);
        assertEq(limiter.remaining(), 0);
    }

    /// @dev Independent absolute-period accounting catches overspending across a sequence of time jumps.
    function test_PeriodRolloverOverflowPreservesUsage() public {
        vm.warp(type(uint48).max);
        limiter.configure(100, 1);
        limiter.consume(40);
        uint256 nextTimestamp = uint256(type(uint48).max) + 1;
        vm.warp(nextTimestamp);
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(48), nextTimestamp)
        );
        limiter.consume(1);
        (,, uint48 start, uint256 spent) = limiter.limit();
        assertEq(start, type(uint48).max);
        assertEq(spent, 40);
    }

    function testFuzz_AggregateSpendingNeverExceedsPeriodBudget(
        uint256 maximum,
        uint48 duration,
        uint256[16] memory amounts,
        uint256[16] memory delays
    ) public {
        maximum = bound(maximum, 1, 1e24);
        duration = uint48(bound(duration, 1, 30 days));
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
                vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
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
    using AssetRateLimits for AssetRateLimits.AssetLimit;
    AssetRateLimits.AssetLimit public limit;

    function configure(uint256 maximum, uint48 duration) external {
        limit.configure(maximum, duration);
    }

    function consume(uint256 assets) external {
        limit.consume(assets);
    }

    function remaining() external view returns (uint256) {
        return limit.remaining();
    }
}
