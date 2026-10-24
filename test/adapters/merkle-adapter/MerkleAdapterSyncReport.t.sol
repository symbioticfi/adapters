// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {CREOracleTestBase} from "./oracle/CREOracle.t.sol";

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {IMerkleAdapterOracle} from "src/interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {stdError} from "forge-std/StdError.sol";

contract MerkleAdapterSyncReportTest is CREOracleTestBase {
    function test_acceptedReportUpdatesNAVButCannotReleaseStagedCashInSameBlock() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(1000);
        vm.prank(account);
        adapter.pull(1000);
        asset.transfer(account, 100);

        uint48 previousSnapshotBlock = _acceptedSnapshotBlock();
        _advanceReport();
        _submitReport(_report(1100));
        assertEq(oracle.reportBlock(), vm.getBlockNumber());
        assertEq(oracle.snapshotBlock(), previousSnapshotBlock);
        assertEq(oracle.totalAssets(), 1000);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(adapter.freeAssets(), 0);
        vm.prank(address(delegator));
        assertEq(adapter.deallocate(1000), 0);

        vm.roll(vm.getBlockNumber() + 1);
        assertEq(oracle.snapshotBlock(), _acceptedSnapshotBlock());
        assertEq(oracle.totalAssets(), 1100);
        assertEq(adapter.totalAssets(), 1100);
        assertEq(adapter.freeAssets(), 1000);
        vm.prank(address(delegator));
        assertEq(adapter.deallocate(1000), 1000);
    }

    function test_NewReportKeepsEarlierCoveredCashAvailable() public {
        _fundPortfolio(1000);
        _stageFixtureCash();
        _advanceReport();
        _submitReport(_report(1000));

        vm.roll(vm.getBlockNumber() + 1);
        uint48 firstSnapshotBlock = _acceptedSnapshotBlock();
        assertEq(adapter.freeAssets(), 1000);
        _submitReport(_report(1000));
        assertEq(oracle.snapshotBlock(), firstSnapshotBlock);
        assertEq(adapter.freeAssets(), 1000);
        assertEq(delegator.deallocate(address(adapter), 1000), 1000);
    }

    function test_ConsecutiveReportsReleasePreviouslyCoveredCash() public {
        _fundPortfolio(1000);
        uint48 previousSnapshotBlock = _acceptedSnapshotBlock();
        _stageFixtureCash();
        uint48 stagedAt = uint48(vm.getBlockNumber());
        vm.roll(uint256(stagedAt) + 2);

        ICREOracle.Report memory first = _report(1000);
        first.snapshotBlock = stagedAt;
        _submitReport(first);
        assertEq(oracle.snapshotBlock(), previousSnapshotBlock);
        assertEq(adapter.freeAssets(), 0);

        vm.roll(vm.getBlockNumber() + 1);
        ICREOracle.Report memory second = _report(1000);
        _submitReport(second);
        assertEq(_acceptedSnapshotBlock(), first.snapshotBlock);
        assertEq(oracle.snapshotBlock(), first.snapshotBlock);
        assertEq(adapter.freeAssets(), 1000);

        vm.roll(vm.getBlockNumber() + 1);
        assertEq(_acceptedSnapshotBlock(), second.snapshotBlock);
        assertEq(adapter.freeAssets(), 1000);
    }

    function test_DeallocationSyncPreservesReservesAndFlow() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(700);
        delegator.requestDeallocate(address(adapter), 300);
        _advanceReport();
        _submitReport(_report(1000));
        vm.roll(block.number + 1);
        vm.recordLogs();
        _syncLiquidity();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(adapter.syncedSnapshotBlock(), _acceptedSnapshotBlock());
        assertEq(adapter.releasedLiquidity(), 300);
        assertEq(adapter.stagedLiquidity(), 0);

        assertEq(adapter.netFlow(), 1000);
        assertEq(asset.balanceOf(address(adapter)), 300);
        assertEq(asset.balanceOf(account), 700);
        assertEq(asset.balanceOf(adapter.vault()), 0);
    }

    function test_PullStagesReturnsWithDelayedNAVWithoutChangingEarlierCheckpoints() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(1000);
        delegator.requestDeallocate(address(adapter), 500);
        vm.warp(block.timestamp + 365 days);
        vm.prank(account);
        adapter.pull(300);
        uint48 stagedAt = uint48(vm.getBlockNumber());
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(account);
        adapter.pull(100);
        assertEq(adapter.stagedLiquidityAt(stagedAt), 300);
        assertEq(adapter.stagedLiquidity(), 400);
        assertEq(adapter.releasedLiquidity(), 0);

        assertEq(adapter.netFlow(), 1000);
        assertEq(asset.balanceOf(address(adapter)), 400);
    }

    function test_PullStagesOnlyTransferredCashWithoutCountingLockedCashTwice() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(1000);
        vm.prank(account);
        adapter.pull(200);
        asset.transfer(address(adapter), 1);

        vm.prank(account);
        adapter.pull(0);
        assertEq(adapter.stagedLiquidity(), 200);
        assertEq(adapter.lockedLiquidity(), 200);
        vm.prank(account);
        adapter.pull(0);
        assertEq(adapter.stagedLiquidity(), 200);

        _advanceReport();
        _submitReport(_report(1000));
        vm.roll(block.number + 1);
        _syncLiquidity();
        assertEq(adapter.releasedLiquidity(), 200);
        asset.transfer(address(adapter), 1);
        vm.prank(account);
        adapter.pull(0);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(adapter.lockedLiquidity(), 200);
    }

    function test_DeallocationAppliesReportAndReturnsCoveredLiquidity() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(700);
        delegator.requestDeallocate(address(adapter), 300);
        _advanceReport();
        _submitReport(_report(1000));
        assertEq(adapter.releasedLiquidity(), 0);
        vm.roll(block.number + 1);
        assertEq(delegator.deallocate(address(adapter), 200), 200);
        assertEq(adapter.syncedSnapshotBlock(), _acceptedSnapshotBlock());
        assertEq(adapter.releasedLiquidity(), 100);

        assertEq(adapter.netFlow(), 800);
    }

    function test_AllocationLeavesUnsyncedCoverageForDeallocation() public {
        _fundPortfolio(1000);
        _stageFixtureCash();
        uint48 previous = adapter.syncedSnapshotBlock();
        _advanceReport();
        _submitReport(_report(900));
        asset.transfer(adapter.vault(), 100);
        assertEq(delegator.allocate(address(adapter), 100), 100);
        assertEq(adapter.syncedSnapshotBlock(), previous);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.totalAssets(), 1100);
        vm.roll(block.number + 1);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(delegator.deallocate(address(adapter), 1000), 1000);
    }

    function test_DelayedUnsynchronizedReportAllowsPullRequestAndSync() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(800);
        delegator.requestDeallocate(address(adapter), 500);
        _advanceReport();
        _submitReport(_report(1000));
        vm.warp(block.timestamp + 365 days);
        vm.prank(account);
        adapter.pull(100);
        delegator.requestDeallocate(address(adapter), 600);
        assertEq(asset.balanceOf(address(adapter)), 300);
        assertEq(adapter.stagedLiquidity(), 300);

        vm.roll(block.number + 1);
        _syncLiquidity();
        assertEq(adapter.syncedSnapshotBlock(), _acceptedSnapshotBlock());
    }

    function test_NoReportIsANoop() public {
        vm.recordLogs();
        _syncLiquidity();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(adapter.syncedSnapshotBlock(), 0);
        assertEq(adapter.releasedLiquidity(), 0);
    }

    function test_ReportAcceptanceDoesNotCallAdapterSettlementOrReadCash() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(700);
        delegator.requestDeallocate(address(adapter), 500);
        uint48 syncedBlock = adapter.syncedSnapshotBlock();
        _advanceReport();
        bytes memory reason = abi.encode("cash unavailable");
        vm.mockCallRevert(address(asset), abi.encodeCall(IERC20.balanceOf, (address(adapter))), reason);
        vm.record();
        _submitReport(_report(1000));
        (, bytes32[] memory writes) = vm.accesses(address(adapter));
        assertEq(writes.length, 0);
        assertEq(oracle.reportBlock(), block.number);
        assertEq(adapter.syncedSnapshotBlock(), syncedBlock);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.stagedLiquidity(), 300);

        vm.roll(block.number + 1);
        _syncLiquidity();
        assertEq(adapter.releasedLiquidity(), 300);
        assertEq(adapter.stagedLiquidity(), 0);
    }

    function test_RejectionCannotReleaseCashButReviewedReportCanBeSynchronized() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(700);
        delegator.requestDeallocate(address(adapter), 300);
        _advanceReport();
        ICREOracle.Report memory update = _report(2000);
        _submitReport(update);
        _syncLiquidity();
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.stagedLiquidity(), 300);
        oracle.acceptReport(abi.encode(update));
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.stagedLiquidity(), 300);
        _syncLiquidity();
        assertEq(adapter.releasedLiquidity(), 0);
        vm.roll(block.number + 1);
        _syncLiquidity();
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
        _syncLiquidity();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(adapter.releasedLiquidity(), 200);
        assertEq(adapter.stagedLiquidity(), staged);

        assertEq(adapter.netFlow(), 900);
    }

    function test_DelayedUnsynchronizedReportCanBeApplied() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(700);
        delegator.requestDeallocate(address(adapter), 300);
        uint48 syncedBlock = adapter.syncedSnapshotBlock();
        _advanceReport();
        _submitReport(_report(1000));
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 1);
        _syncLiquidity();
        assertGt(adapter.syncedSnapshotBlock(), syncedBlock);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(adapter.releasedLiquidity(), 300);
    }

    function test_NAVOverflowRevertsSynchronizationAtomically() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(700);
        delegator.requestDeallocate(address(adapter), 300);
        uint48 syncedBlock = adapter.syncedSnapshotBlock();
        _advanceReport();
        _submitReport(_report(1000));
        vm.roll(block.number + 1);
        vm.mockCall(
            address(oracle),
            abi.encodeCall(IMerkleAdapterOracle.latestSnapshot, ()),
            abi.encode(uint48(0), uint256(type(int256).max))
        );
        vm.expectRevert(stdError.arithmeticError);
        _syncLiquidity();
        assertEq(adapter.syncedSnapshotBlock(), syncedBlock);
        assertEq(adapter.stagedLiquidity(), 300);
        assertEq(adapter.releasedLiquidity(), 0);
    }

    function test_DelayedSyncUsesLatestAcceptedNAV() public {
        _fundPortfolio(1000);
        _stageFixtureCash();
        delegator.requestDeallocate(address(adapter), 1000);
        _advanceReport();
        _submitReport(_report(900));
        _advanceReport();
        _submitReport(_report(950));
        assertEq(adapter.releasedLiquidity(), 0);

        vm.roll(block.number + 1);
        _syncLiquidity();
        assertEq(adapter.releasedLiquidity(), 950);
        assertEq(adapter.syncedSnapshotBlock(), _acceptedSnapshotBlock());
    }

    function test_ReportReleasesLaterCashAlreadyStagedBeforeItsSnapshot() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(800);
        delegator.requestDeallocate(address(adapter), 500);
        vm.prank(account);
        adapter.pull(300);
        _advanceReport();
        _submitReport(_report(1000));
        vm.roll(block.number + 1);
        _syncLiquidity();
        assertEq(adapter.releasedLiquidity(), 500);
        assertEq(adapter.stagedLiquidity(), 0);
        _syncLiquidity();
        assertEq(adapter.releasedLiquidity(), 500);
        _advanceReport();
        _submitReport(_report(1000));
        _syncLiquidity();
        assertEq(adapter.releasedLiquidity(), 500);
        assertEq(adapter.stagedLiquidity(), 0);
    }
}
