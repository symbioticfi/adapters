// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CREOracleTestBase} from "./oracle/CREOracle.t.sol";

contract MerkleReturnedCashTest is CREOracleTestBase {
    function test_PartialPayoutLeavesRemainingCoverageAfterDemandIsPaid() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(1000);
        delegator.requestDeallocate(address(adapter), 100);
        vm.prank(account);
        adapter.pull(300);
        _advanceReport();
        _deliver(_report(1000));

        assertEq(delegator.deallocate(address(adapter), 100), 100);

        assertEq(adapter.releasedLiquidity(), 200);
        assertEq(adapter.freeAssets(), 200);
        _syncLiquidity();
        assertEq(adapter.lockedLiquidity(), 200);
        assertEq(asset.balanceOf(address(adapter)), 200);
        assertEq(asset.balanceOf(account), 700);
        assertEq(adapter.totalAssets(), 900);
        assertEq(adapter.netFlow(), 900);
        assertEq(delegator.deallocate(address(adapter), 200), 200);
        assertEq(adapter.totalAssets(), 700);
        assertEq(adapter.netFlow(), 700);
    }

    function testFuzz_ReturnAboveDemandIsFullyStaged(uint16 returned) public {
        returned = uint16(bound(returned, 101, 1000));
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(1000);
        delegator.requestDeallocate(address(adapter), 100);
        vm.prank(account);
        adapter.pull(returned);

        assertEq(adapter.stagedLiquidity(), returned);
        assertEq(asset.balanceOf(address(adapter)), returned);
        assertEq(adapter.freeAssets(), 0);
        _advanceReport();
        _deliver(_report(1000));
        assertEq(adapter.releasedLiquidity(), returned);
        assertEq(adapter.freeAssets(), returned);
        assertEq(delegator.deallocate(address(adapter), returned), returned);

        assertEq(adapter.totalAssets(), 1000 - returned);
    }

    function test_ZeroDemandReturnWaitsForCoverageBeforeDeallocation() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(1000);
        vm.prank(account);
        adapter.pull(600);

        uint48 stagedAt = uint48(block.number);
        assertEq(adapter.stagedLiquidity(), 600);
        assertEq(adapter.lockedLiquidity(), 600);
        assertEq(asset.balanceOf(address(adapter)), 600);
        assertEq(adapter.freeAssets(), 0);
        _advanceReport();
        _submitReport(_report(1000));
        assertEq(adapter.freeAssets(), 0);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(adapter.freeAssets(), 600);
        _syncLiquidity();
        assertEq(adapter.releasedLiquidity(), 600);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(adapter.stagedLiquidityAt(stagedAt), 600);
        assertEq(asset.balanceOf(address(adapter)), 600);
        assertEq(asset.balanceOf(account), 400);
        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.totalAssets(), 1000);

        _advanceReport();
        _deliver(_report(1000));
        assertEq(adapter.releasedLiquidity(), 600, "coverage cannot be released twice");
        assertEq(delegator.deallocate(address(adapter), 1000), 600);
        assertEq(adapter.totalAssets(), 400);
        assertEq(adapter.netFlow(), 400);
    }

    function test_CancellationPreservesReleasedCashAndLaterStaging() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(1000);
        delegator.requestDeallocate(address(adapter), 100);
        vm.prank(account);
        adapter.pull(300);
        _advanceReport();
        _deliver(_report(1000));
        vm.prank(account);
        adapter.pull(200);
        delegator.requestDeallocate(address(adapter), 0);

        assertEq(adapter.releasedLiquidity(), 300);
        assertEq(adapter.stagedLiquidity(), 200);
        assertEq(asset.balanceOf(address(adapter)), 500);
        assertEq(asset.balanceOf(account), 500);
        assertEq(adapter.freeAssets(), 300);
        assertEq(adapter.netFlow(), 1000);
        _advanceReport();
        _deliver(_report(1000));
        assertEq(adapter.lockedLiquidity(), 500);
        assertEq(asset.balanceOf(account), 500);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(delegator.deallocate(address(adapter), 1000), 500);
    }

    function test_ZeroDemandUnsyncedCoverageMatchesActualDeallocation() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(1000);
        delegator.requestDeallocate(address(adapter), 500);
        vm.prank(account);
        adapter.pull(500);
        _advanceReport();
        _submitReport(_report(1000));
        delegator.requestDeallocate(address(adapter), 0);

        assertEq(adapter.stagedLiquidity(), 500);
        assertEq(adapter.freeAssets(), 0);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(adapter.freeAssets(), 500);
        assertEq(delegator.deallocate(address(adapter), 500), 500);
        assertEq(adapter.lockedLiquidity(), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(account), 500);
        assertEq(adapter.totalAssets(), 500);
        assertEq(adapter.netFlow(), 500);
    }
}
