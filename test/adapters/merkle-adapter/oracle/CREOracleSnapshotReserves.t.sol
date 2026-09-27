// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {CREOracleTestBase} from "./CREOracle.t.sol";
import {MerkleDeallocationHarness} from "./CREOracleDeallocate.t.sol";
import {MerkleAdapterVaultMock} from "test/adapters/MerkleAdapter.t.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ORACLE_LIMITS_ROLE, ORACLE_LIMIT_PRECISION} from "src/interfaces/merkle-adapter/oracle/ICREOracleBase.sol";

/// @dev Regression coverage for whole-portfolio snapshots reconciled against on-chain capital flows.
contract CREOracleSnapshotReservesTest is CREOracleTestBase {
    MerkleDeallocationHarness internal withdrawalPath;

    function setUp() public override {
        super.setUp();
        withdrawalPath = new MerkleDeallocationHarness(adapter.vault());
    }

    function test_SnapshotsBeforeAndAfterWithdrawalBothValueThePortfolioAt850() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        _advanceReport();
        ICREOracle.Report memory beforeWithdrawal = _report(1000);
        _withdraw(150);
        assertEq(oracle.totalAssets(), 850);
        _deliver(beforeWithdrawal);
        assertEq(oracle.totalAssets(), 850);
        assertEq(adapter.totalAssets(), 850);
        _advanceReport();
        _deliver(_report(850));
        assertEq(oracle.totalAssets(), 850);
        assertEq(oracle.valuationOffset(), 0);
    }

    function testFuzz_DelayedReportDoesNotRestoreWithdrawnAssets(
        uint96 gross,
        uint96 withdrawal,
        bool snapshotAfterWithdrawal
    ) public {
        gross = uint96(bound(gross, 1, 100_000e18));
        withdrawal = uint96(bound(withdrawal, 1, gross));
        _fundPortfolio(gross);
        _releasePortfolio(gross);
        _advanceReport();
        ICREOracle.Report memory update = _report(gross);
        _withdraw(withdrawal);
        if (snapshotAfterWithdrawal) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 1);
            update = _report(gross - withdrawal);
        }
        _deliver(update);
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), gross - withdrawal);
        assertEq(adapter.totalAssets(), gross - withdrawal);
        assertEq(asset.balanceOf(address(adapter)), gross - withdrawal);
    }

    function test_FullWithdrawalBeforeAcceptanceLeavesNoGhostAssets() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        _advanceReport();
        ICREOracle.Report memory update = _report(1000);
        _withdraw(1000);
        _deliver(update);
        assertEq(oracle.totalAssets(), 0);
        assertEq(oracle.valuationOffset(), 0);
        assertEq(asset.balanceOf(adapter.vault()), 1000);
    }

    function test_PostSnapshotFlowsAreCountedExactlyOnceAndRequestsDoNotChangeNAV() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        _allocate(300);
        _advanceReport();
        ICREOracle.Report memory update = _report(1300);
        _allocate(100);
        delegator.requestDeallocate(address(adapter), 150);
        assertEq(oracle.totalAssets(), 1400);
        _withdraw(300);
        _deliver(update);
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 1100);
        assertEq(adapter.netFlow(), 1100);
        assertEq(oracle.valuationOffset(), 0);
        _advanceReport();
        _deliver(_report(1100));
        assertEq(adapter.totalAssets(), 1100);
    }

    function testFuzz_MovementLimitsCompareHistoricalFlowAdjustedNAV(bool loss, bool exceedsLimit) public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        _allocate(1000);
        _advanceReport();
        uint256 delta = exceedsLimit ? 201 : 200;
        uint256 reported = loss ? 2000 - delta : 2000 + delta;
        ICREOracle.Report memory update = _report(reported);
        _withdraw(500); // The limit uses snapshot NAV 2000, not current NAV 1500.
        _deliver(update);
        assertEq(oracle.oracleFrozen(), exceedsLimit);
        assertEq(oracle.totalAssets(), exceedsLimit ? 1500 : reported - 500);
        if (!exceedsLimit) assertEq(oracle.valuationOffset(), loss ? -int256(delta) : int256(delta));
    }

    function test_NegativeCurrentValueCannotBeAcceptedByGuard() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        _advanceReport();
        ICREOracle.Report memory update = _report(100);
        _withdraw(200);
        _expectRecoveryFailure(update, ICREOracle.InvalidReport.selector);
        assertEq(oracle.totalAssets(), 800);
    }

    function test_NegativeHistoricalBaselineCannotBeBypassedByGuard() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        _advanceReport();
        _deliverWithReview(_report(500));
        assertEq(oracle.valuationOffset(), -500);
        _advanceReport();
        ICREOracle.Report memory update = _report(600);
        vm.mockCall(
            address(adapter), abi.encodeCall(IMerkleAdapter.netFlowAt, (update.snapshotBlock)), abi.encode(int256(400))
        );
        _expectRecoveryFailure(update, ICREOracle.InvalidReport.selector);
        assertEq(oracle.valuationOffset(), -500);
        assertEq(oracle.totalAssets(), 500);
    }

    function test_RejectionPreservesExactSnapshotPayloadAndReviewAppliesCurrentFlows() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        _advanceReport();
        ICREOracle.Report memory update = _report(1200);
        bytes memory payload = abi.encode(update);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit ICREOracle.RejectReport(keccak256(payload), update);
        _deliver(update);
        assertTrue(oracle.oracleFrozen());
        // Raw adapter deallocation remains callable; the production delegator enforces validation separately.
        vm.prank(address(delegator));
        assertEq(adapter.deallocate(150), 150);
        oracle.unfreezeOracle(payload);
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 1050);
        assertEq(oracle.valuationOffset(), 200);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
    }

    function test_SignedOffsetSupportsRealizedProfitsAndNegativeNetCapital() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        asset.transfer(address(adapter), 100);
        delegator.requestDeallocate(address(adapter), 1100);
        _advanceReport();
        _deliver(_report(1100));
        _withdraw(1100);
        assertEq(adapter.netFlow(), -100);
        assertEq(oracle.valuationOffset(), 100);
        assertEq(oracle.totalAssets(), 0);
        _advanceReport();
        _deliver(_report(0));
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.valuationOffset(), 100);
        _allocate(200);
        assertEq(oracle.totalAssets(), 200);
    }

    function testFuzz_ValuesAboveSignedRangeFreezeAndCannotBeReviewed(uint256 assets) public {
        assets = bound(assets, uint256(type(int256).max) + 1, type(uint256).max);
        _expectRecoveryFailure(_report(assets), ICREOracle.InvalidReport.selector);
        assertEq(oracle.valuationOffset(), 0);
    }

    function test_OffsetSubtractionOverflowFreezesAndCannotBeReviewed() public {
        // A positive existing offset keeps the historical baseline valid while subtraction would overflow.
        _deliverWithReview(_report(1));
        _advanceReport();
        ICREOracle.Report memory update = _report(uint256(type(int256).max));
        vm.mockCall(
            address(adapter), abi.encodeCall(IMerkleAdapter.netFlowAt, (update.snapshotBlock)), abi.encode(int256(-1))
        );
        _expectRecoveryFailure(update, ICREOracle.InvalidReport.selector);
        assertEq(oracle.valuationOffset(), 1);
    }

    function test_PositiveFlowOverflowIsRejectedByRawGetterAndReportReview() public {
        _deliverWithReview(_report(uint256(type(int256).max)));
        vm.mockCall(address(adapter), abi.encodeCall(IMerkleAdapter.netFlow, ()), abi.encode(int256(1)));
        vm.expectRevert(ICREOracle.InvalidAssets.selector);
        oracle.totalAssets();
        _advanceReport();
        _expectRecoveryFailure(_report(uint256(type(int256).max)), ICREOracle.InvalidReport.selector);
        assertEq(oracle.valuationOffset(), type(int256).max);
    }

    function test_NegativeFlowUnderflowCannotWrapIntoPositiveAssets() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        _advanceReport();
        _deliverWithReview(_report(900));
        assertEq(oracle.valuationOffset(), -100);
        vm.mockCall(address(adapter), abi.encodeCall(IMerkleAdapter.netFlow, ()), abi.encode(type(int256).min));
        vm.expectRevert(ICREOracle.InvalidAssets.selector);
        oracle.totalAssets();
    }

    function test_OnlyFiveWordPayloadsAreAccepted() public {
        bytes memory payload = abi.encode(_report(0));
        assertEq(payload.length, 160);
        vm.prank(address(forwarder));
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.onReport(_metadata(), bytes.concat(payload, bytes32(0)));
        assertEq(oracle.snapshotBlock(), 0);
        assertFalse(oracle.oracleFrozen());
    }

    function _allocate(uint256 amount) internal {
        asset.transfer(adapter.vault(), amount);
        assertEq(delegator.allocate(address(adapter), amount), amount);
    }

    function _withdraw(uint256 amount) internal {
        MerkleAdapterVaultMock(adapter.vault()).setDelegator(address(withdrawalPath));
        uint256 vaultBalance = asset.balanceOf(adapter.vault());
        assertEq(withdrawalPath.execute(address(adapter), amount), amount);
        assertEq(asset.balanceOf(adapter.vault()), vaultBalance + amount);
        MerkleAdapterVaultMock(adapter.vault()).setDelegator(address(delegator));
    }
}
