// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {CREOracleTestBase} from "./oracle/CREOracle.t.sol";

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {IMerkleAdapterOracle} from "src/interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";

import {FrontendLiquidityLens} from "@symbioticfi/core/src/contracts/adapters/utils/FrontendLiquidityLens.sol";

contract MerkleAdapterFreeAssetsTest is CREOracleTestBase {
    function test_FreeAssetsExcludesUncoveredCashUntilPullAndReport() public {
        _fundPortfolio(1000);
        assertEq(adapter.freeAssets(), 0);
        vm.prank(account);
        _fixtureCashToAccount(1000);
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
        _fixtureCashToAccount(1000);
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
        _syncLiquidity();
        assertEq(adapter.freeAssets(), 200);
        assertEq(adapter.stagedLiquidity(), 300);
        assertEq(delegator.deallocate(address(adapter), free), free);
        assertEq(adapter.freeAssets(), 0);
    }

    function testFuzz_FreeAssetsCapsUnsyncedCoverageByNAV(uint256 nav) public {
        nav = bound(nav, 0, 999);
        _fundPortfolio(1000);
        _stageFixtureCash();
        delegator.requestDeallocate(address(adapter), 1000);
        _advanceReport();
        ICREOracle.Report memory captured = _report(nav);
        _submitReport(captured);
        if (oracle.snapshotBlock() != captured.snapshotBlock) oracle.acceptReport(abi.encode(captured));

        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.freeAssets(), nav);
        _syncLiquidity();
        assertEq(adapter.freeAssets(), nav);
        assertEq(delegator.deallocate(address(adapter), 1000), nav);
    }

    /// forge-config: default.isolate = true
    function test_FreeAssetsTracksReleasedCashAfterPartialReturn() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        uint256 free = adapter.freeAssets();
        vm.snapshotGasLastCall("MerkleAdapter", "freeAssetsReleased");
        assertEq(free, 1000);
        assertEq(delegator.deallocate(address(adapter), 993), 993);
        assertEq(adapter.releasedLiquidity(), 7);
        assertEq(asset.balanceOf(address(adapter)), 7);
        assertEq(adapter.freeAssets(), 7);
        assertEq(delegator.deallocate(address(adapter), 7), 7);
        assertEq(adapter.freeAssets(), 0);
    }

    function test_FreeAssetsIsZeroAfterTotalLoss() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        _advanceReport();
        _deliverWithReview(_report(0));
        assertEq(asset.balanceOf(address(adapter)), 1000);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(asset.balanceOf(account), 0);
        assertEq(adapter.freeAssets(), 0);
        _stageFixtureCash();
        _advanceReport();
        _deliverWithReview(_report(1000));
        assertEq(asset.balanceOf(address(adapter)), 1000);
        assertEq(asset.balanceOf(account), 0);
        assertEq(adapter.freeAssets(), 1000);
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
