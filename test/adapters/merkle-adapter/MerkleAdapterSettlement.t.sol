// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {CREOracleTestBase} from "test/adapters/merkle-adapter/oracle/CREOracle.t.sol";

contract MerkleAdapterLiquidityTest is CREOracleTestBase {
    function test_UnrequestedCashStaysInvestableButCannotBeWithdrawn() public {
        _fundPortfolio(1000);
        assertEq(adapter.deallocatable(), 0);
        assertEq(delegator.deallocate(address(adapter), 300), 0);
        assertEq(adapter.totalAssets(), 1000);
        vm.prank(account);
        adapter.push(1000);
        assertEq(asset.balanceOf(account), 1000);
    }

    function test_RequestsProtectCashAndPaymentsNeedCoveringReports() public {
        _fundPortfolio(1000);
        vm.prank(account);
        adapter.push(800);
        delegator.requestDeallocate(address(adapter), 500);
        assertEq(adapter.stagedLiquidity(), 200);
        vm.prank(account);
        vm.expectRevert(IMerkleAdapter.InsufficientIdleAssets.selector);
        adapter.push(1);
        assertEq(delegator.deallocate(address(adapter), 500), 0);
        _next(1000);
        assertEq(delegator.deallocate(address(adapter), 500), 200);
        assertEq(adapter.pendingDeallocation(), 300);
        vm.prank(account);
        adapter.pull(400);
        assertEq(adapter.stagedLiquidity(), 300);
        assertEq(adapter.deallocatable(), 0);
        _next(800);
        assertEq(delegator.deallocate(address(adapter), 300), 300);
        assertEq(adapter.pendingDeallocation(), 0);
        vm.prank(account);
        adapter.push(100);
        assertEq(adapter.totalAssets(), 500);
    }

    function test_IlliquidDemandDefersWithoutFreezingReport() public {
        _fundPortfolio(1000);
        vm.prank(account);
        adapter.push(1000);
        delegator.requestDeallocate(address(adapter), type(uint256).max);
        _next(1000);
        assertFalse(oracle.oracleFrozen());
        assertEq(adapter.pendingDeallocation(), 1000);
        assertEq(adapter.deallocatable(), 0);
        vm.prank(account);
        adapter.pull(200);
        assertEq(delegator.deallocate(address(adapter), 1000), 0);
        _next(1000);
        assertEq(delegator.deallocate(address(adapter), 1000), 200);
        assertEq(adapter.pendingDeallocation(), 800);
        assertEq(adapter.totalAssets(), 800);
    }

    function test_AllocationDoesNotNetRequestsOrRefundUnreleasedCash() public {
        _fundPortfolio(1000);
        vm.prank(account);
        adapter.push(1000);
        delegator.requestDeallocate(address(adapter), 300);
        asset.transfer(adapter.vault(), 500);
        assertEq(delegator.allocate(address(adapter), 200), 200);
        assertEq(adapter.pendingDeallocation(), 300);
        assertEq(adapter.stagedLiquidity(), 200);
        assertEq(delegator.allocate(address(adapter), 300), 300);
        assertEq(adapter.stagedLiquidity(), 200, "later cash cannot enlarge an existing snapshot batch");
        assertEq(adapter.netFlow(), 1500);
        assertEq(asset.balanceOf(adapter.vault()), 0);
        assertEq(delegator.deallocate(address(adapter), 300), 0);
        _next(1500);
        assertEq(adapter.releasedLiquidity(), 200);
        assertEq(adapter.stagedLiquidity(), 100);
        assertEq(delegator.deallocate(address(adapter), 300), 200);
        _next(1300);
        assertEq(delegator.deallocate(address(adapter), 300), 100);
        assertEq(adapter.totalAssets(), 1200);
    }

    function test_DelayedPreReturnReportCannotReleaseLaterCash() public {
        _fundPortfolio(1000);
        vm.prank(account);
        adapter.push(1000);
        delegator.requestDeallocate(address(adapter), 500);
        _advanceReport();
        ICREOracle.Report memory captured = _report(1000);
        vm.prank(account);
        adapter.pull(500);
        _deliver(captured);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.stagedLiquidity(), 500);
        assertEq(delegator.deallocate(address(adapter), 500), 0);
        _next(1000);
        assertEq(delegator.deallocate(address(adapter), 500), 500);
    }

    function test_PermissionlessStagingCapsDirectReturnsAtDemandAndDoesNotResetAge() public {
        _fundPortfolio(1000);
        vm.prank(account);
        adapter.push(1000);
        delegator.requestDeallocate(address(adapter), 400);
        vm.prank(account);
        asset.transfer(address(adapter), 300);
        vm.prank(address(0xbeef));
        adapter.stageLiquidity();
        uint48 stagedBlock = adapter.stagedBlock();
        assertEq(adapter.stagedLiquidity(), 300);
        vm.roll(block.number + 1);
        vm.prank(account);
        asset.transfer(address(adapter), 200);
        adapter.stageLiquidity();
        assertEq(adapter.stagedLiquidity(), 300);
        assertEq(adapter.stagedBlock(), stagedBlock);
        _next(1000);
        assertEq(adapter.releasedLiquidity(), 300);
        assertEq(adapter.stagedLiquidity(), 100);
    }

    function test_RejectedReportAndEmptyUnfreezeDoNotReleaseLiquidity() public {
        _fundPortfolio(1000);
        delegator.requestDeallocate(address(adapter), 300);
        uint48 acceptedBlock = oracle.snapshotBlock();
        _next(0);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.snapshotBlock(), acceptedBlock);
        assertEq(adapter.deallocatable(), 0);
        assertEq(adapter.stagedLiquidity(), 300);
        vm.expectRevert(ICREOracle.OracleFrozen.selector);
        delegator.deallocate(address(adapter), 300);
        oracle.unfreezeOracle("");
        assertEq(adapter.deallocatable(), 0);
        _next(1000);
        assertEq(adapter.deallocatable(), 300);
    }

    function test_CancelledDemandCannotReinvestReleasedOrStagedCash() public {
        _fundPortfolio(1000);
        delegator.requestDeallocate(address(adapter), 300);
        delegator.requestDeallocate(address(adapter), 0);
        vm.prank(account);
        adapter.push(700);
        vm.prank(account);
        vm.expectRevert(IMerkleAdapter.InsufficientIdleAssets.selector);
        adapter.push(1);
        _next(1000);
        assertEq(adapter.releasedLiquidity(), 300);
        vm.prank(account);
        vm.expectRevert(IMerkleAdapter.InsufficientIdleAssets.selector);
        adapter.push(1);
        assertEq(delegator.deallocate(address(adapter), 300), 300);
        assertEq(adapter.totalAssets(), 700);
    }

    function test_DeallocateDoesNotStageCashBeforeDelegatorTransfersItOut() public {
        _fundPortfolio(1000);
        vm.prank(account);
        adapter.push(1000);
        delegator.requestDeallocate(address(adapter), 500);
        vm.prank(account);
        adapter.pull(200);
        _next(1000);
        assertEq(adapter.releasedLiquidity(), 200);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(delegator.deallocate(address(adapter), 500), 200);
        assertEq(adapter.freeAssets(), 0);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(adapter.pendingDeallocation(), 300);
        _next(800);
        assertEq(adapter.deallocatable(), 0);
        vm.prank(account);
        adapter.pull(300);
        assertEq(adapter.deallocatable(), 0);
        _next(800);
        assertEq(delegator.deallocate(address(adapter), 300), 300);
    }

    function test_OnlyOracleCanSettleLiquidity() public {
        _fundPortfolio(1000);
        delegator.requestDeallocate(address(adapter), 300);
        vm.expectRevert(IMerkleAdapter.InvalidCaller.selector);
        adapter.settleReport(uint48(block.number), 1000);
        assertEq(adapter.deallocatable(), 0);
    }

    function test_DeallocateHasNoOracleValidationInsideTheAdapter() public {
        _fundPortfolio(1000);
        delegator.requestDeallocate(address(adapter), 150);
        _next(1000);
        oracle.freezeOracle();
        vm.prank(address(delegator));
        assertEq(adapter.deallocate(150), 150);
        assertEq(adapter.netFlow(), 850);
        assertEq(oracle.totalAssets(), 850);
        assertEq(asset.balanceOf(address(adapter)), 1000);
    }

    function testFuzz_PartialReturnsPreserveDemandAndConserveAssets(uint96 request, uint16 liquid, uint16 payout)
        public
    {
        liquid = uint16(bound(liquid, 0, 1000));
        payout = uint16(bound(payout, 0, 1500));
        _fundPortfolio(1000);
        vm.prank(account);
        adapter.push(1000 - liquid);
        delegator.requestDeallocate(address(adapter), request);
        uint256 covered = request < liquid ? request : liquid;
        assertEq(delegator.deallocate(address(adapter), payout), 0);
        _next(1000);
        uint256 paid = payout < covered ? payout : covered;
        assertEq(delegator.deallocate(address(adapter), payout), paid);
        assertEq(adapter.pendingDeallocation(), (request < 1000 ? request : 1000) - paid);
        assertEq(adapter.releasedLiquidity(), covered - paid);
        assertEq(adapter.totalAssets(), 1000 - paid);
        assertEq(adapter.netFlow(), int256(1000 - paid));
        assertEq(asset.balanceOf(adapter.vault()), paid);
        _next(1000 - paid);
        assertFalse(oracle.oracleFrozen());
        assertEq(adapter.totalAssets(), 1000 - paid);
    }

    function _next(uint256 assets) internal {
        _advanceReport();
        _deliver(_report(assets));
    }
}
