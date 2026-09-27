// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {CREOracleTestBase} from "./CREOracle.t.sol";

contract CREOracleRecoveryTest is CREOracleTestBase {
    function test_FrozenOracleReceivesFreshReportsWithoutMovingAcceptedSnapshot() public {
        _fundPortfolio(1000);
        uint48 acceptedBlock = oracle.snapshotBlock();
        uint48 acceptedTimestamp = oracle.snapshotTimestamp();
        ICREOracle.Report memory update;
        for (uint256 i; i < 3; ++i) {
            _advanceReport();
            update = _report(i == 0 ? 3000 : 1050);
            _deliver(update);
            assertTrue(oracle.oracleFrozen());
            assertEq(oracle.snapshotBlock(), acceptedBlock);
            assertEq(oracle.snapshotTimestamp(), acceptedTimestamp);
            assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(update)));
        }
        oracle.unfreezeOracle(abi.encode(update));
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 1050);
        _advanceReport();
        _deliver(_report(1050));
        assertEq(oracle.snapshotBlock(), block.number - 1);
    }

    function test_LateReviewDoesNotBurnTheNextReportingInterval() public {
        _fundPortfolio(1000);
        _advanceReport();
        ICREOracle.Report memory rejected = _report(3000);
        _deliver(rejected);
        vm.warp(rejected.snapshotTimestamp + 100);
        oracle.unfreezeOracle(abi.encode(rejected));
        assertEq(oracle.snapshotTimestamp(), rejected.snapshotTimestamp);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        _deliver(_report(3000));
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.snapshotTimestamp(), rejected.snapshotTimestamp + 100);
    }

    function test_EmptyUnfreezeDoesNotMoveAcceptedSnapshot() public {
        _fundPortfolio(1000);
        uint48 accepted = oracle.snapshotTimestamp();
        _advanceReport();
        _deliver(_report(3000));
        oracle.unfreezeOracle("");
        assertEq(oracle.snapshotTimestamp(), accepted);
        _deliver(_report(1050));
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 1050);
    }

    function test_ReviewedRejectedReportIsAppliedWithoutRedelivery() public {
        ICREOracle.Report memory update = _report(1000);
        _deliver(update);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.snapshotBlock(), 0);
        oracle.unfreezeOracle(abi.encode(update));
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.snapshotBlock(), update.snapshotBlock);
        assertEq(oracle.totalAssets(), 1000);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
    }

    function test_GuardCannotApproveAReportBeforeAuthenticatedRejection() public {
        bytes memory payload = abi.encode(_report(1000));
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(payload);
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.snapshotBlock(), 0);
        assertEq(oracle.totalAssets(), 0);
        _deliver(_report(0));
        assertEq(oracle.snapshotBlock(), 499);
    }

    function testFuzz_MalformedOrUncachedBytesCannotChangeRecovery(bytes memory report) public {
        _deliver(_report(1000));
        bytes32 rejectedHash = oracle.rejectedReportHash();
        vm.assume(report.length != 0 && keccak256(report) != rejectedHash);
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(report);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.rejectedReportHash(), rejectedHash);
        assertEq(oracle.snapshotBlock(), 0);
        assertEq(oracle.totalAssets(), 0);
    }

    function testFuzz_AlteredCachedReportCannotBeReviewed(uint8 field, uint256 change) public {
        ICREOracle.Report memory update = _report(1000);
        _deliver(update);
        bytes32 rejectedHash = oracle.rejectedReportHash();
        change |= 1;
        field %= 5;
        if (field == 0) update.chainId ^= change;
        else if (field == 1) update.adapter = address(uint160(update.adapter) ^ uint160(change));
        else if (field == 2) update.totalAssets ^= change;
        else if (field == 3) update.snapshotBlock ^= uint48(change);
        else update.snapshotTimestamp ^= uint48(change);
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(abi.encode(update));
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.rejectedReportHash(), rejectedHash);
        assertEq(oracle.snapshotBlock(), 0);
    }

    function test_LatestAuthenticatedRejectionReplacesEarlierCandidateWhileFrozen() public {
        _fundPortfolio(1000);
        _advanceReport();
        bytes memory firstPayload = abi.encode(_report(3000));
        _deliver(_report(3000));
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        ICREOracle.Report memory latest = _report(1050);
        _deliver(latest);
        bytes memory latestPayload = abi.encode(latest);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.rejectedReportHash(), keccak256(latestPayload));
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(firstPayload);
        oracle.unfreezeOracle(latestPayload);
        assertEq(oracle.snapshotBlock(), latest.snapshotBlock);
        assertEq(oracle.totalAssets(), 1050);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
    }

    function testFuzz_InvalidReportCannotReplaceCachedRejection(uint8 field) public {
        _fundPortfolio(1000);
        _advanceReport();
        ICREOracle.Report memory update = _report(3000);
        _deliver(update);
        bytes32 rejectedHash = oracle.rejectedReportHash();
        field %= 5;
        bytes4 expected = ICREOracle.InvalidReport.selector;
        if (field == 0) {
            update.chainId++;
        } else if (field == 1) {
            update.adapter = address(oracle);
        } else {
            if (field == 2) update.snapshotTimestamp = SafeCast.toUint48(block.timestamp + 1);
            else if (field == 3) update.snapshotTimestamp = oracle.snapshotTimestamp();
            else update.snapshotBlock = oracle.snapshotBlock();
            expected = ICREOracle.StaleReport.selector;
        }
        _expectReportError(update, expected);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.rejectedReportHash(), rejectedHash);
        assertEq(oracle.totalAssets(), 1000);
    }

    function test_EmptyUnfreezeDiscardsCandidateWithoutApplyingIt() public {
        _fundPortfolio(1000);
        delegator.requestDeallocate(address(adapter), 300);
        uint48 snapshot = oracle.snapshotTimestamp();
        _advanceReport();
        _deliver(_report(400));
        oracle.unfreezeOracle("");
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        assertEq(oracle.totalAssets(), 1000);
        assertEq(oracle.snapshotTimestamp(), snapshot);
        assertEq(adapter.pendingDeallocation(), 300);
        _deliver(_report(1000));
        assertEq(oracle.totalAssets(), 1000);
        assertEq(adapter.pendingDeallocation(), 300);
    }

    function test_ManualFreezeAndWorkflowChangeInvalidateCachedReview() public {
        ICREOracle.Report memory update = _report(1000);
        _deliver(update);
        bytes memory payload = abi.encode(update);
        oracle.freezeOracle();
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(payload);
        _deliver(update);
        bytes32 nextWorkflow = keccak256("replacement workflow");
        _proposeWorkflow(address(oracle), nextWorkflow);
        _acceptWorkflow(address(oracle), nextWorkflow);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(payload);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.snapshotBlock(), 0);
    }

    function testFuzz_ReviewRechecksExactDeliveryAge(uint16 age) public {
        _fundPortfolio(1000);
        _advanceReport();
        ICREOracle.Report memory update = _report(400);
        _deliver(update);
        bytes memory payload = abi.encode(update);
        age = uint16(bound(age, 1, 120));
        vm.warp(update.snapshotTimestamp + age);
        if (age > 100) {
            vm.expectRevert(ICREOracle.StaleReport.selector);
            oracle.unfreezeOracle(payload);
            assertTrue(oracle.oracleFrozen());
            assertEq(oracle.rejectedReportHash(), keccak256(payload));
            assertEq(oracle.totalAssets(), 1000);
        } else {
            oracle.unfreezeOracle(payload);
            assertFalse(oracle.oracleFrozen());
            assertEq(oracle.rejectedReportHash(), bytes32(0));
            assertEq(oracle.totalAssets(), 400);
        }
    }

    function test_ReviewExactlyAtMaximumDeliveryAgeIsAccepted() public {
        ICREOracle.Report memory update = _report(1000);
        _deliver(update);
        vm.warp(update.snapshotTimestamp + oracle.MAX_REPORT_AGE());
        oracle.unfreezeOracle(abi.encode(update));
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 1000);
    }

    function test_ReviewRechecksImmutableAgeAndPreservesCandidateOnFailure() public {
        _fundPortfolio(1000);
        _advanceReport();
        ICREOracle.Report memory update = _report(3000);
        _deliver(update);
        bytes memory payload = abi.encode(update);
        _migrateWithMaxOracleAge(2);
        vm.warp(update.snapshotTimestamp + 3);
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(payload);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.rejectedReportHash(), keccak256(payload));
        assertEq(oracle.totalAssets(), 1000);
    }

    function test_UnfundedWithdrawalDefersWithoutFreezeAndEachReturnNeedsCoveringReport() public {
        _fundPortfolio(1000);
        vm.prank(account);
        adapter.push(1000);
        delegator.requestDeallocate(address(adapter), 600);
        _advanceReport();
        _deliver(_report(1000));
        assertFalse(oracle.oracleFrozen());
        assertEq(adapter.pendingDeallocation(), 600);
        assertEq(adapter.deallocatable(), 0);
        vm.prank(account);
        adapter.pull(400);
        assertEq(delegator.deallocate(address(adapter), 1000), 0);
        assertEq(oracle.totalAssets(), 1000);
        _advanceReport();
        _deliver(_report(1000));
        assertEq(delegator.deallocate(address(adapter), 1000), 400);
        assertEq(oracle.totalAssets(), 600);
        assertEq(adapter.pendingDeallocation(), 200);
        vm.prank(account);
        adapter.pull(200);
        assertEq(delegator.deallocate(address(adapter), 1000), 0);
        _advanceReport();
        _deliver(_report(600));
        assertFalse(oracle.oracleFrozen());
        assertEq(delegator.deallocate(address(adapter), 1000), 200);
        assertEq(oracle.totalAssets(), 400);
        assertEq(adapter.pendingDeallocation(), 0);
    }
}
