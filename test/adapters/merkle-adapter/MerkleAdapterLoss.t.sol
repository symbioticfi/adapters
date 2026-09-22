// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";

import {stdError} from "forge-std/StdError.sol";

import {CREOracleTestBase} from "test/adapters/merkle-adapter/oracle/CREOracle.t.sol";

contract MerkleAdapterLossTest is CREOracleTestBase {
    function setUp() public override {
        super.setUp();
        _deliver(_report(0));
        _afterCutoff();
        asset.transfer(adapter.vault(), 1000);
        delegator.allocate(address(adapter), 1000);
        _next(0);
        _next(1000);
        vm.prank(account);
        adapter.push(1000);
    }

    function test_QueuedWithdrawalSurvivesAnAlreadyAcceptedLoss() public {
        delegator.requestDeallocate(address(adapter), 1000);
        vm.startPrank(account);
        asset.transfer(address(0xdead), 100);
        adapter.pull(900);
        vm.stopPrank();
        _next(900);
        assertFalse(oracle.oracleFrozen());
        assertEq(adapter.totalAssets(), 900);

        _next(900);

        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 5);
        assertEq(oracle.totalAssets(), 0);
        assertEq(adapter.totalAssets(), 900);
        assertEq(adapter.deallocatable(), 900);
        assertEq(delegator.deallocate(address(adapter), 1000), 900);
        assertEq(adapter.totalAssets(), 0);
    }

    function test_ReviewedLossAtWithdrawalMaturityReleasesSurvivingAssets() public {
        delegator.requestDeallocate(address(adapter), 1000);
        _next(1000);
        vm.startPrank(account);
        asset.transfer(address(0xdead), 600);
        adapter.pull(400);
        vm.stopPrank();
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        ICREOracle.Report memory update = _report(400);
        _deliver(update);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 4);
        assertEq(_batch(false).deallocation, 1000);

        vm.expectEmit(false, false, false, true, address(adapter));
        emit IMerkleAdapter.SettleReport(400);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit ICREOracle.OnReport(5, 0, update.snapshotBlock, update.snapshotTimestamp);
        oracle.unfreezeOracle(abi.encode(update));

        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 5);
        assertEq(oracle.totalAssets(), 0);
        assertEq(adapter.totalAssets(), 400);
        assertEq(adapter.deallocatable(), 400);
        assertEq(delegator.deallocate(address(adapter), 1000), 400);
        assertEq(adapter.totalAssets(), 0);
    }

    function testFuzz_WithdrawalIsCappedBySurvivingNAV(uint256 requested, uint16 surviving) public {
        surviving = uint16(bound(surviving, 0, 1000));
        delegator.requestDeallocate(address(adapter), requested);
        _next(1000);
        vm.startPrank(account);
        asset.transfer(address(0xdead), 1000 - surviving);
        adapter.pull(surviving);
        vm.stopPrank();
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        ICREOracle.Report memory update = _report(surviving);
        _deliverWithReview(update);

        uint256 released = requested < surviving ? requested : surviving;
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), surviving - released);
        assertEq(adapter.totalAssets(), surviving);
        assertEq(adapter.deallocatable(), released);
        assertEq(delegator.deallocate(address(adapter), type(uint256).max), released);
        assertEq(adapter.totalAssets(), surviving - released);
    }

    function test_CompleteLossClearsMaturingWithdrawal() public {
        delegator.requestDeallocate(address(adapter), 1000);
        _next(1000);
        vm.prank(account);
        asset.transfer(address(0xdead), 1000);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        ICREOracle.Report memory update = _report(0);
        _deliverWithReview(update);

        assertFalse(oracle.oracleFrozen());
        assertEq(_batch(false).deallocation, 0);
        assertEq(adapter.totalAssets(), 0);
        assertEq(adapter.reservedAssets(), 0);
        assertEq(delegator.deallocate(address(adapter), 1000), 0);
        _next(0);
        assertFalse(oracle.oracleFrozen());
    }

    function test_PriorMaturedAndPendingAssetsAreNotWrittenDown() public {
        delegator.requestDeallocate(address(adapter), 200);
        _next(1000);
        vm.prank(account);
        adapter.pull(200);
        _next(1000);
        assertEq(adapter.deallocatable(), 200);

        delegator.requestDeallocate(address(adapter), type(uint256).max);
        _next(800);
        asset.transfer(adapter.vault(), 50);
        delegator.allocate(address(adapter), 50);
        vm.startPrank(account);
        asset.transfer(address(0xdead), 500);
        adapter.pull(300);
        vm.stopPrank();
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        ICREOracle.Report memory update = _report(300);
        _deliverWithReview(update);

        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 0);
        assertEq(_batch(false).allocation, 50);
        assertEq(adapter.reservedAssets(), 550);
        assertEq(adapter.totalAssets(), 550);
        assertEq(delegator.deallocate(address(adapter), type(uint256).max), 500);
        assertEq(adapter.totalAssets(), 50);
        _next(50);
        assertFalse(oracle.oracleFrozen());
        assertEq(adapter.totalAssets(), 50);
    }

    function test_LossDoesNotReplaceFundingRequirementWithIdleBalance() public {
        delegator.requestDeallocate(address(adapter), 1000);
        _next(1000);
        vm.prank(account);
        adapter.pull(300);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        ICREOracle.Report memory update = _report(400);
        _expectRecoveryFailure(update, ICREOracle.InvalidReport.selector);

        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 4);
        assertEq(oracle.totalAssets(), 1000);
        assertEq(_batch(false).deallocation, 1000);
        assertEq(adapter.deallocatable(), 0);
    }

    function test_ConsecutiveReportsSettleBothWithdrawalBatchesAfterLoss() public {
        delegator.requestDeallocate(address(adapter), 300);
        _next(1000);
        delegator.requestDeallocate(address(adapter), 800);
        assertEq(_batch(false).deallocation, 300);
        assertEq(_batch(true).deallocation, 500);
        vm.startPrank(account);
        asset.transfer(address(0xdead), 400);
        adapter.pull(600);
        vm.stopPrank();
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        ICREOracle.Report memory update = _report(600);
        _deliverWithReview(update);
        assertFalse(oracle.oracleFrozen());
        assertEq(adapter.deallocatable(), 300);
        assertEq(_batch(false).deallocation, 500);
        assertEq(oracle.totalAssets(), 300);

        _next(300);

        assertFalse(oracle.oracleFrozen());
        assertEq(_batch(false).deallocation, 0);
        assertEq(_batch(true).deallocation, 0);
        assertEq(adapter.deallocatable(), 600);
        assertEq(adapter.totalAssets(), 600);
        assertEq(delegator.deallocate(address(adapter), 1000), 600);
        assertEq(adapter.totalAssets(), 0);
    }

    function testFuzz_ProtectedReserveOverflowRevertsWithoutChangingOracle(bool reviewed) public {
        delegator.requestDeallocate(address(adapter), 1000);
        _next(1000);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        ICREOracle.Report memory update = _report(reviewed ? 0 : 1000);
        bytes memory payload = abi.encode(update);
        if (reviewed) _deliver(update);
        bytes32 rejectedHash = oracle.rejectedReportHash();
        _setAdapterState(IMerkleAdapter.deallocatable.selector, 0, type(uint256).max);
        _setAdapterState(IMerkleAdapter.nextBatch.selector, 0, 1);
        vm.expectRevert(stdError.arithmeticError);
        if (reviewed) oracle.unfreezeOracle(payload);
        else _deliver(update);

        assertEq(oracle.oracleFrozen(), reviewed);
        assertEq(oracle.rejectedReportHash(), rejectedHash);
        assertEq(oracle.nonce(), 4);
        assertEq(oracle.totalAssets(), 1000);
        assertEq(_batch(false).deallocation, 1000);
    }

    function test_OnlyOracleCanSettleAWithdrawal() public {
        delegator.requestDeallocate(address(adapter), 1000);
        _next(1000);
        vm.expectRevert(IMerkleAdapter.InvalidCaller.selector);
        adapter.settleReport(0);
        vm.prank(account);
        vm.expectRevert(IMerkleAdapter.InvalidCaller.selector);
        adapter.settleReport(0);
        vm.prank(address(delegator));
        vm.expectRevert(IMerkleAdapter.InvalidCaller.selector);
        adapter.settleReport(0);
        assertEq(_batch(false).deallocation, 1000);
    }

    /// forge-config: default.isolate = true
    function test_SettleReportPromotesDeferredBatchAndMaturesSurvivingWithdrawal() public {
        delegator.requestDeallocate(address(adapter), 500);
        _next(1000);
        delegator.requestDeallocate(address(adapter), 800);
        vm.prank(account);
        adapter.pull(400);
        vm.prank(address(oracle));
        (bool accepted, uint256 netAssets) = adapter.settleReport(400);
        vm.snapshotGasLastCall("MerkleAdapterLoss", "settleReport");

        assertTrue(accepted);
        assertEq(netAssets, 0);
        assertEq(_batch(false).deallocation, 300);
        assertEq(_batch(true).deallocation, 0);
        assertEq(adapter.deallocatable(), 400);
        assertEq(_batch(false).allocation, 0);
        assertEq(_batch(true).allocation, 0);
    }

    function _next(uint256 assets) internal {
        _advanceReport();
        _deliver(_report(assets));
        _afterCutoff();
    }
}
