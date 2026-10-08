// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {CREOracleTestBase} from "./oracle/CREOracle.t.sol";

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {IMerkleAdapterOracle} from "src/interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {stdError} from "forge-std/StdError.sol";

contract MerkleAdapterSyncReportTest is CREOracleTestBase {
    function test_AnyoneCanSyncReportWithoutMovingFundsOrChangingFlow() public {
        _fundPortfolio(1000);
        delegator.requestDeallocate(address(adapter), 300);
        _advanceReport();
        _submitReport(_report(1000));
        vm.expectEmit(true, false, false, true, address(adapter));
        emit IMerkleAdapter.SyncReport(oracle.snapshotBlock(), 300);
        vm.prank(address(0xbeef));
        adapter.syncReport();
        assertEq(adapter.syncedSnapshotBlock(), oracle.snapshotBlock());
        assertEq(adapter.releasedLiquidity(), 300);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(adapter.pendingDeallocation(), 300);
        assertEq(adapter.netFlow(), 1000);
        assertEq(asset.balanceOf(address(adapter)), 1000);
        assertEq(asset.balanceOf(adapter.vault()), 0);
    }

    function test_AnyoneCanStageDirectReturnsWithStaleNAVWithoutChangingEarlierCheckpoints() public {
        _fundPortfolio(1000);
        vm.prank(account);
        adapter.push(1000);
        delegator.requestDeallocate(address(adapter), 500);
        vm.warp(uint256(oracle.snapshotTimestamp()) + oracle.MAX_REPORT_AGE() + 1);
        vm.prank(account);
        asset.transfer(address(adapter), 300);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit IMerkleAdapter.StageLiquidity(300, uint48(vm.getBlockNumber()));
        vm.prank(address(0xbeef));
        adapter.stageLiquidity();
        uint48 stagedAt = uint48(vm.getBlockNumber());
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(account);
        asset.transfer(address(adapter), 100);
        vm.prank(address(0xcafe));
        adapter.stageLiquidity();
        assertEq(adapter.stagedLiquidityAt(stagedAt), 300);
        assertEq(adapter.stagedLiquidity(), 400);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.pendingDeallocation(), 500);
        assertEq(adapter.netFlow(), 1000);
        assertEq(asset.balanceOf(address(adapter)), 400);
    }

    function test_DeallocationAppliesReportAndReturnsCoveredLiquidity() public {
        _fundPortfolio(1000);
        delegator.requestDeallocate(address(adapter), 300);
        _advanceReport();
        _submitReport(_report(1000));
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(delegator.deallocate(address(adapter), 200), 200);
        assertEq(adapter.syncedSnapshotBlock(), oracle.snapshotBlock());
        assertEq(adapter.releasedLiquidity(), 100);
        assertEq(adapter.pendingDeallocation(), 100);
        assertEq(adapter.netFlow(), 800);
    }

    function test_AllocationAppliesLossBeforeAccountingForNewCapital() public {
        _fundPortfolio(1000);
        delegator.requestDeallocate(address(adapter), 1000);
        _advanceReport();
        _submitReport(_report(900));
        asset.transfer(adapter.vault(), 100);
        assertEq(delegator.allocate(address(adapter), 100), 100);
        assertEq(adapter.syncedSnapshotBlock(), oracle.snapshotBlock());
        assertEq(adapter.releasedLiquidity(), 900);
        assertEq(adapter.pendingDeallocation(), 900);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(delegator.deallocate(address(adapter), 1000), 900);
    }

    function test_ExpiredUnsynchronizedReportStillAllowsPullAndRequest() public {
        _fundPortfolio(1000);
        vm.prank(account);
        adapter.push(800);
        delegator.requestDeallocate(address(adapter), 500);
        _advanceReport();
        _submitReport(_report(1000));
        vm.warp(uint256(oracle.snapshotTimestamp()) + oracle.MAX_REPORT_AGE() + 1);
        vm.prank(account);
        adapter.pull(100);
        delegator.requestDeallocate(address(adapter), 600);
        assertEq(asset.balanceOf(address(adapter)), 300);
        assertEq(adapter.stagedLiquidity(), 300);
        assertEq(adapter.pendingDeallocation(), 600);
        vm.expectRevert(IMerkleAdapterOracle.OracleStale.selector);
        adapter.syncReport();
    }

    function test_NoReportIsANoop() public {
        adapter.syncReport();
        assertEq(adapter.syncedSnapshotBlock(), 0);
        assertEq(adapter.releasedLiquidity(), 0);
    }

    function test_ReportAcceptanceDoesNotCallAdapterSettlementOrReadCash() public {
        _fundPortfolio(1000);
        vm.prank(account);
        adapter.push(700);
        delegator.requestDeallocate(address(adapter), 500);
        uint48 syncedBlock = adapter.syncedSnapshotBlock();
        _advanceReport();
        bytes memory reason = abi.encode("cash unavailable");
        vm.mockCallRevert(address(asset), abi.encodeCall(IERC20.balanceOf, (address(adapter))), reason);
        vm.record();
        _submitReport(_report(1000));
        (, bytes32[] memory writes) = vm.accesses(address(adapter));
        assertEq(writes.length, 0);
        assertGt(oracle.snapshotBlock(), syncedBlock);
        assertEq(adapter.syncedSnapshotBlock(), syncedBlock);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.stagedLiquidity(), 300);

        vm.expectRevert(reason);
        adapter.syncReport();
        assertEq(adapter.syncedSnapshotBlock(), syncedBlock);
        assertEq(adapter.stagedLiquidity(), 300);
        vm.clearMockedCalls();
        vm.expectEmit(true, false, false, true, address(adapter));
        emit IMerkleAdapter.SyncReport(oracle.snapshotBlock(), 300);
        adapter.syncReport();
        assertEq(adapter.releasedLiquidity(), 300);
        assertEq(adapter.stagedLiquidity(), 0);
    }

    function test_RejectionCannotReleaseCashButReviewedReportCanBeSynchronized() public {
        _fundPortfolio(1000);
        delegator.requestDeallocate(address(adapter), 300);
        _advanceReport();
        ICREOracle.Report memory update = _report(2000);
        _submitReport(update);
        adapter.syncReport();
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.stagedLiquidity(), 300);
        oracle.acceptReport(abi.encode(update));
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.stagedLiquidity(), 300);
        adapter.syncReport();
        assertEq(adapter.releasedLiquidity(), 300);
        assertEq(adapter.syncedSnapshotBlock(), update.snapshotBlock);
    }

    function test_RepeatedSyncDoesNotRestorePayoutOrReapplyDemandCap() public {
        _fundPortfolio(1000);
        _releasePortfolio(300);
        assertEq(delegator.deallocate(address(adapter), 100), 100);
        delegator.requestDeallocate(address(adapter), 2000);
        uint256 staged = adapter.stagedLiquidity();
        vm.recordLogs();
        adapter.syncReport();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(adapter.releasedLiquidity(), 200);
        assertEq(adapter.stagedLiquidity(), staged);
        assertEq(adapter.pendingDeallocation(), 2000);
        assertEq(adapter.netFlow(), 900);
    }

    function test_ExpiredUnsynchronizedReportRevertsAndLaterReportRecovers() public {
        _fundPortfolio(1000);
        delegator.requestDeallocate(address(adapter), 300);
        uint48 syncedBlock = adapter.syncedSnapshotBlock();
        _advanceReport();
        _submitReport(_report(1000));
        vm.warp(uint256(oracle.snapshotTimestamp()) + oracle.MAX_REPORT_AGE() + 1);
        vm.expectRevert(IMerkleAdapterOracle.OracleStale.selector);
        adapter.syncReport();
        assertEq(adapter.syncedSnapshotBlock(), syncedBlock);
        assertEq(adapter.stagedLiquidity(), 300);
        assertEq(adapter.releasedLiquidity(), 0);
        _advanceReport();
        _submitReport(_report(1000));
        adapter.syncReport();
        assertEq(adapter.releasedLiquidity(), 300);
    }

    function test_NAVOverflowRevertsSynchronizationAtomically() public {
        _fundPortfolio(1000);
        delegator.requestDeallocate(address(adapter), 300);
        uint48 syncedBlock = adapter.syncedSnapshotBlock();
        _advanceReport();
        _submitReport(_report(1000));
        vm.mockCall(
            address(oracle),
            abi.encodeCall(IMerkleAdapterOracle.latestSnapshot, ()),
            abi.encode(uint48(0), uint256(type(int256).max))
        );
        vm.expectRevert(stdError.arithmeticError);
        adapter.syncReport();
        assertEq(adapter.syncedSnapshotBlock(), syncedBlock);
        assertEq(adapter.stagedLiquidity(), 300);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.pendingDeallocation(), 300);
    }

    function test_DelayedSyncUsesLatestAcceptedNAV() public {
        _fundPortfolio(1000);
        delegator.requestDeallocate(address(adapter), 1000);
        _advanceReport();
        _submitReport(_report(900));
        _advanceReport();
        _submitReport(_report(950));
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.pendingDeallocation(), 1000);
        adapter.syncReport();
        assertEq(adapter.releasedLiquidity(), 950);
        assertEq(adapter.pendingDeallocation(), 950);
        assertEq(adapter.syncedSnapshotBlock(), oracle.snapshotBlock());
    }

    function test_ReportReleasesLaterCashAlreadyStagedBeforeItsSnapshot() public {
        _fundPortfolio(1000);
        vm.prank(account);
        adapter.push(800);
        delegator.requestDeallocate(address(adapter), 500);
        vm.prank(account);
        adapter.pull(300);
        _advanceReport();
        _submitReport(_report(1000));
        adapter.syncReport();
        assertEq(adapter.releasedLiquidity(), 500);
        assertEq(adapter.stagedLiquidity(), 0);
        adapter.syncReport();
        assertEq(adapter.releasedLiquidity(), 500);
        _advanceReport();
        _submitReport(_report(1000));
        adapter.syncReport();
        assertEq(adapter.releasedLiquidity(), 500);
        assertEq(adapter.stagedLiquidity(), 0);
    }
}
