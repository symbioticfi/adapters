// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

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
        assets = adapter.lockedLiquidity();
        vm.snapshotGasLastCall("MerkleAdapter", "lockedLiquidityEmpty");
        assertEq(assets, 0);
        _stageFixtureCash();
        delegator.requestDeallocate(address(adapter), 100);
        assets = adapter.stagedLiquidity();
        vm.snapshotGasLastCall("MerkleAdapter", "stagedLiquidity");
        assertEq(assets, 1000);
        assets = adapter.lockedLiquidity();
        vm.snapshotGasLastCall("MerkleAdapter", "lockedLiquidity");
        assertEq(assets, 1000);
        assets = adapter.stagedLiquidityAt(uint48(block.number));
        vm.snapshotGasLastCall("MerkleAdapter", "stagedLiquidityAtLatest");
        assertEq(assets, 1000);
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
        vm.snapshotGasLastCall("MerkleAdapter", "requestDeallocate");
        assertEq(adapter.stagedLiquidity(), 0);
        vm.prank(address(delegator));
        adapter.requestDeallocate(0);
        vm.snapshotGasLastCall("MerkleAdapter", "requestDeallocateCancel");

        assertEq(adapter.stagedLiquidity(), 0);

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
    function test_GasPullStagesRequestedCash() public {
        vm.prank(account);
        _fixtureCashToAccount(1000);
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
    function test_GasDeallocationSynchronizationPaths() public {
        _stageFixtureCash();
        _advanceReport();
        _submitReport(_report(1000));
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(address(delegator));
        adapter.deallocate(0);
        vm.snapshotGasLastCall("MerkleAdapter", "deallocateSyncRelease");
        assertEq(adapter.releasedLiquidity(), 1000);
        vm.prank(address(delegator));
        adapter.deallocate(0);
        vm.snapshotGasLastCall("MerkleAdapter", "deallocateSyncedZero");
        _advanceReport();
        _submitReport(_report(900));
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(address(delegator));
        adapter.deallocate(0);
        vm.snapshotGasLastCall("MerkleAdapter", "deallocateSyncLossCap");
        assertEq(adapter.releasedLiquidity(), 900);
        assertEq(adapter.stagedLiquidity(), 0);
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

        assertEq(adapter.releasedLiquidity(), 300);
        vm.prank(address(delegator));
        paid = adapter.deallocate(0);
        vm.snapshotGasLastCall("MerkleAdapter", "deallocateZero");
        assertEq(paid, 0);
        assertEq(adapter.netFlow(), 900);
    }
}

contract MerkleAdapterValuationGasTest is CREOracleTestBase {
    /// forge-config: default.isolate = true
    function test_GasMissingFreshAndDelayedValuation() public {
        assertEq(adapter.totalAssets(), 0);
        vm.snapshotGasLastCall("MerkleAdapter", "totalAssetsUninitialized");

        _fundPortfolio(1000);
        uint256 assets = adapter.totalAssets();
        vm.snapshotGasLastCall("MerkleAdapter", "totalAssetsFresh");
        assertEq(assets, 1000);

        vm.warp(block.timestamp + 365 days);
        assertEq(adapter.totalAssets(), 1000);
        vm.snapshotGasLastCall("MerkleAdapter", "totalAssetsDelayed");
    }
}
