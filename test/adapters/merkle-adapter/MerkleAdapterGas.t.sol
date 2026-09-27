// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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
        assertEq(assets, 1000);
        int256 flow = adapter.netFlow();
        vm.snapshotGasLastCall("MerkleAdapter", "netFlow");
        assertEq(flow, 1000);
        flow = adapter.netFlowAt(uint48(block.number - 1));
        vm.snapshotGasLastCall("MerkleAdapter", "netFlowAtLatest");
        assertEq(flow, 1000);
        flow = adapter.netFlowAt(0);
        vm.snapshotGasLastCall("MerkleAdapter", "netFlowAtBeforeFirst");
        assertEq(flow, 0);
    }

    /// forge-config: default.isolate = true
    function test_GasDeallocatableBounds() public {
        uint256 assets = adapter.deallocatable();
        vm.snapshotGasLastCall("MerkleAdapter", "deallocatableUnreleased");
        assertEq(assets, 0);
        _releasePortfolio(400);
        assets = adapter.deallocatable();
        vm.snapshotGasLastCall("MerkleAdapter", "deallocatableReleased");
        assertEq(assets, 400);

        vm.prank(address(adapter));
        asset.transfer(address(0xbeef), 800);
        assets = adapter.deallocatable();
        vm.snapshotGasLastCall("MerkleAdapter", "deallocatableCashBound");
        assertEq(assets, 200);

        _advanceReport();
        _deliverWithReview(_report(100));
        assets = adapter.deallocatable();
        vm.snapshotGasLastCall("MerkleAdapter", "deallocatableNAVBound");
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
        vm.snapshotGasLastCall("MerkleAdapter", "requestDeallocateCancel");
        assertEq(adapter.pendingDeallocation(), 0);
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
        vm.snapshotGasLastCall("MerkleAdapter", "stageLiquidityNewBatch");
        assertEq(adapter.stagedLiquidity(), 200);
        adapter.stageLiquidity();
        vm.snapshotGasLastCall("MerkleAdapter", "stageLiquidityExistingBatch");
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
        vm.snapshotGasLastCall("MerkleAdapter", "pullExistingBatch");
        assertEq(adapter.stagedLiquidity(), 200);
        assertEq(asset.balanceOf(account), 700);
    }

    /// forge-config: default.isolate = true
    function test_GasSettleReportPaths() public {
        vm.prank(account);
        adapter.push(800);
        delegator.requestDeallocate(address(adapter), 500);
        uint48 stagedBlock = adapter.stagedBlock();
        vm.prank(account);
        asset.transfer(address(adapter), 400);
        vm.prank(address(oracle));
        adapter.settleReport(stagedBlock - 1, 1000);
        vm.snapshotGasLastCall("MerkleAdapter", "settleReportUncoveredBatch");
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.stagedLiquidity(), 200);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(address(oracle));
        adapter.settleReport(stagedBlock, 1000);
        vm.snapshotGasLastCall("MerkleAdapter", "settleReportReleaseAndRestage");
        assertEq(adapter.releasedLiquidity(), 200);
        assertEq(adapter.stagedLiquidity(), 300);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(address(oracle));
        adapter.settleReport(uint48(vm.getBlockNumber() - 1), 1000);
        vm.snapshotGasLastCall("MerkleAdapter", "settleReportRelease");
        assertEq(adapter.releasedLiquidity(), 500);
        assertEq(adapter.stagedLiquidity(), 0);
        vm.prank(address(oracle));
        adapter.settleReport(uint48(vm.getBlockNumber() - 1), 100);
        vm.snapshotGasLastCall("MerkleAdapter", "settleReportLossCap");
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
