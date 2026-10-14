// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMerkleAdapterOracle} from "src/interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {CREOracleTestBase} from "./oracle/CREOracle.t.sol";

contract MerkleAdapterGasTest is CREOracleTestBase {
    function setUp() public override {
        super.setUp();
        _fundPortfolio(1000);
    }

    /// forge-config: default.isolate = true
    function test_GasPortfolioAndFlowReads() public {
        uint256 assets = adapter.totalAssets();
        vm.snapshotGasLastCall("MerkleAdapter", "totalAssets");
        assertEq(assets, 1000);
        assets = adapter.allocatable();
        vm.snapshotGasLastCall("MerkleAdapter", "allocatable");
        assertEq(assets, type(uint256).max);
        assets = adapter.freeAssets();
        vm.snapshotGasLastCall("MerkleAdapter", "freeAssets");
        assertEq(assets, 0);
        int256 flow = adapter.netFlow();
        vm.snapshotGasLastCall("MerkleAdapter", "netFlow");
        assertEq(flow, 1000);
        flow = adapter.netFlowAt(uint48(block.number - 1));
        vm.snapshotGasLastCall("MerkleAdapter", "netFlowAtLatest");
        assertEq(flow, 1000);
        flow = adapter.netFlowAt(0);
        vm.snapshotGasLastCall("MerkleAdapter", "netFlowAtBeforeFirst");
        assertEq(flow, 0);
        assets = adapter.stagedLiquidity();
        vm.snapshotGasLastCall("MerkleAdapter", "stagedLiquidityEmpty");
        assertEq(assets, 0);
        delegator.requestDeallocate(address(adapter), 100);
        assets = adapter.stagedLiquidity();
        vm.snapshotGasLastCall("MerkleAdapter", "stagedLiquidity");
        assertEq(assets, 100);
        assets = adapter.stagedLiquidityAt(uint48(block.number));
        vm.snapshotGasLastCall("MerkleAdapter", "stagedLiquidityAtLatest");
        assertEq(assets, 100);
        assets = adapter.stagedLiquidityAt(0);
        vm.snapshotGasLastCall("MerkleAdapter", "stagedLiquidityAtBeforeFirst");
        assertEq(assets, 0);
    }

    /// forge-config: default.isolate = true
    function test_GasDeallocateReleasedBound() public {
        _releasePortfolio(400);
        vm.prank(address(delegator));
        uint256 assets = adapter.deallocate(1000);
        vm.snapshotGasLastCall("MerkleAdapter", "deallocateReleasedBound");
        assertEq(assets, 400);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.netFlow(), 600);
    }

    /// forge-config: default.isolate = true
    function test_GasDeallocateNAVBound() public {
        _releasePortfolio(400);
        _advanceReport();
        _deliverWithReview(_report(100));
        vm.prank(address(delegator));
        uint256 assets = adapter.deallocate(1000);
        vm.snapshotGasLastCall("MerkleAdapter", "deallocateNAVBound");
        assertEq(assets, 100);
    }

    /// forge-config: default.isolate = true
    function test_GasAllocationAndRequestPaths() public {
        vm.prank(address(delegator));
        adapter.requestDeallocate(400);
        vm.snapshotGasLastCall("MerkleAdapter", "requestDeallocateStage");
        assertEq(adapter.stagedLiquidity(), 400);
        vm.prank(address(delegator));
        adapter.requestDeallocate(0);
        vm.snapshotGasLastCall("MerkleAdapter", "requestDeallocateIgnoreDecrease");
        assertEq(adapter.pendingDeallocation(), 400);
        assertEq(adapter.stagedLiquidity(), 400);

        asset.transfer(address(adapter), 100);
        vm.prank(address(delegator));
        uint256 allocated = adapter.allocate(100);
        vm.snapshotGasLastCall("MerkleAdapter", "allocateNewCheckpoint");
        assertEq(allocated, 100);
        assertEq(adapter.netFlow(), 1100);
        asset.transfer(address(adapter), 50);
        vm.prank(address(delegator));
        allocated = adapter.allocate(50);
        vm.snapshotGasLastCall("MerkleAdapter", "allocateSameBlock");
        assertEq(allocated, 50);
        assertEq(adapter.netFlow(), 1150);
        vm.prank(address(delegator));
        allocated = adapter.allocate(0);
        vm.snapshotGasLastCall("MerkleAdapter", "allocateZero");
        assertEq(allocated, 0);
        assertEq(adapter.totalAssets(), 1150);
    }

    /// forge-config: default.isolate = true
    function test_GasStageLiquidityPaths() public {
        adapter.stageLiquidity();
        vm.snapshotGasLastCall("MerkleAdapter", "stageLiquidityNoDemand");
        vm.prank(account);
        adapter.push(1000);
        vm.snapshotGasLastCall("MerkleAdapter", "push");
        vm.prank(address(delegator));
        adapter.requestDeallocate(500);
        vm.snapshotGasLastCall("MerkleAdapter", "requestDeallocateNoCash");
        adapter.stageLiquidity();
        vm.snapshotGasLastCall("MerkleAdapter", "stageLiquidityNoCash");
        assertEq(adapter.stagedLiquidity(), 0);
        vm.prank(account);
        asset.transfer(address(adapter), 200);
        adapter.stageLiquidity();
        vm.snapshotGasLastCall("MerkleAdapter", "stageLiquidityNewCheckpoint");
        assertEq(adapter.stagedLiquidity(), 200);
        adapter.stageLiquidity();
        vm.snapshotGasLastCall("MerkleAdapter", "stageLiquidityAlreadyLocked");
        assertEq(adapter.stagedLiquidity(), 200);
    }

    /// forge-config: default.isolate = true
    function test_GasPullStagesRequestedCash() public {
        vm.prank(account);
        adapter.push(1000);
        delegator.requestDeallocate(address(adapter), 500);
        vm.prank(account);
        adapter.pull(200);
        vm.snapshotGasLastCall("MerkleAdapter", "pullStage");
        assertEq(adapter.stagedLiquidity(), 200);
        assertEq(asset.balanceOf(account), 800);
        vm.prank(account);
        adapter.pull(100);
        vm.snapshotGasLastCall("MerkleAdapter", "pullSameBlockCheckpoint");
        assertEq(adapter.stagedLiquidity(), 300);
        assertEq(asset.balanceOf(account), 700);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(account);
        adapter.pull(100);
        vm.snapshotGasLastCall("MerkleAdapter", "pullNewBlockCheckpoint");
        assertEq(adapter.stagedLiquidity(), 400);
        assertEq(asset.balanceOf(account), 600);
    }

    /// forge-config: default.isolate = true
    function test_GasSyncReportReleasesCoveredCashAndStagesPreviouslyUntrackedCash() public {
        vm.prank(account);
        adapter.push(800);
        delegator.requestDeallocate(address(adapter), 500);
        _advanceReport();
        _submitReport(_report(1000));
        vm.prank(account);
        asset.transfer(address(adapter), 300);
        adapter.syncReport();
        vm.snapshotGasLastCall("MerkleAdapter", "syncReportReleaseAndRestage");
        assertEq(adapter.releasedLiquidity(), 200);
        assertEq(adapter.stagedLiquidity(), 300);
    }

    /// forge-config: default.isolate = true
    function test_GasSyncReportPaths() public {
        vm.prank(account);
        adapter.push(800);
        delegator.requestDeallocate(address(adapter), 500);
        vm.prank(account);
        asset.transfer(address(adapter), 400);
        adapter.syncReport();
        vm.snapshotGasLastCall("MerkleAdapter", "syncReportUnchanged");
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.stagedLiquidity(), 500);
        _advanceReport();
        _submitReport(_report(1000));
        adapter.syncReport();
        vm.snapshotGasLastCall("MerkleAdapter", "syncReportReleaseCoveredCheckpoints");
        assertEq(adapter.releasedLiquidity(), 500);
        assertEq(adapter.stagedLiquidity(), 0);
        _advanceReport();
        _submitReport(_report(1000));
        adapter.syncReport();
        vm.snapshotGasLastCall("MerkleAdapter", "syncReportRelease");
        assertEq(adapter.releasedLiquidity(), 500);
        assertEq(adapter.stagedLiquidity(), 0);
        _advanceReport();
        _submitReport(_report(100));
        oracle.acceptReport(abi.encode(_report(100)));
        adapter.syncReport();
        vm.snapshotGasLastCall("MerkleAdapter", "syncReportLossCap");
        assertEq(adapter.releasedLiquidity(), 100);
        assertEq(adapter.pendingDeallocation(), 100);
    }

    /// forge-config: default.isolate = true
    function test_GasDeallocateWithoutRelease() public {
        vm.prank(address(delegator));
        uint256 paid = adapter.deallocate(100);
        vm.snapshotGasLastCall("MerkleAdapter", "deallocateUnreleased");
        assertEq(paid, 0);
        assertEq(adapter.netFlow(), 1000);
    }

    /// forge-config: default.isolate = true
    function test_GasDeallocateReleased() public {
        _releasePortfolio(400);
        vm.prank(address(delegator));
        uint256 paid = adapter.deallocate(100);
        vm.snapshotGasLastCall("MerkleAdapter", "deallocateReleased");
        assertEq(paid, 100);
        assertEq(adapter.netFlow(), 900);
        assertEq(adapter.pendingDeallocation(), 300);
        assertEq(adapter.releasedLiquidity(), 300);
        vm.prank(address(delegator));
        paid = adapter.deallocate(0);
        vm.snapshotGasLastCall("MerkleAdapter", "deallocateZero");
        assertEq(paid, 0);
        assertEq(adapter.netFlow(), 900);
    }
}

/// @dev Reverting reads use regions because Foundry does not retain a reverted last-call frame.
contract MerkleAdapterValuationGasTest is CREOracleTestBase {
    /// forge-config: default.isolate = true
    function test_GasMissingFreshAndDelayedValuation() public {
        vm.expectRevert(IMerkleAdapterOracle.OracleStale.selector);
        vm.startSnapshotGas("MerkleAdapter", "totalAssetsUninitializedRegion");
        adapter.totalAssets();
        vm.stopSnapshotGas();

        _fundPortfolio(1000);
        uint256 assets = adapter.totalAssets();
        vm.snapshotGasLastCall("MerkleAdapter", "totalAssetsFresh");
        assertEq(assets, 1000);

        vm.warp(uint256(oracle.snapshotTimestamp()) + 365 days);
        assertEq(adapter.totalAssets(), 1000);
        vm.snapshotGasLastCall("MerkleAdapter", "totalAssetsDelayed");
    }
}
