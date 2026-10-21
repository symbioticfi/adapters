// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {CREOracleTestBase} from "./oracle/CREOracle.t.sol";

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MerkleAdapterStagingTest is CREOracleTestBase {
    function testFuzz_CheckpointsPreserveEarlierBlocksAndCombineSameBlockReturns(uint256 first, uint256 second) public {
        first = bound(first, 1, 499);
        second = bound(second, 1, 500 - first);
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(1000);
        delegator.requestDeallocate(address(adapter), 1000);
        uint48 firstBlock = uint48(vm.getBlockNumber());
        vm.prank(account);
        adapter.pull(first);
        vm.prank(account);
        adapter.pull(second);
        assertEq(adapter.stagedLiquidityAt(firstBlock - 1), 0);
        assertEq(adapter.stagedLiquidityAt(firstBlock), first + second);
        vm.roll(vm.getBlockNumber() + 2);
        vm.prank(account);
        adapter.pull(100);
        assertEq(adapter.stagedLiquidityAt(firstBlock), first + second);
        assertEq(adapter.stagedLiquidityAt(firstBlock + 1), first + second);
        assertEq(adapter.stagedLiquidityAt(uint48(vm.getBlockNumber())), first + second + 100);
        assertEq(adapter.stagedLiquidityAt(type(uint48).max), first + second + 100);
        _syncLiquidity();
        assertEq(adapter.stagedLiquidity(), first + second + 100);
    }

    function test_HistorySurvivesMultipleReleasesAndPayouts() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(1000);
        delegator.requestDeallocate(address(adapter), 1000);
        uint48 firstBlock = uint48(vm.getBlockNumber());
        for (uint256 i; i < 10; ++i) {
            vm.prank(account);
            adapter.pull(100);
            _advanceReport();
            _deliver(_report(1000 - i * 100));
            assertEq(delegator.deallocate(address(adapter), 100), 100);
            assertEq(adapter.stagedLiquidity(), 0);
        }
        for (uint256 i; i < 10; ++i) {
            assertEq(adapter.stagedLiquidityAt(firstBlock + uint48(i)), (i + 1) * 100);
        }
        assertEq(adapter.stagedLiquidityAt(type(uint48).max), 1000);
        _syncLiquidity();
        assertEq(adapter.releasedLiquidity(), 0);
    }

    function test_LossCapConsumesCoveredHistoryWithoutReleasingLaterCash() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(1000);
        delegator.requestDeallocate(address(adapter), 1000);
        vm.prank(account);
        adapter.pull(600);
        _advanceReport();
        ICREOracle.Report memory captured = _report(400);
        vm.prank(account);
        adapter.pull(400);
        _deliverWithReview(captured);
        assertEq(adapter.releasedLiquidity(), 400);
        assertEq(adapter.stagedLiquidity(), 400);

        assertEq(delegator.deallocate(address(adapter), 400), 400);
        _syncLiquidity();
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.stagedLiquidity(), 400);
        _advanceReport();
        _deliver(_report(0));
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(adapter.stagedLiquidityAt(uint48(vm.getBlockNumber())), 1000);
    }

    function test_CumulativeStagingReachesUint208Maximum() public {
        _fundPortfolio(1000);
        vm.mockCall(
            address(asset), abi.encodeCall(IERC20.balanceOf, (address(adapter))), abi.encode(type(uint208).max - 1)
        );
        _stageFixtureCash();
        delegator.requestDeallocate(address(adapter), type(uint256).max);
        uint48 firstBlock = uint48(vm.getBlockNumber());
        vm.roll(vm.getBlockNumber() + 1);
        vm.mockCall(address(asset), abi.encodeCall(IERC20.balanceOf, (address(adapter))), abi.encode(type(uint208).max));
        _stageFixtureCash();
        assertEq(adapter.stagedLiquidityAt(firstBlock), type(uint208).max - 1);
        assertEq(adapter.stagedLiquidityAt(uint48(vm.getBlockNumber())), type(uint208).max);
        assertEq(adapter.stagedLiquidity(), type(uint208).max);
    }

    function test_ReportReleasesAllReturnsStagedBeforeItsSnapshot() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(1000);
        delegator.requestDeallocate(address(adapter), 500);
        vm.prank(account);
        adapter.pull(200);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(account);
        adapter.pull(300);
        assertEq(adapter.stagedLiquidity(), 500);
        _advanceReport();
        _deliver(_report(1000));
        assertEq(adapter.releasedLiquidity(), 500);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(delegator.deallocate(address(adapter), 500), 500);
    }

    function test_DelayedReportReleasesOnlyReturnsStagedThroughItsSnapshot() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(1000);
        delegator.requestDeallocate(address(adapter), 500);
        vm.prank(account);
        adapter.pull(200);
        _advanceReport();
        ICREOracle.Report memory captured = _report(1000);
        vm.prank(account);
        adapter.pull(300);
        assertEq(adapter.stagedLiquidity(), 500);
        _deliver(captured);
        assertEq(adapter.releasedLiquidity(), 200);
        assertEq(adapter.stagedLiquidity(), 300);
        assertEq(delegator.deallocate(address(adapter), 500), 200);
        _syncLiquidity();
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.stagedLiquidity(), 300);
        _advanceReport();
        _deliver(_report(800));
        assertEq(delegator.deallocate(address(adapter), 500), 300);
    }
}
