// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {CREOracleTestBase} from "./CREOracle.t.sol";
import {MerkleDeallocationHarness} from "./CREOracleDeallocate.t.sol";
import {MerkleAdapterVaultMock} from "test/adapters/MerkleAdapter.t.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IMerkleAdapterOracle} from "src/interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {
    ICREOracle,
    ORACLE_LIMITS_ROLE,
    ORACLE_LIMIT_PRECISION
} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {stdError} from "forge-std/StdError.sol";

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
        assertEq(adapter.totalAssets(), 850);
        _deliver(beforeWithdrawal);
        assertEq(adapter.totalAssets(), 850);
        _advanceReport();
        _deliver(_report(850));
        assertEq(adapter.totalAssets(), 850);
        _assertReportedAssets(850);
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
        assertEq(adapter.totalAssets(), 0);
        _assertReportedAssets(1000);
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
        assertEq(adapter.totalAssets(), 1400);
        _withdraw(300);
        _deliver(update);
        assertEq(adapter.totalAssets(), 1100);
        assertEq(adapter.netFlow(), 1100);
        _assertReportedAssets(1300);
        _advanceReport();
        _deliver(_report(1100));
        assertEq(adapter.totalAssets(), 1100);
    }

    function test_OracleTuplePreservesSnapshotNAVWhileAdapterTracksLaterFlows() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        (uint48 reportBlock, uint256 reportedAssets) = oracle.latestSnapshot();
        assertEq(reportedAssets, 1000);

        _allocate(300);
        _assertReportedAssets(1000);
        assertEq(oracle.snapshotBlock(), reportBlock);
        assertEq(adapter.totalAssets(), 1300);
        _withdraw(200);
        _assertReportedAssets(1000);
        assertEq(oracle.snapshotBlock(), reportBlock);
        assertEq(adapter.totalAssets(), 1100);

        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(0, 0, 0);
        _advanceReport();
        _deliver(_report(1100));
        _assertReportedAssets(1100);
        assertGt(oracle.snapshotBlock(), reportBlock);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
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
        assertEq(oracle.rejectedReportHash(), exceedsLimit ? keccak256(abi.encode(update)) : bytes32(0));
        assertEq(adapter.totalAssets(), exceedsLimit ? 1500 : reported - 500);
        if (!exceedsLimit) _assertReportedAssets(reported);
    }

    function test_NegativeCurrentValueCannotBeAcceptedByGuard() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        _advanceReport();
        ICREOracle.Report memory update = _report(100);
        _deliver(update);
        bytes32 rejected = keccak256(abi.encode(update));
        assertEq(oracle.rejectedReportHash(), rejected);
        _withdraw(200);
        vm.expectRevert(ICREOracle.InvalidAssets.selector);
        _deliver(update);
        vm.expectRevert(ICREOracle.InvalidAssets.selector);
        oracle.acceptReport(abi.encode(update));
        assertEq(oracle.rejectedReportHash(), rejected);
        _assertReportedAssets(1000);
        assertEq(adapter.totalAssets(), 800);
        assertEq(adapter.releasedLiquidity(), 800);
    }

    function test_GuardBypassesNegativeHistoricalMovementBaseline() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        _advanceReport();
        _deliverWithReview(_report(500));
        _advanceReport();
        ICREOracle.Report memory update = _report(600);
        _deliver(update);
        bytes32 rejected = keccak256(abi.encode(update));
        assertEq(oracle.rejectedReportHash(), rejected);

        // Isolate the signed-baseline guard with a mocked flow response; current NAV remains positive.
        vm.mockCall(
            address(adapter), abi.encodeCall(IMerkleAdapter.netFlowAt, (update.snapshotBlock)), abi.encode(int256(400))
        );
        vm.expectEmit(false, false, false, true, address(oracle));
        emit ICREOracle.OnReport(update, true);
        _deliver(update);
        assertEq(oracle.rejectedReportHash(), rejected);
        oracle.acceptReport(abi.encode(update));

        assertEq(oracle.rejectedReportHash(), bytes32(0));
        assertEq(oracle.snapshotBlock(), update.snapshotBlock);
        _assertReportedAssets(600);
        assertEq(adapter.totalAssets(), 600);
        assertEq(adapter.releasedLiquidity(), 500);
        assertEq(adapter.pendingDeallocation(), 500);
        assertEq(adapter.stagedLiquidity(), 0);
    }

    function test_GuardBypassesHistoricalMovementBaselineOverflow() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        _advanceReport();
        _deliverWithReview(_report(500));
        _assertReportedAssets(500);
        _advanceReport();
        ICREOracle.Report memory update = _report(600);
        _deliver(update);
        bytes32 rejected = keccak256(abi.encode(update));
        assertEq(oracle.rejectedReportHash(), rejected);
        vm.mockCall(
            address(adapter),
            abi.encodeCall(IMerkleAdapter.netFlowAt, (oracle.snapshotBlock())),
            abi.encode(type(int256).min)
        );
        vm.expectRevert(stdError.arithmeticError);
        _deliver(update);
        oracle.acceptReport(abi.encode(update));
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        _assertReportedAssets(600);
        vm.clearMockedCalls();
        assertEq(adapter.totalAssets(), 600);
    }

    function test_InvalidCurrentNAVAndDeviationPreserveRejectedReportAndReserves() public {
        _fundPortfolio(1000);
        _releasePortfolio(600);
        delegator.requestDeallocate(address(adapter), 800);
        uint48 acceptedBlock = oracle.snapshotBlock();
        uint256 cumulativeStaged = adapter.stagedLiquidityAt(uint48(block.number));
        _advanceReport();
        ICREOracle.Report memory rejected = _report(1200);
        _deliver(rejected);
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(rejected)));

        vm.mockCall(address(adapter), abi.encodeCall(IMerkleAdapter.netFlow, ()), abi.encode(int256(-1300)));
        vm.expectRevert(ICREOracle.InvalidAssets.selector);
        _deliver(_report(2000));
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(rejected)));
        assertEq(oracle.snapshotBlock(), acceptedBlock);
        _assertReportedAssets(1000);
        assertEq(adapter.releasedLiquidity(), 600);
        assertEq(adapter.stagedLiquidity(), 200);
        assertEq(adapter.stagedLiquidityAt(uint48(block.number)), cumulativeStaged);
        assertEq(adapter.pendingDeallocation(), 800);
        assertEq(asset.balanceOf(address(adapter)), 1000);
        assertEq(asset.balanceOf(adapter.vault()), 0);
        vm.clearMockedCalls();
        assertEq(adapter.totalAssets(), 1000);
    }

    function test_RejectionPreservesExactSnapshotPayloadAndReviewAppliesCurrentFlows() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        _advanceReport();
        ICREOracle.Report memory update = _report(1200);
        bytes memory payload = abi.encode(update);
        vm.expectEmit(false, false, false, true, address(oracle));
        emit ICREOracle.OnReport(update, true);
        _deliver(update);
        assertEq(oracle.rejectedReportHash(), keccak256(payload));
        assertEq(adapter.totalAssets(), 1000);
        _withdraw(150);
        assertEq(adapter.totalAssets(), 850);
        vm.expectEmit(false, false, false, true, address(oracle));
        emit ICREOracle.OnReport(update, false);
        oracle.acceptReport(payload);
        assertEq(adapter.totalAssets(), 1050);
        _assertReportedAssets(1200);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
    }

    function test_SnapshotsSupportRealizedProfitsAndNegativeNetCapital() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        asset.transfer(address(adapter), 100);
        delegator.requestDeallocate(address(adapter), 1100);
        _advanceReport();
        _deliver(_report(1100));
        _withdraw(1100);
        assertEq(adapter.netFlow(), -100);
        _assertReportedAssets(1100);
        assertEq(adapter.totalAssets(), 0);
        _advanceReport();
        _deliver(_report(0));
        _assertReportedAssets(0);
        _allocate(200);
        assertEq(adapter.totalAssets(), 200);
    }

    function testFuzz_ValuesAboveSignedRangeRevertWithoutReplacingRejectedReport(uint256 assets) public {
        assets = bound(assets, uint256(type(int256).max) + 1, type(uint256).max);
        _deliverWithReview(_report(1));
        _advanceReport();
        ICREOracle.Report memory rejected = _report(2);
        _deliver(rejected);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintToInt.selector, assets));
        _deliver(_report(assets));
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(rejected)));
        assertEq(oracle.snapshotBlock(), 499);
        _assertReportedAssets(1);
        assertEq(adapter.totalAssets(), 1);
    }

    function test_SnapshotFlowSubtractionOverflowRevertsWithoutReplacingRejectedReport() public {
        // The previous reported NAV keeps the historical baseline valid while the new subtraction overflows.
        _deliverWithReview(_report(1));
        _advanceReport();
        ICREOracle.Report memory rejected = _report(2);
        _deliver(rejected);
        ICREOracle.Report memory update = _report(uint256(type(int256).max));
        vm.mockCall(
            address(adapter), abi.encodeCall(IMerkleAdapter.netFlowAt, (update.snapshotBlock)), abi.encode(int256(-1))
        );
        vm.expectRevert(stdError.arithmeticError);
        _deliver(update);
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(rejected)));
        assertEq(oracle.snapshotBlock(), 499);
        _assertReportedAssets(1);
    }

    function test_PositiveFlowOverflowRevertsInTotalAssetsAndDelivery() public {
        _fundPortfolio(1);
        _advanceReport();
        _deliverWithReview(_report(uint256(type(int256).max)));
        uint48 acceptedBlock = oracle.snapshotBlock();
        vm.mockCall(
            address(oracle),
            abi.encodeCall(IMerkleAdapterOracle.latestSnapshot, ()),
            abi.encode(uint48(0), uint256(type(int256).max))
        );
        vm.expectRevert(stdError.arithmeticError);
        adapter.totalAssets();
        vm.clearMockedCalls();
        vm.mockCall(address(adapter), abi.encodeCall(IMerkleAdapter.netFlow, ()), abi.encode(int256(2)));
        _advanceReport();
        vm.expectRevert(stdError.arithmeticError);
        _deliver(_report(uint256(type(int256).max)));
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        assertEq(oracle.snapshotBlock(), acceptedBlock);
        _assertReportedAssets(uint256(type(int256).max));
    }

    function test_OracleRejectsNegativeNAVAfterReturningProfit() public {
        _fundPortfolio(1000);
        asset.transfer(address(adapter), 100);
        delegator.requestDeallocate(address(adapter), 1100);
        _advanceReport();
        _deliver(_report(1100));
        _advanceReport();
        ICREOracle.Report memory update = _report(0);
        _withdraw(1100);
        assertEq(adapter.netFlow(), -100);
        vm.expectRevert(ICREOracle.InvalidAssets.selector);
        _deliver(update);
        _assertReportedAssets(1100);
        assertEq(adapter.totalAssets(), 0);
    }

    function test_IntermediateSubtractionOverflowRevertsEvenWhenFlowDeltaIsZero() public {
        _fundPortfolio(1000);
        asset.transfer(address(adapter), 100);
        delegator.requestDeallocate(address(adapter), 1100);
        _advanceReport();
        _deliver(_report(1100));
        _withdraw(1100);
        _advanceReport();
        _deliver(_report(0));
        assertEq(adapter.netFlowAt(oracle.snapshotBlock()), -100);
        assertEq(adapter.netFlow(), -100);
        vm.mockCall(
            address(oracle),
            abi.encodeCall(IMerkleAdapterOracle.latestSnapshot, ()),
            abi.encode(oracle.snapshotBlock(), uint256(type(int256).max))
        );
        vm.expectRevert(stdError.arithmeticError);
        adapter.totalAssets();
    }

    function test_OnlyFourWordPayloadsAreAccepted() public {
        bytes memory payload = abi.encode(_report(0));
        assertEq(payload.length, 128);
        vm.prank(address(forwarder));
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.onReport(_metadata(), bytes.concat(payload, bytes32(0)));
        assertEq(oracle.snapshotBlock(), 0);
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
