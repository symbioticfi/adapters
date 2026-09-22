// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";

import {CREOracleTestBase} from "test/adapters/merkle-adapter/oracle/CREOracle.t.sol";

contract CREOracleRecoveryTest is CREOracleTestBase {
    function test_ReviewedRejectedReportIsAppliedWithoutRedelivery() public {
        ICREOracle.Report memory update = _report(1000);
        _deliver(update);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 0);

        (bool accepted,) = address(oracle).call(abi.encodeWithSignature("unfreezeOracle(bytes)", abi.encode(update)));

        assertTrue(accepted, "review should apply the already-authenticated report directly");
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 1);
        assertEq(oracle.totalAssets(), 1000);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
    }

    function test_GuardCannotApproveAReportBeforeAuthenticatedRejection() public {
        bytes memory payload = abi.encode(_report(1000));
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(payload);
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 0);
        assertEq(oracle.totalAssets(), 0);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        _deliver(_report(0));
        assertEq(oracle.nonce(), 1);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
    }

    function testFuzz_MalformedOrUncachedBytesCannotChangeRecovery(bytes memory report) public {
        ICREOracle.Report memory update = _report(1000);
        _deliver(update);
        bytes32 rejectedHash = oracle.rejectedReportHash();
        vm.assume(report.length != 0 && keccak256(report) != rejectedHash);
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(report);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.rejectedReportHash(), rejectedHash);
        assertEq(oracle.nonce(), 0);
        assertEq(oracle.totalAssets(), 0);
    }

    function testFuzz_AlteredCachedReportCannotBeReviewed(uint8 field, uint256 change) public {
        ICREOracle.Report memory update = _report(1000);
        _deliver(update);
        bytes32 rejectedHash = oracle.rejectedReportHash();
        change |= 1;
        field %= 7;
        if (field == 0) update.chainId ^= change;
        else if (field == 1) update.oracle = address(uint160(update.oracle) ^ uint160(change));
        else if (field == 2) update.adapter = address(uint160(update.adapter) ^ uint160(change));
        else if (field == 3) update.nonce ^= change;
        else if (field == 4) update.totalAssets ^= change;
        else if (field == 5) update.snapshotBlock ^= change;
        else update.snapshotTimestamp ^= change;
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(abi.encode(update));
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.rejectedReportHash(), rejectedHash);
        assertEq(oracle.nonce(), 0);
        assertEq(oracle.totalAssets(), 0);
    }

    function test_LatestAuthenticatedRejectionReplacesEarlierCandidateWhileFrozen() public {
        _fundPortfolio();
        _advanceReport();
        ICREOracle.Report memory first = _report(3000);
        _deliver(first);
        bytes memory firstPayload = abi.encode(first);
        assertEq(oracle.rejectedReportHash(), keccak256(firstPayload));

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        ICREOracle.Report memory latest = _report(1050);
        _deliver(latest);
        bytes memory latestPayload = abi.encode(latest);
        assertTrue(oracle.oracleFrozen(), "a valid newer report does not clear an existing freeze");
        assertEq(oracle.rejectedReportHash(), keccak256(latestPayload));
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(firstPayload);
        assertEq(oracle.rejectedReportHash(), keccak256(latestPayload));
        oracle.unfreezeOracle(latestPayload);
        assertEq(oracle.nonce(), 3);
        assertEq(oracle.totalAssets(), 1050);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
    }

    function testFuzz_InvalidReportCannotReplaceCachedRejection(uint8 field) public {
        _fundPortfolio();
        _advanceReport();
        ICREOracle.Report memory update = _report(3000);
        _deliver(update);
        bytes32 rejectedHash = oracle.rejectedReportHash();
        field %= 6;
        bytes4 expected = ICREOracle.InvalidReport.selector;
        if (field == 0) {
            update.chainId++;
        } else if (field == 1) {
            update.adapter = address(oracle);
        } else if (field == 2) {
            update.oracle = address(adapter);
        } else if (field == 3) {
            update.nonce++;
            expected = ICREOracle.InvalidNonce.selector;
        } else {
            update.snapshotTimestamp = field == 4 ? block.timestamp + 1 : oracle.cutoff() - 1;
            expected = ICREOracle.StaleReport.selector;
        }
        _expectReportError(update, expected);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.rejectedReportHash(), rejectedHash);
        assertEq(oracle.nonce(), 2);
        assertEq(oracle.totalAssets(), 1000);
    }

    function test_EmptyUnfreezeDiscardsCandidateWithoutApplyingIt() public {
        _fundPortfolio();
        delegator.requestDeallocate(address(adapter), 300);
        uint256 cutoff = oracle.cutoff();
        uint256 snapshot = oracle.snapshotTimestamp();
        _advanceReport();
        _deliver(_report(400));
        assertTrue(oracle.oracleFrozen());
        oracle.unfreezeOracle(bytes(""));
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        assertEq(oracle.nonce(), 2);
        assertEq(oracle.totalAssets(), 1000);
        assertEq(oracle.cutoff(), cutoff);
        assertEq(oracle.snapshotTimestamp(), snapshot);
        assertEq(_batch(false).deallocation, 300);
        assertEq(adapter.deallocatable(), 0);

        _advanceReport();
        _deliver(_report(1000));
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        assertEq(oracle.nonce(), 3);
        assertEq(oracle.totalAssets(), 700);
        assertEq(adapter.deallocatable(), 300);
    }

    function test_ManualFreezeAndWorkflowChangeInvalidateCachedReview() public {
        ICREOracle.Report memory update = _report(1000);
        _deliver(update);
        bytes memory payload = abi.encode(update);
        oracle.freezeOracle();
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(payload);
        assertTrue(oracle.oracleFrozen());

        _deliver(update);
        assertEq(oracle.rejectedReportHash(), keccak256(payload));
        bytes32 nextWorkflow = keccak256("replacement workflow");
        _proposeWorkflow(address(oracle), nextWorkflow);
        _acceptWorkflow(address(oracle), nextWorkflow);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(payload);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 0);
    }

    function testFuzz_ReviewRechecksExactDeliveryAge(uint16 age) public {
        _fundPortfolio();
        delegator.requestDeallocate(address(adapter), 1000);
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
            assertEq(oracle.nonce(), 2);
            assertEq(oracle.totalAssets(), 1000);
            assertEq(_batch(false).deallocation, 1000);
            assertEq(adapter.deallocatable(), 0);
        } else {
            oracle.unfreezeOracle(payload);
            assertFalse(oracle.oracleFrozen());
            assertEq(oracle.rejectedReportHash(), bytes32(0));
            assertEq(oracle.nonce(), 3);
            assertEq(oracle.totalAssets(), 0);
            assertEq(adapter.deallocatable(), 400);
        }
    }

    function test_ReviewExactlyAtMaximumDeliveryAgeIsAccepted() public {
        ICREOracle.Report memory update = _report(1000);
        _deliver(update);
        vm.warp(update.snapshotTimestamp + oracle.MAX_REPORT_AGE());
        oracle.unfreezeOracle(abi.encode(update));
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        assertEq(oracle.nonce(), 1);
        assertEq(oracle.totalAssets(), 1000);
    }

    function test_ReviewRechecksImmutableAgeAndPreservesCandidateOnFailure() public {
        _fundPortfolio();
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
        assertEq(oracle.nonce(), 2);
        assertEq(oracle.totalAssets(), 1000);
    }

    function test_RecoveryWaitsForWithdrawalFundingAndThenSettlesOnce() public {
        _fundPortfolio();
        vm.prank(account);
        adapter.push(1000);
        delegator.requestDeallocate(address(adapter), 600);
        vm.prank(account);
        adapter.pull(400);
        _advanceReport();
        ICREOracle.Report memory update = _report(1000);
        _deliver(update);
        bytes memory payload = abi.encode(update);
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(payload);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.rejectedReportHash(), keccak256(payload));
        assertEq(_batch(false).deallocation, 600);
        assertEq(adapter.deallocatable(), 0);

        vm.prank(account);
        adapter.pull(200);
        oracle.unfreezeOracle(payload);
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 400);
        assertEq(oracle.nonce(), 3);
        assertEq(adapter.deallocatable(), 600);
        assertEq(delegator.deallocate(address(adapter), 1000), 600);
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(payload);
        assertEq(adapter.deallocatable(), 0);
    }

    function _fundPortfolio() internal {
        _deliver(_report(0));
        asset.transfer(adapter.vault(), 1000);
        delegator.allocate(address(adapter), 1000);
        _advanceReport();
        _deliver(_report(1000));
    }
}
