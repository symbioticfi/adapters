// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {CREOracleTestBase} from "test/adapters/merkle-adapter/oracle/CREOracle.t.sol";

/// @dev Tests end-of-block capital-flow reconciliation.
contract MerkleAdapterFlowHistoryTest is CREOracleTestBase {
    function test_AllocationIsUsableImmediatelyAtAnyTime() public {
        _deliver(_report(0));
        for (uint256 i; i < 3; ++i) {
            vm.warp(uint256(oracle.snapshotTimestamp()) + 1 + i * (oracle.MAX_REPORT_AGE() - 1) / 2);
            _allocate(100);
            vm.prank(account);
            adapter.push(100);
            assertEq(asset.balanceOf(account), (i + 1) * 100);
            assertEq(adapter.totalAssets(), (i + 1) * 100);
        }
        _next(300);
        assertEq(adapter.totalAssets(), 300);
    }

    function test_FlowHistoryUsesEndOfBlockAndPreservesOlderCheckpoints() public {
        _deliver(_report(0));
        uint48 emptyBlock = uint48(vm.getBlockNumber() - 1);
        _allocate(150);
        _releasePortfolio(20);
        uint48 firstBlock = uint48(vm.getBlockNumber());
        _allocate(50);
        assertEq(delegator.deallocate(address(adapter), 20), 20);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(adapter.netFlowAt(emptyBlock), 0);
        assertEq(adapter.netFlowAt(firstBlock), 180);
        uint48 secondBlock = uint48(vm.getBlockNumber());
        _allocate(40);
        vm.roll(vm.getBlockNumber() + 2);
        assertEq(adapter.netFlowAt(firstBlock), 180);
        assertEq(adapter.netFlowAt(secondBlock), 220);
        assertEq(adapter.netFlowAt(secondBlock + 1), 220);
        assertEq(adapter.netFlow(), 220);
    }

    function test_FlowHistoryReturnsLatestFlowForCurrentAndFutureBlocks() public {
        assertEq(adapter.netFlowAt(uint48(vm.getBlockNumber())), 0);
        assertEq(adapter.netFlowAt(uint48(vm.getBlockNumber() + 1)), 0);
        _deliver(_report(0));
        _allocate(100);
        assertEq(adapter.netFlowAt(uint48(vm.getBlockNumber())), 100);
        assertEq(adapter.netFlowAt(uint48(vm.getBlockNumber() + 1)), 100);
    }

    function test_ReportBeforeAllocationAddsTheLaterCapitalExactlyOnce() public {
        _deliver(_report(0));
        _allocate(1000);
        _advanceReport();
        ICREOracle.Report memory captured = _report(1000);
        _allocate(200);
        _deliver(captured);
        assertEq(adapter.totalAssets(), 1200);
        _next(1200);
        assertEq(adapter.totalAssets(), 1200);
    }

    function test_ReportBeforeWithdrawalSubtractsTheLaterCapitalExactlyOnce() public {
        _fundPortfolio();
        _releasePortfolio(1000);
        _advanceReport();
        ICREOracle.Report memory captured = _report(1000);
        assertEq(delegator.deallocate(address(adapter), 150), 150);
        _deliver(captured);
        assertEq(adapter.totalAssets(), 850);
        _next(850);
        assertEq(adapter.totalAssets(), 850);
        assertEq(asset.balanceOf(adapter.vault()), 150);
    }

    function test_SnapshotAfterWithdrawalDoesNotSubtractItTwice() public {
        _fundPortfolio();
        _releasePortfolio(1000);
        assertEq(delegator.deallocate(address(adapter), 150), 150);
        _next(850);
        assertEq(adapter.totalAssets(), 850);
        assertEq(adapter.netFlow(), 850);
    }

    function test_ReportBetweenAllocationAndWithdrawalRecognizesOnlyPerformance() public {
        _fundPortfolio();
        _releasePortfolio(1000);
        _allocate(100);
        _advanceReport();
        ICREOracle.Report memory captured = _report(1110);
        assertEq(delegator.deallocate(address(adapter), 200), 200);
        _deliver(captured);
        assertEq(adapter.totalAssets(), 910);
        _assertReportedAssets(1110);
        assertEq(adapter.totalAssets() + asset.balanceOf(adapter.vault()), 1110);
    }

    function test_InternalPushPullAndDirectReturnDoNotChangeCapitalFlow() public {
        _fundPortfolio();
        vm.startPrank(account);
        adapter.push(700);
        adapter.pull(200);
        asset.transfer(address(adapter), 100);
        vm.stopPrank();
        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(asset.balanceOf(address(adapter)), 600);
        assertEq(adapter.freeAssets(), 0);
        _next(1000);
        assertEq(adapter.totalAssets(), 1000);
    }

    function test_LifetimeNetFlowCanBeNegativeAfterReturningProfit() public {
        _fundPortfolio();
        asset.transfer(address(adapter), 100);
        delegator.requestDeallocate(address(adapter), 1100);
        _next(1100);
        assertEq(delegator.deallocate(address(adapter), 1100), 1100);
        uint48 withdrawalBlock = uint48(vm.getBlockNumber());
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(adapter.netFlow(), -100);
        assertEq(adapter.netFlowAt(withdrawalBlock), -100);
        _assertReportedAssets(1100);
        assertEq(adapter.totalAssets(), 0);
        _next(0);
        assertEq(adapter.totalAssets(), 0);
        _allocate(50);
        assertEq(adapter.netFlow(), -50);
        assertEq(adapter.totalAssets(), 50);
    }

    function test_RequestTimingDoesNotChangeNAVOrCheckpoint() public {
        _fundPortfolio();
        delegator.requestDeallocate(address(adapter), 300);
        vm.warp(block.timestamp + 5);
        delegator.requestDeallocate(address(adapter), 100);
        assertEq(adapter.pendingDeallocation(), 100);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(adapter.netFlow(), 1000);
        delegator.requestDeallocate(address(adapter), 0);
        assertEq(adapter.pendingDeallocation(), 0);
        assertEq(delegator.deallocate(address(adapter), 1000), 0);
        _next(1000);
        assertEq(delegator.deallocate(address(adapter), 1000), 300);
        assertEq(adapter.totalAssets(), 700);
    }

    function testFuzz_DelayedSnapshotReconcilesBothDirections(uint96 added, uint96 withdrawn) public {
        _fundPortfolio();
        _releasePortfolio(1000);
        added = uint96(bound(added, 0, 1e20));
        withdrawn = uint96(bound(withdrawn, 0, 1000));
        _advanceReport();
        ICREOracle.Report memory captured = _report(1000);
        _allocate(added);
        assertEq(delegator.deallocate(address(adapter), withdrawn), withdrawn);
        _deliver(captured);
        assertEq(adapter.totalAssets(), uint256(1000) + added - withdrawn);
        assertEq(adapter.totalAssets(), asset.balanceOf(address(adapter)));
        _next(uint256(1000) + added - withdrawn);
        assertEq(adapter.totalAssets(), uint256(1000) + added - withdrawn);
    }

    function _fundPortfolio() internal {
        _deliver(_report(0));
        _allocate(1000);
        _next(1000);
    }

    function _allocate(uint256 amount) internal returns (uint256) {
        asset.transfer(adapter.vault(), amount);
        return delegator.allocate(address(adapter), amount);
    }

    function _next(uint256 assets) internal {
        _advanceReport();
        _deliver(_report(assets));
    }
}
