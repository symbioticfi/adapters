// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {MerkleCapitalFlowFixture} from "./MerkleCapitalFlow.t.sol";
import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";

/// @dev Stateful custody conservation through the production vault and delegator, including delayed loss reports.
contract MerkleCapitalFlowInvariantTest is MerkleCapitalFlowFixture {
    ICREOracle.Report internal pendingReport;
    int256 internal expectedFlow;
    uint256 internal expectedTotal;
    // Losses stay in accounted NAV until an accepted snapshot includes them.
    uint256 internal cumulativeLoss;
    uint256 internal reportedLoss;
    uint256 internal pendingReportLoss;

    function setUp() public override {
        super.setUp();
        expectedFlow = 1000;
        expectedTotal = 10_000;
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = this.stepAllocate.selector;
        selectors[1] = this.stepReturn.selector;
        selectors[2] = this.stepRequest.selector;
        selectors[3] = this.stepPush.selector;
        selectors[4] = this.stepPull.selector;
        selectors[5] = this.stepCapture.selector;
        selectors[6] = this.stepDeliver.selector;
        selectors[7] = this.stepProfit.selector;
        selectors[8] = this.stepStage.selector;
        selectors[9] = this.stepLoss.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
        targetContract(address(this));
    }

    function stepAllocate(uint256 amount) public {
        _ensureFresh();
        amount = bound(amount, 0, asset.balanceOf(address(realVault)));
        uint256 vaultCash = asset.balanceOf(address(realVault));
        realDelegator.allocate(address(adapter), amount);
        // The public entry point may return existing adapter cash before allocating new capital.
        expectedFlow += int256(vaultCash) - int256(asset.balanceOf(address(realVault)));
    }

    function stepReturn(uint256 amount) public {
        _ensureFresh();
        amount = bound(amount, 0, expectedTotal);
        uint256 vaultCash = asset.balanceOf(address(realVault));
        realDelegator.deallocate(address(adapter), amount);
        // Include the automatic sweep after the explicitly requested return.
        expectedFlow += int256(vaultCash) - int256(asset.balanceOf(address(realVault)));
    }

    function stepRequest(uint256 amount) public {
        _ensureFresh();
        amount = bound(amount, 0, adapter.totalAssets());
        vm.prank(address(realDelegator));
        adapter.requestDeallocate(amount);
    }

    function stepPush(uint256 amount) public {
        _ensureFresh();
        uint256 cash = adapter.freeAssets();
        uint256 protected = adapter.releasedLiquidity() + adapter.stagedLiquidity();
        uint256 pending = adapter.pendingDeallocation();
        if (pending > protected) protected = pending;
        amount = bound(amount, 0, cash > protected ? cash - protected : 0);
        vm.prank(account);
        adapter.push(amount);
    }

    function stepPull(uint256 amount) public {
        _ensureFresh();
        amount = bound(amount, 0, asset.balanceOf(account));
        vm.prank(account);
        adapter.pull(amount);
    }

    function stepStage() public {
        _ensureFresh();
        adapter.stageLiquidity();
    }

    function stepCapture() public {
        _ensureFresh();
        _capturePendingReport();
    }

    function stepDeliver() public {
        _ensureFresh();
        if (pendingReport.snapshotTimestamp == 0) return;
        if (block.timestamp - pendingReport.snapshotTimestamp > oracle.MAX_REPORT_AGE()) {
            _capturePendingReport();
        }
        _deliverPendingReport();
    }

    function stepProfit(uint256 amount) public {
        _ensureFresh();
        amount = bound(amount, 0, 100);
        asset.transfer(account, amount);
        expectedTotal += amount;
        _capturePendingReport();
        _deliverPendingReport();
    }

    function stepLoss(uint256 amount) public {
        _ensureFresh();
        amount = bound(amount, 0, asset.balanceOf(account));
        vm.prank(account);
        asset.transfer(address(0xdead), amount);
        cumulativeLoss += amount;
        expectedTotal -= amount;
    }

    function test_UnreportedLossRemainsInNAVUntilItsSnapshotIsDelivered() public {
        stepPush(1000);
        stepLoss(200);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(_portfolioCash(), 800);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();

        stepCapture();
        stepRequest(1000);
        stepPull(800);
        stepReturn(800);
        assertEq(adapter.deallocatable(), 0);
        stepDeliver();
        assertEq(adapter.totalAssets(), 800);
        assertEq(adapter.deallocatable(), 0, "cash staged after the snapshot remains locked");
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();

        stepCapture();
        stepAllocate(100);
        stepDeliver();
        assertEq(adapter.totalAssets(), 900);
        assertEq(adapter.deallocatable(), 800);
        stepReturn(800);
        assertEq(adapter.totalAssets(), 100);
        assertEq(realVault.totalAssets(), 9800);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();
    }

    function test_ReportRecognizesOnlySnapshotLossAcrossCancellationAndReturns() public {
        stepPush(1000);
        stepRequest(1000);
        stepLoss(200);
        stepPull(300);
        stepCapture();
        stepLoss(100);
        stepRequest(0);
        stepDeliver();
        assertEq(adapter.totalAssets(), 800);
        assertEq(_portfolioCash(), 700);
        assertEq(adapter.pendingDeallocation(), 0);
        assertEq(adapter.releasedLiquidity(), 300);
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
        assertEq(adapter.totalAssets(), 400);
        assertEq(realVault.totalAssets(), 9700);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();
    }

    function test_SnapshotBeforeLossDoesNotRecognizeLaterLoss() public {
        stepPush(1000);
        stepCapture();
        stepLoss(200);
        stepDeliver();
        assertEq(adapter.totalAssets(), 1000);
        assertEq(_portfolioCash(), 800);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();

        stepCapture();
        stepDeliver();
        assertEq(adapter.totalAssets(), 800);
        assertEq(realVault.totalAssets(), 9800);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();
    }

    function test_ExpiredLossSnapshotIsRecaptured() public {
        stepPush(1000);
        stepLoss(200);
        stepCapture();
        stepLoss(100);
        vm.warp(uint256(pendingReport.snapshotTimestamp) + oracle.MAX_REPORT_AGE() + 1);
        stepDeliver();
        assertEq(adapter.totalAssets(), 700);
        assertEq(realVault.totalAssets(), 9700);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();
    }

    function test_StaleNAVRefreshRecognizesLossAndDiscardsOldSnapshot() public {
        stepPush(1000);
        stepLoss(200);
        stepCapture();
        stepLoss(100);
        vm.warp(uint256(oracle.snapshotTimestamp()) + oracle.MAX_ORACLE_AGE() + 1);
        stepStage();
        assertEq(adapter.totalAssets(), 700);
        assertEq(pendingReport.snapshotTimestamp, 0);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();
    }

    function test_FullAccountLossAndLaterProfitPreserveConservation() public {
        stepPush(1000);
        stepLoss(1000);
        stepCapture();
        stepDeliver();
        assertEq(adapter.totalAssets(), 0);
        assertEq(realVault.totalAssets(), 9000);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();

        stepProfit(100);
        assertEq(adapter.totalAssets(), 100);
        assertEq(realVault.totalAssets(), 9100);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();
    }

    function test_AllocateGhostIncludesThePreallocationSweep() public {
        stepRequest(1000);
        stepCapture();
        stepDeliver();
        stepAllocate(100);
        assertEq(expectedFlow, 100);
        invariant_AccountedNAVIncludesUnreportedLoss();
        invariant_VaultTransfersConserveCombinedAssets();
    }

    function test_ReturnGhostIncludesTheFollowupSweep() public {
        stepRequest(1000);
        stepCapture();
        stepDeliver();
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
            adapter.totalAssets(), _portfolioCash() + (cumulativeLoss - reportedLoss), "NAV includes unreported loss"
        );
        assertEq(adapter.netFlow(), expectedFlow, "net flow equals observed vault transfers");
        assertFalse(oracle.oracleFrozen());
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: pr.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: snapshots.invariant.fail-on-revert = true
    /// forge-config: default.invariant.max-time-delay = 10
    /// forge-config: pr.invariant.max-time-delay = 10
    /// forge-config: ci.invariant.max-time-delay = 10
    /// forge-config: snapshots.invariant.max-time-delay = 10
    function invariant_ReleasedAndStagedLiquidityRemainCashBacked() public view {
        assertLe(adapter.releasedLiquidity() + adapter.stagedLiquidity(), adapter.freeAssets());
        assertLe(adapter.releasedLiquidity(), adapter.totalAssets());
        assertLe(adapter.deallocatable(), adapter.releasedLiquidity());
        assertLe(adapter.deallocatable(), adapter.totalAssets());
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
        assertEq(realVault.totalAssets(), expectedTotal + (cumulativeLoss - reportedLoss));
        assertEq(asset.balanceOf(address(realVault)) + _portfolioCash(), expectedTotal);
    }

    function _capturePendingReport() internal {
        pendingReport = _capturePortfolio();
        pendingReportLoss = cumulativeLoss;
    }

    function _deliverPendingReport() internal {
        _deliver(pendingReport);
        reportedLoss = pendingReportLoss;
        delete pendingReport;
        delete pendingReportLoss;
    }

    function _ensureFresh() internal {
        if (block.timestamp - oracle.snapshotTimestamp() > oracle.MAX_ORACLE_AGE()) {
            _capturePendingReport();
            _deliverPendingReport();
        }
    }
}
