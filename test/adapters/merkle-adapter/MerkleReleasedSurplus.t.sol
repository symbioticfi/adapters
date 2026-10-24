// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {CREOracleTestBase} from "./oracle/CREOracle.t.sol";

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";

contract MerkleReleasedSurplusTest is CREOracleTestBase {
    function testFuzz_CancellationPreservesCoveredCashForDeallocation(uint16 remaining, bool alreadyReleased) public {
        remaining = uint16(bound(remaining, 0, 499));
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(500);
        delegator.requestDeallocate(address(adapter), 500);
        uint48 stagedAt = uint48(block.number);
        if (alreadyReleased) {
            _advanceReport();
            _deliver(_report(1000));
        }

        delegator.requestDeallocate(address(adapter), remaining);
        if (!alreadyReleased) {
            assertEq(adapter.stagedLiquidity(), 500, "uncovered staging must never shrink");
            assertEq(asset.balanceOf(address(adapter)), 500);
            _advanceReport();
            _submitReport(_report(1000));
            assertEq(adapter.freeAssets(), 0);
            vm.roll(vm.getBlockNumber() + 1);
        }
        assertEq(adapter.freeAssets(), 500, "covered cash remains available beyond pending demand");
        _syncLiquidity();
        assertEq(adapter.releasedLiquidity(), 500);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(adapter.stagedLiquidityAt(stagedAt), 500, "cumulative history must not be rewritten");
        assertEq(asset.balanceOf(address(adapter)), 500);
        assertEq(asset.balanceOf(account), 500);
        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(delegator.deallocate(address(adapter), 1000), 500);

        _advanceReport();
        _deliver(_report(500));
        assertEq(adapter.releasedLiquidity(), 0, "paid coverage cannot be released again");
        assertEq(adapter.totalAssets(), 500);
    }

    function test_DelayedPartialCoveragePreservesLaterStaging() public {
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
        delegator.requestDeallocate(address(adapter), 100);
        assertEq(adapter.stagedLiquidity(), 500);

        _deliver(captured);
        assertEq(adapter.releasedLiquidity(), 200);
        assertEq(adapter.stagedLiquidity(), 300);
        assertEq(asset.balanceOf(address(adapter)), 500);
        assertEq(asset.balanceOf(account), 500);
        assertEq(delegator.deallocate(address(adapter), 500), 200);

        assertEq(adapter.stagedLiquidity(), 300);

        _advanceReport();
        _deliver(_report(800));
        assertEq(adapter.releasedLiquidity(), 300);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(asset.balanceOf(address(adapter)), 300);
        assertEq(asset.balanceOf(account), 500);
        assertEq(delegator.deallocate(address(adapter), 500), 300);
        assertEq(adapter.totalAssets(), 500);
        assertEq(adapter.netFlow(), 500);
    }
}
