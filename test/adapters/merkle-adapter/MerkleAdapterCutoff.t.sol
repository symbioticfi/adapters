// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";

import {CREOracleTestBase} from "test/adapters/merkle-adapter/oracle/CREOracle.t.sol";

contract MerkleAdapterCutoffTest is CREOracleTestBase {
    function test_AllocationBeforeCutoffEntersNextReport() public {
        _deliver(_report(0));
        _allocate(1000);

        assertEq(_batch(false).allocation, 1000);
        assertEq(_batch(true).allocation, 0);
        assertEq(adapter.totalAssets(), 1000);
        vm.prank(account);
        vm.expectRevert(IMerkleAdapter.InsufficientIdleAssets.selector);
        adapter.push(1);

        _next(1000);
        assertEq(oracle.nonce(), 2);
        assertEq(oracle.totalAssets(), 1000);
        assertEq(adapter.reservedAssets(), 0);
        vm.prank(account);
        adapter.push(1000);
        assertEq(asset.balanceOf(account), 1000);

        _next(1000);
        assertEq(adapter.totalAssets(), 1000, "allocation must be incorporated exactly once");
    }

    function test_AllocationAtCutoffAndAfterWaitsForFollowingReport() public {
        _deliver(_report(0));
        uint256 cutoff = oracle.cutoff();
        vm.warp(cutoff - 1);
        _allocate(100);
        vm.warp(cutoff);
        _allocate(200);
        vm.warp(cutoff + 1);
        _allocate(300);
        assertEq(_batch(false).allocation, 100);
        assertEq(_batch(true).allocation, 500);

        _next(100);
        assertEq(oracle.totalAssets(), 100);
        assertEq(adapter.totalAssets(), 600);
        assertEq(adapter.reservedAssets(), 500);
        _next(600);
        assertEq(oracle.totalAssets(), 600);
        assertEq(adapter.reservedAssets(), 0);
    }

    function test_WithdrawalBeforeAtAndAfterCutoffMaturesInCorrectReport() public {
        _fundPortfolio();
        uint256 cutoff = oracle.cutoff();
        vm.warp(cutoff - 1);
        delegator.requestDeallocate(address(adapter), 100);
        vm.warp(cutoff);
        delegator.requestDeallocate(address(adapter), 400);
        vm.warp(cutoff + 1);
        delegator.requestDeallocate(address(adapter), 500);
        assertEq(_batch(false).deallocation, 100);
        assertEq(_batch(true).deallocation, 400);

        _next(1000);
        assertEq(oracle.totalAssets(), 900);
        assertEq(delegator.deallocate(address(adapter), 500), 100);
        _next(900);
        assertEq(oracle.totalAssets(), 500);
        assertEq(delegator.deallocate(address(adapter), 500), 400);
        _next(500);
        assertEq(delegator.deallocate(address(adapter), 500), 0, "withdrawal cannot mature twice");
        assertEq(adapter.totalAssets(), 500);
    }

    function test_BeforeCutoffRequestsCanBeMatchedReducedAndCancelled() public {
        _fundPortfolio();
        delegator.requestDeallocate(address(adapter), 300);
        assertEq(_allocate(100), 0);
        assertEq(_batch(false).deallocation, 200);
        delegator.requestDeallocate(address(adapter), 50);
        assertEq(_batch(false).deallocation, 50);
        delegator.requestDeallocate(address(adapter), 0);
        assertEq(_batch(false).deallocation, 0);
        _next(1000);
        assertEq(delegator.deallocate(address(adapter), 1000), 0);
        assertEq(oracle.totalAssets(), 1000);
    }

    function test_BeforeCutoffPendingAllocationCanBeReturnedImmediately() public {
        _deliver(_report(0));
        _allocate(100);
        delegator.requestDeallocate(address(adapter), 40);
        assertEq(_batch(false).allocation, 60);
        assertEq(_batch(false).deallocation, 0);
        assertEq(delegator.deallocate(address(adapter), 100), 40);
        _next(60);
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 60);
        assertEq(adapter.totalAssets(), 60);
    }

    function test_AfterCutoffOnlyDeferredRequestsAndAllocationsCanChange() public {
        _fundPortfolio();
        delegator.requestDeallocate(address(adapter), 300);
        _afterCutoff();
        delegator.requestDeallocate(address(adapter), 500);
        assertEq(_allocate(100), 0);
        assertEq(_batch(false).deallocation, 300);
        assertEq(_batch(true).deallocation, 100);

        delegator.requestDeallocate(address(adapter), 0);
        assertEq(_batch(false).deallocation, 300, "the frozen request cannot be cancelled");
        assertEq(_batch(true).deallocation, 0);
        _allocate(50);
        delegator.requestDeallocate(address(adapter), 400);
        assertEq(_batch(true).allocation, 0);
        assertEq(adapter.deallocatable(), 50);
        assertEq(_batch(false).deallocation, 300);
        assertEq(_batch(true).deallocation, 50);

        _next(1000);
        assertEq(oracle.totalAssets(), 700);
        assertEq(delegator.deallocate(address(adapter), 1000), 350);
    }

    function test_SnapshotBeforeCutoffCannotBeCachedOrReviewed() public {
        _deliver(_report(0));
        uint256 cutoff = oracle.cutoff();
        vm.roll(block.number + 1);
        vm.warp(cutoff);
        ICREOracle.Report memory update = _report(0);
        _expectReportError(update, ICREOracle.StaleReport.selector);
        assertEq(oracle.nonce(), 1);
        assertEq(oracle.cutoff(), cutoff);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(abi.encode(update));

        vm.warp(cutoff + 1);
        _deliver(_report(0));
        assertEq(oracle.nonce(), 2, "snapshot exactly at cutoff is eligible");
    }

    function test_DelayedReportKeepsDeferredWritesAndSelectsFutureCutoff() public {
        _deliver(_report(0));
        _allocate(100);
        _afterCutoff();
        _allocate(200);
        vm.warp(10_395);
        _allocate(300);
        _next(100);
        assertEq(oracle.nonce(), 2, "missed calendar slots do not skip accounting nonces");
        assertEq(oracle.cutoff(), 10_490);
        assertEq(_batch(false).allocation, 500);
        assertEq(adapter.totalAssets(), 600);
        _allocate(50);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        _expectReportError(_report(650), ICREOracle.StaleReport.selector);
        _next(650);
        assertEq(oracle.totalAssets(), 650);
        assertEq(adapter.reservedAssets(), 0);
    }

    function test_PostSnapshotReserveChangesDoNotInvalidateClosedBatch() public {
        _fundPortfolio();
        delegator.requestDeallocate(address(adapter), 200);
        _next(1000);
        delegator.requestDeallocate(address(adapter), 300);
        _afterCutoff();
        _allocate(50);
        _advanceReport();
        ICREOracle.Report memory captured = _report(800);

        // The report is in flight while later deposits, cancellation and withdrawals change reserves.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        _allocate(70);
        delegator.requestDeallocate(address(adapter), 350);
        assertEq(delegator.deallocate(address(adapter), 150), 150);
        assertEq(_batch(false).deallocation, 300);
        assertEq(_batch(true).allocation, 70);
        assertEq(adapter.deallocatable(), 100);
        assertEq(adapter.totalAssets(), 970);

        _deliver(captured);
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 4);
        assertEq(oracle.totalAssets(), 500);
        assertEq(adapter.totalAssets(), 970);
        assertEq(adapter.reservedAssets(), 470);
        assertEq(delegator.deallocate(address(adapter), 1000), 400);
        _next(570);
        assertEq(adapter.totalAssets(), 570);
        assertEq(adapter.reservedAssets(), 0);
        assertEq(delegator.deallocate(address(adapter), 1000), 0);
    }

    function test_RejectionAndFreezeDoNotMoveCutoffOrConsumeQueuedFunds() public {
        _deliver(_report(0));
        _allocate(1000);
        uint256 cutoff = oracle.cutoff();
        _advanceReport();
        ICREOracle.Report memory update = _report(1200);
        _deliver(update);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 1);
        assertEq(oracle.cutoff(), cutoff);
        assertEq(_batch(false).allocation, 1000);
        _deliver(update);
        assertEq(oracle.cutoff(), cutoff);

        assertEq(oracle.cutoff(), cutoff);
        oracle.unfreezeOracle(abi.encode(update));
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 2);
        assertGt(oracle.cutoff(), block.timestamp);
        assertEq(adapter.reservedAssets(), 0);
    }

    function test_LossProtectsMaturedReservesAndDeferredAllocation() public {
        _fundPortfolio();
        vm.prank(account);
        adapter.push(1000);
        delegator.requestDeallocate(address(adapter), 200);
        vm.prank(account);
        adapter.pull(200);
        _next(1000);
        assertEq(adapter.deallocatable(), 200);

        delegator.requestDeallocate(address(adapter), type(uint256).max);
        _afterCutoff();
        _allocate(50);
        delegator.requestDeallocate(address(adapter), 0);
        assertEq(_batch(true).allocation, 50);
        assertEq(_batch(false).deallocation, type(uint256).max);
        vm.startPrank(account);
        asset.transfer(address(0xdead), 500);
        adapter.pull(300);
        vm.stopPrank();
        _advanceReport();
        ICREOracle.Report memory update = _report(300);
        _deliverWithReview(update);
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 0);
        assertEq(_batch(false).deallocation, 0);
        assertEq(adapter.deallocatable(), 500);
        assertEq(_batch(false).allocation, 50);
        assertEq(adapter.totalAssets(), 550);

        delegator.requestDeallocate(address(adapter), 30);
        assertEq(_batch(false).allocation, 20);
        assertEq(delegator.deallocate(address(adapter), 1000), 530);
        _next(20);
        assertEq(adapter.totalAssets(), 20);
    }

    function testFuzz_LossCapsWithdrawalInEitherWindow(bool deferred, uint16 surviving) public {
        surviving = uint16(bound(surviving, 0, 1000));
        _fundPortfolio();
        vm.prank(account);
        adapter.push(1000);
        if (deferred) _afterCutoff();
        delegator.requestDeallocate(address(adapter), 1000);
        if (deferred) _next(1000);
        vm.startPrank(account);
        asset.transfer(address(0xdead), 1000 - surviving);
        adapter.pull(surviving);
        vm.stopPrank();
        _advanceReport();
        ICREOracle.Report memory update = _report(surviving);
        _deliverWithReview(update);
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.nonce(), deferred ? 4 : 3);
        assertEq(oracle.totalAssets(), 0);
        assertEq(adapter.totalAssets(), surviving);
        assertEq(delegator.deallocate(address(adapter), 1000), surviving);
        assertEq(adapter.totalAssets(), 0);
    }

    function _allocate(uint256 amount) internal returns (uint256) {
        asset.transfer(adapter.vault(), amount);
        return delegator.allocate(address(adapter), amount);
    }

    function _fundPortfolio() internal {
        _deliver(_report(0));
        _allocate(1000);
        _next(1000);
    }

    function _next(uint256 assets) internal {
        _advanceReport();
        _deliver(_report(assets));
    }
}
