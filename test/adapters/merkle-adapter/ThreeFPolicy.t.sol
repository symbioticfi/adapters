// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ThreeFPolicy} from "src/contracts/merkle-adapter/automations/ThreeFPolicy.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/automations/IThreeFPolicy.sol";
import {IAssetRateLimits} from "src/interfaces/merkle-adapter/IAssetRateLimits.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";

contract ThreeFPolicyTest is Test {
    address internal _policy;
    address internal _executor = makeAddr("executor");

    function setUp() public {
        _policy = address(new ThreeFPolicy(address(this), _executor));
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(1000, 1 days);
        ThreeFPolicy(_policy).setMinYieldPerRequest(10_000);
    }

    function test_MulticallConfiguresPolicyAndPreservesOwner() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IThreeFPolicy.setMinYieldPerRequest, (20_000));
        calls[1] = abi.encodeCall(IThreeFPolicy.setMaxAssetsPerDuration, (2000, 2 days));
        ThreeFPolicy(_policy).multicall(calls);
        assertEq(ThreeFPolicy(_policy).minYieldPerRequest(), 20_000);
        assertEq(ThreeFPolicy(_policy).remainingAssets(), 2000);
        vm.prank(_executor);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _executor));
        ThreeFPolicy(_policy).multicall(calls);
    }

    function test_MulticallConsumesAsExecutorAndRollsBackExceededBudget() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IThreeFPolicy.consume, (400, 4));
        calls[1] = abi.encodeCall(IThreeFPolicy.consume, (700, 7));
        vm.prank(_executor);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        ThreeFPolicy(_policy).multicall(calls);
        assertEq(ThreeFPolicy(_policy).remainingAssets(), 1000);
        calls[1] = abi.encodeCall(IThreeFPolicy.consume, (600, 6));
        vm.prank(_executor);
        ThreeFPolicy(_policy).multicall(calls);
        assertEq(ThreeFPolicy(_policy).remainingAssets(), 0);
    }

    function test_OnlyOwnerCanChangePolicy() public {
        vm.startPrank(_executor);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _executor));
        ThreeFPolicy(_policy).setMinYieldPerRequest(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _executor));
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(10_000, 1);
        vm.stopPrank();
    }

    function test_OnlyBoundExecutorCanConsume() public {
        vm.expectRevert(IThreeFPolicy.InvalidCaller.selector);
        ThreeFPolicy(_policy).consume(100, 1);
    }

    function test_ReconfigurationPreservesSpentAcrossDurationAndBudgetChanges() public {
        vm.prank(_executor);
        ThreeFPolicy(_policy).consume(100, 1);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(200, 2 days);
        assertEq(ThreeFPolicy(_policy).remainingAssets(), 100);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(0, 2 days);
        assertEq(ThreeFPolicy(_policy).remainingAssets(), 0);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(200, 2 days);
        assertEq(ThreeFPolicy(_policy).remainingAssets(), 100);
    }

    function test_CurrentMinimumAppliesImmediatelyAndDoesNotResetUsage() public {
        vm.prank(_executor);
        ThreeFPolicy(_policy).consume(100, 1);
        ThreeFPolicy(_policy).setMinYieldPerRequest(20_000);
        vm.prank(_executor);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        ThreeFPolicy(_policy).consume(100, 1);
        assertEq(ThreeFPolicy(_policy).remainingAssets(), 900);
        ThreeFPolicy(_policy).setMinYieldPerRequest(0);
        vm.prank(_executor);
        ThreeFPolicy(_policy).consume(100, 0);
        assertEq(ThreeFPolicy(_policy).remainingAssets(), 800);
    }

    function test_PeriodRollsWithoutAccumulatingUnusedCapacity() public {
        vm.prank(_executor);
        ThreeFPolicy(_policy).consume(1000, 10);
        vm.prank(_executor);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        ThreeFPolicy(_policy).consume(1, 1);
        vm.warp(block.timestamp + 3 days);
        assertEq(ThreeFPolicy(_policy).remainingAssets(), 1000);
        vm.prank(_executor);
        ThreeFPolicy(_policy).consume(1000, 10);
        assertEq(ThreeFPolicy(_policy).remainingAssets(), 0);
    }

    function test_ExecutorsHaveIndependentBudgets() public {
        address second = address(new ThreeFPolicy(address(this), _executor));
        ThreeFPolicy(second).setMaxAssetsPerDuration(1000, 1 days);
        vm.prank(_executor);
        ThreeFPolicy(_policy).consume(1000, 10);
        assertEq(ThreeFPolicy(second).remainingAssets(), 1000);
    }

    function testFuzz_MinimumRoundsConservatively(uint128 principal, uint64 minimum) public {
        principal = uint128(bound(principal, 1, type(uint128).max));
        minimum = uint64(bound(minimum, 1, 1_000_000));
        ThreeFPolicy(_policy).setMinYieldPerRequest(minimum);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(principal, 1 days);
        uint256 yieldAssets = (uint256(principal) * minimum + 999_999) / 1_000_000;
        vm.prank(_executor);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        ThreeFPolicy(_policy).consume(principal, yieldAssets - 1);
        vm.prank(_executor);
        ThreeFPolicy(_policy).consume(principal, yieldAssets);
        assertEq(ThreeFPolicy(_policy).remainingAssets(), 0);
    }
}
