// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {CREOracleTestBase} from "./oracle/CREOracle.t.sol";

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {IMerkleAdapterOracle} from "src/interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";

import {FrontendLiquidityLens} from "@symbioticfi/core/src/contracts/adapters/utils/FrontendLiquidityLens.sol";

contract MerkleAdapterFreeAssetsTest is CREOracleTestBase {
    function test_FreeAssetsExcludesUncoveredCashWithoutBlockingPushOrStage() public {
        _fundPortfolio(1000);
        assertEq(adapter.freeAssets(), 0);
        vm.prank(account);
        adapter.push(1000);
        delegator.requestDeallocate(address(adapter), 500);
        vm.prank(account);
        adapter.pull(200);
        assertEq(asset.balanceOf(address(adapter)), 200);
        assertEq(adapter.stagedLiquidity(), 200);
        assertEq(adapter.freeAssets(), 0);
    }

    function test_FrontendLensExcludesDonationsWithoutUnderflow() public {
        _fundPortfolio(1000);
        asset.transfer(address(adapter), 2000);
        address lens = address(new MerkleLiquidityLensHarness());
        assertEq(MerkleLiquidityLensHarness(lens).freeLiquidity(address(adapter), address(asset)), 0);
        assertEq(adapter.totalAssets(), 1000);
    }

    /// forge-config: default.isolate = true
    function test_FreeAssetsIncludesUnsyncedCoverageAndExcludesLaterReturns() public {
        _fundPortfolio(1000);
        vm.prank(account);
        adapter.push(1000);
        delegator.requestDeallocate(address(adapter), 500);
        vm.prank(account);
        adapter.pull(200);
        _advanceReport();
        ICREOracle.Report memory captured = _report(1000);
        vm.prank(account);
        adapter.pull(300);
        _submitReport(captured);

        assertEq(adapter.releasedLiquidity(), 0);
        uint256 free = adapter.freeAssets();
        vm.snapshotGasLastCall("MerkleAdapter", "freeAssetsUnsynced");
        assertEq(free, 200);
        adapter.syncReport();
        assertEq(adapter.freeAssets(), 200);
        assertEq(adapter.stagedLiquidity(), 300);
        assertEq(delegator.deallocate(address(adapter), free), free);
        assertEq(adapter.freeAssets(), 0);
    }

    function testFuzz_FreeAssetsCapsUnsyncedCoverageByNAV(uint256 nav) public {
        nav = bound(nav, 0, 999);
        _fundPortfolio(1000);
        delegator.requestDeallocate(address(adapter), 1000);
        _advanceReport();
        ICREOracle.Report memory captured = _report(nav);
        _submitReport(captured);
        if (oracle.snapshotBlock() != captured.snapshotBlock) oracle.acceptReport(abi.encode(captured));

        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.freeAssets(), nav);
        adapter.syncReport();
        assertEq(adapter.freeAssets(), nav);
        assertEq(delegator.deallocate(address(adapter), 1000), nav);
    }

    /// forge-config: default.isolate = true
    function test_FreeAssetsCapsReleasedCoverageByCash() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        deal(address(asset), address(adapter), 7);
        uint256 free = adapter.freeAssets();
        vm.snapshotGasLastCall("MerkleAdapter", "freeAssetsCashBound");
        assertEq(free, 7);
        assertEq(delegator.deallocate(address(adapter), free), free);
        assertEq(adapter.freeAssets(), 0);
    }

    function test_FreeAssetsIsZeroAfterTotalLoss() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        _advanceReport();
        _deliverWithReview(_report(0));
        assertEq(asset.balanceOf(address(adapter)), 1000);
        assertEq(adapter.freeAssets(), 0);
    }

    function test_FreeAssetsRemainsAvailableAfterDelay() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertEq(adapter.freeAssets(), 1000);
    }
}

contract MerkleLiquidityLensHarness is FrontendLiquidityLens {
    function freeLiquidity(address adapter, address asset) public view returns (uint256) {
        (Leg memory leg,) = _leg(adapter, asset);
        return leg.free;
    }
}
