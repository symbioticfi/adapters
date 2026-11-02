// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {IMerkleAdapterOracle} from "src/interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {CREOracleTestBase} from "test/adapters/merkle-adapter/oracle/CREOracle.t.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract MerkleAdapterLossTest is CREOracleTestBase {
    function setUp() public override {
        super.setUp();
        _deliver(_report(0));
        asset.transfer(adapter.vault(), 1000);
        delegator.allocate(address(adapter), 1000);
        _next(1000);
    }

    function test_QueuedWithdrawalSurvivesLossAndPaysAvailableCash() public {
        delegator.requestDeallocate(address(adapter), 1000);
        _realizeLossAndReturn(900);
        _next(900);
        assertEq(adapter.totalAssets(), 900);

        assertEq(delegator.deallocate(address(adapter), 1000), 900);

        assertEq(adapter.totalAssets(), 0);
        _next(0);
        assertEq(adapter.totalAssets(), 0);
    }

    function test_ReviewedLossMakesSurvivingCashReturnableOnDeallocation() public {
        delegator.requestDeallocate(address(adapter), 1000);
        _realizeLossAndReturn(400);
        _advanceReport();
        ICREOracle.Report memory update = _report(400);
        _deliver(update);
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(update)));

        assertEq(adapter.totalAssets(), 1000);
        assertEq(delegator.deallocate(address(adapter), 1000), 0);
        oracle.acceptReport(abi.encode(update));
        assertEq(adapter.totalAssets(), 1000);
        assertEq(delegator.deallocate(address(adapter), 1000), 0);
        vm.roll(block.number + 1);
        assertEq(adapter.totalAssets(), 400);
        assertEq(delegator.deallocate(address(adapter), 1000), 400);

        assertEq(adapter.totalAssets(), 0);
    }

    function testFuzz_WithdrawalIsCappedByNAVAndCash(uint256 requested, uint16 surviving) public {
        surviving = uint16(bound(surviving, 0, 1000));
        delegator.requestDeallocate(address(adapter), requested);
        _realizeLossAndReturn(surviving);
        _advanceReport();
        _deliverWithReview(_report(surviving));
        uint256 paid = requested < surviving ? requested : surviving;
        assertEq(delegator.deallocate(address(adapter), requested), paid);
        assertEq(adapter.totalAssets(), surviving - paid);
    }

    function test_CompleteLossDoesNotInventLiquidityAndWritesDownDemand() public {
        delegator.requestDeallocate(address(adapter), 1000);
        _realizeLossAndReturn(0);
        _advanceReport();
        _deliverWithReview(_report(0));
        assertEq(adapter.totalAssets(), 0);

        assertEq(delegator.deallocate(address(adapter), 1000), 0);
        delegator.requestDeallocate(address(adapter), 0);
    }

    function test_PostSnapshotAllocationSurvivesLossAndRemainsInAccount() public {
        delegator.requestDeallocate(address(adapter), 450);
        _realizeLossAndReturn(400);
        _advanceReport();
        ICREOracle.Report memory update = _report(400);
        asset.transfer(adapter.vault(), 50);
        assertEq(delegator.allocate(address(adapter), 50), 50);
        _deliverWithReview(update);
        _assertReportedAssets(400);
        assertEq(adapter.totalAssets(), 450);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(asset.balanceOf(address(adapter)), 400);
        assertEq(asset.balanceOf(account), 50);
        assertEq(delegator.deallocate(address(adapter), 450), 400);
        assertEq(adapter.totalAssets(), 50);
        vm.prank(account);
        adapter.pull(50);
        _next(50);
        assertEq(delegator.deallocate(address(adapter), 50), 50);
        assertEq(adapter.totalAssets(), 0);
    }

    function test_ReturnedCashCannotExitBeforeLossReport() public {
        delegator.requestDeallocate(address(adapter), 1000);
        _realizeLossAndReturn(900);
        assertEq(delegator.deallocate(address(adapter), 1000), 0);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(adapter.stagedLiquidity(), 900);
        _next(900);
        assertEq(adapter.totalAssets(), 900);
        _assertReportedAssets(900);
        assertEq(delegator.deallocate(address(adapter), 1000), 900);
        assertEq(adapter.totalAssets(), 0);
        assertEq(adapter.netFlow(), 100);
    }

    function test_UnreportedProfitStaysInAdapterUntilValuationRecognizesIt() public {
        asset.transfer(account, 100);
        delegator.requestDeallocate(address(adapter), 1100);
        vm.prank(account);
        adapter.pull(1100);
        assertEq(delegator.deallocate(address(adapter), 1100), 0);
        _next(1100);
        assertEq(delegator.deallocate(address(adapter), 1100), 1100);
        assertEq(adapter.netFlow(), -100);
        assertEq(adapter.totalAssets(), 0);
    }

    function test_DelayedLossWithPreviouslyReleasedPayoutPreservesCurrentNAV() public {
        delegator.requestDeallocate(address(adapter), 150);
        vm.prank(account);
        adapter.pull(150);
        _next(1000);
        vm.prank(account);
        asset.transfer(address(0xdead), 100);
        delegator.requestDeallocate(address(adapter), 1000);
        vm.prank(account);
        adapter.pull(750);
        _advanceReport();
        ICREOracle.Report memory update = _report(900);
        assertEq(delegator.deallocate(address(adapter), 150), 150);
        _deliver(update);
        assertEq(adapter.totalAssets(), 750);
        _assertReportedAssets(900);
        assertEq(delegator.deallocate(address(adapter), 1000), 750);
    }

    function test_TotalAssetsRejectsNegativeNAVAfterPostSnapshotWithdrawal() public {
        vm.prank(account);
        adapter.pull(1000);
        _next(1000);
        uint48 snapshot = oracle.snapshotBlock();
        assertEq(delegator.deallocate(address(adapter), 500), 500);

        vm.mockCall(
            address(oracle), abi.encodeCall(IMerkleAdapterOracle.latestSnapshot, ()), abi.encode(snapshot, uint256(499))
        );
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedIntToUint.selector, int256(-1)));
        adapter.totalAssets();

        vm.mockCall(
            address(oracle), abi.encodeCall(IMerkleAdapterOracle.latestSnapshot, ()), abi.encode(snapshot, uint256(500))
        );
        assertEq(adapter.totalAssets(), 0);
        vm.mockCall(
            address(oracle), abi.encodeCall(IMerkleAdapterOracle.latestSnapshot, ()), abi.encode(snapshot, uint256(501))
        );
        assertEq(adapter.totalAssets(), 1);
    }

    function _realizeLossAndReturn(uint256 surviving) internal {
        vm.startPrank(account);
        asset.transfer(address(0xdead), 1000 - surviving);
        adapter.pull(surviving);
        vm.stopPrank();
    }

    function _next(uint256 assets) internal {
        _advanceReport();
        _deliver(_report(assets));
    }
}
