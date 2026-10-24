// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {MerkleCapitalFlowFixture} from "./MerkleCapitalFlow.t.sol";
import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";

/// @dev Stateful custody conservation through the production vault and delegator, including delayed reports and sync.
contract MerkleCapitalFlowInvariantTest is MerkleCapitalFlowFixture {
    ICREOracle.Report internal pendingReport;
    int256 internal expectedFlow;
    uint256 internal expectedTotal;
    // Gains and losses change accounted NAV when their accepted snapshot becomes eligible.
    uint256 internal cumulativeLoss;
    uint256 internal reportedLoss;
    uint256 internal prevReportedLoss;
    uint256 internal pendingReportLoss;
    uint256 internal cumulativeProfit;
    uint256 internal reportedProfit;
    uint256 internal prevReportedProfit;
    uint256 internal pendingReportProfit;

    function setUp() public override {
        super.setUp();
        expectedFlow = 1000;
        expectedTotal = 10_000;
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = this.stepAllocate.selector;
        selectors[1] = this.stepReturn.selector;
        selectors[2] = this.stepRequest.selector;
        selectors[3] = this.stepPull.selector;
        selectors[4] = this.stepCapture.selector;
        selectors[5] = this.stepDeliver.selector;
        selectors[6] = this.stepProfit.selector;
        selectors[7] = this.stepLoss.selector;
        selectors[8] = this.stepSync.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
        targetContract(address(this));
    }

    function stepAllocate(uint256 amount) public {
        amount = bound(amount, 0, asset.balanceOf(address(realVault)));
        uint256 vaultCash = asset.balanceOf(address(realVault));
        realDelegator.allocate(address(adapter), amount);
        // The public entry point may return existing adapter cash before allocating new capital.
        expectedFlow += int256(vaultCash) - int256(asset.balanceOf(address(realVault)));
    }

    function stepReturn(uint256 amount) public {
        amount = bound(amount, 0, expectedTotal);
        uint256 vaultCash = asset.balanceOf(address(realVault));
        uint256 returnable = realDelegator.deallocatable();
        realDelegator.deallocate(address(adapter), amount);
        // Include the automatic sweep after the explicitly requested return.
        uint256 returned = asset.balanceOf(address(realVault)) - vaultCash;
        assertEq(returned, returnable, "deallocation and its follow-up sweep match simulated liquidity");
        expectedFlow -= int256(returned);
    }

    function stepRequest(uint256 amount) public {
        amount = bound(amount, 0, adapter.totalAssets());
        vm.prank(address(realDelegator));
        adapter.requestDeallocate(amount);
    }

    function stepPull(uint256 amount) public {
        amount = bound(amount, 0, asset.balanceOf(account));
        vm.prank(account);
        adapter.pull(amount);
    }

    function stepSync() public {
        _syncLiquidity();
    }

    function stepCapture() public {
        _capturePendingReport();
    }

    function stepDeliver() public {
        if (pendingReport.snapshotBlock == 0) return;
        _deliverPendingReport();
    }

    function stepProfit(uint256 amount) public {
        amount = bound(amount, 0, 100);
        asset.transfer(account, amount);
        cumulativeProfit += amount;
        expectedTotal += amount;
        _capturePendingReport();
        _deliverPendingReport();
    }

    function stepLoss(uint256 amount) public {
        amount = bound(amount, 0, asset.balanceOf(account));
        vm.prank(account);
        asset.transfer(address(0xdead), amount);
        cumulativeLoss += amount;
        expectedTotal -= amount;
    }

    function test_UnreportedLossRemainsInNAVUntilItsSnapshotIsDelivered() public {
        _fixtureCashToAccount(1000);
        stepLoss(200);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(_portfolioCash(), 800);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();

        stepCapture();
        stepRequest(1000);
        stepPull(800);
        stepReturn(800);
        assertEq(realDelegator.deallocatable(), 0);
        stepDeliver();
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(adapter.totalAssets(), 800);
        assertEq(realDelegator.deallocatable(), 0, "cash staged after the snapshot remains locked");
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();

        stepCapture();
        stepAllocate(100);
        stepDeliver();
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(adapter.totalAssets(), 900);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(realDelegator.deallocatable(), 800);
        stepReturn(800);
        assertEq(adapter.totalAssets(), 100);
        assertEq(realVault.totalAssets(), 9800);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();
    }

    function test_ReportRecognizesOnlySnapshotLossAcrossRequestResetAndReturns() public {
        _fixtureCashToAccount(1000);
        stepRequest(1000);
        stepLoss(200);
        stepPull(300);
        stepCapture();
        stepLoss(100);
        stepRequest(0);
        stepDeliver();
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(adapter.totalAssets(), 800);
        assertEq(_portfolioCash(), 700);

        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.stagedLiquidity(), 300);
        assertEq(realDelegator.deallocatable(), 300);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_ReleasedAndStagedLiquidityRemainCashBacked();
        invariant_VaultTransfersConserveCombinedAssets();

        stepReturn(100);
        assertEq(adapter.totalAssets(), 500);
        assertEq(_portfolioCash(), 400);
        assertEq(realVault.totalAssets(), 9800);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();

        stepCapture();
        stepDeliver();
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(adapter.totalAssets(), 400);
        assertEq(realVault.totalAssets(), 9700);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();
    }

    function test_SnapshotBeforeLossDoesNotRecognizeLaterLoss() public {
        _fixtureCashToAccount(1000);
        stepCapture();
        stepLoss(200);
        stepDeliver();
        assertEq(adapter.totalAssets(), 1000);
        assertEq(_portfolioCash(), 800);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();

        stepCapture();
        stepDeliver();
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(adapter.totalAssets(), 800);
        assertEq(realVault.totalAssets(), 9800);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();
    }

    function test_DelayedLossSnapshotPreservesItsOriginalValuation() public {
        _fixtureCashToAccount(1000);
        stepLoss(200);
        stepCapture();
        stepLoss(100);
        vm.warp(block.timestamp + 365 days);
        stepDeliver();
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(adapter.totalAssets(), 800);
        assertEq(realVault.totalAssets(), 9800);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();
    }

    function test_DelayedNAVDoesNotAutomaticallyRecognizeLoss() public {
        _fixtureCashToAccount(1000);
        stepLoss(200);
        stepCapture();
        stepLoss(100);
        vm.warp(block.timestamp + 365 days);
        stepSync();
        assertEq(adapter.totalAssets(), 1000);
        assertGt(pendingReport.snapshotBlock, 0);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();
    }

    function test_CaptureAfterDelayKeepsPendingReportAvailable() public {
        vm.warp(block.timestamp + 365 days);
        stepCapture();
        assertGt(pendingReport.snapshotBlock, _acceptedSnapshotBlock());
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_ReleasedAndStagedLiquidityRemainCashBacked();
        invariant_VaultTransfersConserveCombinedAssets();
    }

    function test_FullAccountLossAndLaterProfitPreserveConservation() public {
        _fixtureCashToAccount(1000);
        stepLoss(1000);
        stepCapture();
        stepDeliver();
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(adapter.totalAssets(), 0);
        assertEq(realVault.totalAssets(), 9000);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();

        stepProfit(100);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(adapter.totalAssets(), 100);
        assertEq(realVault.totalAssets(), 9100);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();
    }

    function test_AllocateGhostIncludesThePreallocationSweep() public {
        _stageFixtureCash();
        stepRequest(1000);
        stepCapture();
        stepDeliver();
        vm.roll(vm.getBlockNumber() + 1);
        stepAllocate(100);
        assertEq(expectedFlow, 100);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();
    }

    function test_AcceptedReportRemainsUnsynchronizedAcrossLiquiditySimulation() public {
        _fixtureCashToAccount(700);
        stepRequest(300);
        uint48 syncedBlock = adapter.syncedSnapshotBlock();
        stepCapture();
        stepDeliver();
        vm.roll(vm.getBlockNumber() + 1);
        assertGt(_acceptedSnapshotBlock(), syncedBlock);
        assertEq(adapter.syncedSnapshotBlock(), syncedBlock);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.stagedLiquidity(), 300);

        invariant_ReleasedAndStagedLiquidityRemainCashBacked();
        assertEq(realDelegator.deallocatable(), 300);
        assertEq(adapter.syncedSnapshotBlock(), syncedBlock);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.stagedLiquidity(), 300);
        assertEq(adapter.netFlow(), 1000);

        stepReturn(100);
        assertEq(adapter.syncedSnapshotBlock(), _acceptedSnapshotBlock());
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(expectedFlow, 700);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();
    }

    function test_LossAndProfitReportsCanAdvanceBeforeLiquiditySynchronizes() public {
        _fixtureCashToAccount(600);
        stepRequest(1000);
        uint48 syncedBlock = adapter.syncedSnapshotBlock();
        stepLoss(200);
        stepCapture();
        stepDeliver();
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(adapter.totalAssets(), 800);
        assertEq(adapter.syncedSnapshotBlock(), syncedBlock);
        uint48 lossBlock = _acceptedSnapshotBlock();

        stepProfit(50);
        vm.roll(vm.getBlockNumber() + 1);
        assertGt(_acceptedSnapshotBlock(), lossBlock);
        assertEq(adapter.totalAssets(), 850);
        assertEq(adapter.syncedSnapshotBlock(), syncedBlock);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.stagedLiquidity(), 400);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_ReleasedAndStagedLiquidityRemainCashBacked();
        invariant_VaultTransfersConserveCombinedAssets();

        stepSync();
        assertEq(adapter.syncedSnapshotBlock(), _acceptedSnapshotBlock());
        assertEq(adapter.releasedLiquidity(), 400);

        assertEq(adapter.netFlow(), 1000);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_ReleasedAndStagedLiquidityRemainCashBacked();
        invariant_VaultTransfersConserveCombinedAssets();
    }

    function test_ReturnGhostIncludesTheFollowupSweep() public {
        _stageFixtureCash();
        stepRequest(1000);
        stepCapture();
        stepDeliver();
        vm.roll(vm.getBlockNumber() + 1);
        stepReturn(150);
        assertEq(expectedFlow, 0);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: pr.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: snapshots.invariant.fail-on-revert = true
    /// forge-config: default.invariant.max-time-delay = 10
    /// forge-config: pr.invariant.max-time-delay = 10
    /// forge-config: ci.invariant.max-time-delay = 10
    /// forge-config: snapshots.invariant.max-time-delay = 10
    function invariant_AccountedNAVIncludesUnreportedLoss() public view {
        assertEq(
            adapter.totalAssets(),
            _portfolioCash()
                + (cumulativeLoss - (oracle.reportBlock() < vm.getBlockNumber() ? reportedLoss : prevReportedLoss))
                - (cumulativeProfit
                    - (oracle.reportBlock() < vm.getBlockNumber() ? reportedProfit : prevReportedProfit)),
            "NAV includes unreported loss"
        );
        assertEq(adapter.netFlow(), expectedFlow, "net flow equals observed vault transfers");
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: pr.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: snapshots.invariant.fail-on-revert = true
    /// forge-config: default.invariant.max-time-delay = 10
    /// forge-config: pr.invariant.max-time-delay = 10
    /// forge-config: ci.invariant.max-time-delay = 10
    /// forge-config: snapshots.invariant.max-time-delay = 10
    function invariant_ReleasedAndStagedLiquidityRemainCashBacked() public {
        assertEq(adapter.lockedLiquidity(), adapter.releasedLiquidity() + adapter.stagedLiquidity());
        assertLe(adapter.lockedLiquidity(), asset.balanceOf(address(adapter)));
        // Simulation applies accepted reports without committing their liquidity changes.
        uint256 returnable = realDelegator.deallocatable();
        assertEq(returnable, adapter.freeAssets(), "freeAssets matches immediate deallocation");
        assertLe(adapter.freeAssets(), asset.balanceOf(address(adapter)));
        assertLe(adapter.freeAssets(), adapter.totalAssets());
        assertLe(returnable, adapter.totalAssets());
        assertLe(
            returnable,
            adapter.releasedLiquidity()
                + (adapter.stagedLiquidityAt(_acceptedSnapshotBlock())
                    - adapter.stagedLiquidityAt(adapter.syncedSnapshotBlock())),
            "returns require reported cash"
        );
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: pr.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: snapshots.invariant.fail-on-revert = true
    /// forge-config: default.invariant.max-time-delay = 10
    /// forge-config: pr.invariant.max-time-delay = 10
    /// forge-config: ci.invariant.max-time-delay = 10
    /// forge-config: snapshots.invariant.max-time-delay = 10
    function invariant_VaultTransfersConserveCombinedAssets() public view {
        assertEq(
            realVault.totalAssets(),
            expectedTotal
                + (cumulativeLoss - (oracle.reportBlock() < vm.getBlockNumber() ? reportedLoss : prevReportedLoss))
                - (cumulativeProfit
                    - (oracle.reportBlock() < vm.getBlockNumber() ? reportedProfit : prevReportedProfit))
        );
        assertEq(asset.balanceOf(address(realVault)) + _portfolioCash(), expectedTotal);
    }

    function _capturePendingReport() internal {
        pendingReport = _capturePortfolio();
        pendingReportLoss = cumulativeLoss;
        pendingReportProfit = cumulativeProfit;
    }

    function _deliverPendingReport() internal {
        _submitReport(pendingReport);
        assertEq(oracle.reportBlock(), vm.getBlockNumber(), "report must be accepted");
        prevReportedLoss = reportedLoss;
        reportedLoss = pendingReportLoss;
        prevReportedProfit = reportedProfit;
        reportedProfit = pendingReportProfit;
        delete pendingReport;
        delete pendingReportLoss;
        delete pendingReportProfit;
    }
}
