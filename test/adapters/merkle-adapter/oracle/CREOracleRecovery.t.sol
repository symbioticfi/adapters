// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    ICREOracle,
    ORACLE_LIMITS_ROLE,
    ORACLE_LIMIT_PRECISION
} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {CREOracleTestBase} from "./CREOracle.t.sol";

contract CREOracleRecoveryTest is CREOracleTestBase {
    function test_RaisedLimitsAllowLaterReportAfterDeviationRejection() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(700);
        uint48 acceptedBlock = _acceptedSnapshotBlock();
        delegator.requestDeallocate(address(adapter), 300);
        _advanceReport();
        ICREOracle.Report memory rejected = _report(1800);
        bytes memory rejectedPayload = abi.encode(rejected);
        _deliver(rejected);

        assertEq(oracle.rejectedReportHash(), keccak256(rejectedPayload));
        assertEq(_acceptedSnapshotBlock(), acceptedBlock);
        _assertReportedAssets(1000);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.stagedLiquidity(), 300);
        assertEq(adapter.releasedLiquidity(), 0);

        assertEq(asset.balanceOf(address(adapter)), 300);
        assertEq(asset.balanceOf(account), 700);
        assertEq(asset.balanceOf(adapter.vault()), 0);

        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(uint32(ORACLE_LIMIT_PRECISION), uint32(ORACLE_LIMIT_PRECISION), 0);
        assertEq(_acceptedSnapshotBlock(), acceptedBlock);
        assertEq(adapter.totalAssets(), 1000);

        _advanceReport();
        ICREOracle.Report memory accepted = _report(1900);
        _deliver(accepted);

        assertEq(_acceptedSnapshotBlock(), accepted.snapshotBlock);
        _assertReportedAssets(1900);
        assertEq(adapter.totalAssets(), 1900);
        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(adapter.releasedLiquidity(), 300);

        assertEq(asset.balanceOf(address(adapter)), 300);
        assertEq(asset.balanceOf(account), 700);
        assertEq(asset.balanceOf(adapter.vault()), 0);

        assertEq(oracle.rejectedReportHash(), keccak256(rejectedPayload));
        vm.expectRevert(ICREOracle.StaleReport.selector);
        oracle.acceptReport(rejectedPayload);
        assertEq(_acceptedSnapshotBlock(), accepted.snapshotBlock);
        assertEq(adapter.totalAssets(), 1900);
        assertEq(adapter.releasedLiquidity(), 300);
        assertEq(oracle.rejectedReportHash(), keccak256(rejectedPayload));
    }

    function test_WithinLimitsReportAfterDeviationRejectionUsesActiveBaseline() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(700);
        uint48 acceptedBlock = _acceptedSnapshotBlock();
        delegator.requestDeallocate(address(adapter), 300);
        _advanceReport();
        ICREOracle.Report memory rejected = _report(3000);
        bytes memory rejectedPayload = abi.encode(rejected);
        _deliver(rejected);

        assertEq(oracle.rejectedReportHash(), keccak256(rejectedPayload));
        assertEq(_acceptedSnapshotBlock(), acceptedBlock);
        _assertReportedAssets(1000);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.stagedLiquidity(), 300);
        assertEq(adapter.releasedLiquidity(), 0);

        assertEq(asset.balanceOf(address(adapter)), 300);
        assertEq(asset.balanceOf(account), 700);
        assertEq(asset.balanceOf(adapter.vault()), 0);

        _advanceReport();
        ICREOracle.Report memory accepted = _report(1050);
        _deliver(accepted);

        assertEq(_acceptedSnapshotBlock(), accepted.snapshotBlock);
        _assertReportedAssets(1050);
        assertEq(adapter.totalAssets(), 1050);
        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(adapter.releasedLiquidity(), 300);

        assertEq(asset.balanceOf(address(adapter)), 300);
        assertEq(asset.balanceOf(account), 700);
        assertEq(asset.balanceOf(adapter.vault()), 0);

        assertEq(oracle.rejectedReportHash(), keccak256(rejectedPayload));
        vm.expectRevert(ICREOracle.StaleReport.selector);
        oracle.acceptReport(rejectedPayload);
        assertEq(_acceptedSnapshotBlock(), accepted.snapshotBlock);
        assertEq(adapter.totalAssets(), 1050);
        assertEq(adapter.releasedLiquidity(), 300);
        assertEq(oracle.rejectedReportHash(), keccak256(rejectedPayload));
    }

    function test_RejectedReportKeepsActiveNAVUsableAfterLongDelay() public {
        _fundPortfolio(1000);
        _releasePortfolio(300);
        uint48 acceptedBlock = _acceptedSnapshotBlock();
        uint256 acceptedAt = block.timestamp;
        vm.warp(acceptedAt + 1000);
        vm.roll(vm.getBlockNumber() + 1);
        ICREOracle.Report memory rejected = _report(3000);
        _deliver(rejected);

        assertEq(adapter.totalAssets(), 1000);
        asset.transfer(adapter.vault(), 40);
        assertEq(delegator.allocate(address(adapter), 40), 40);
        assertEq(delegator.deallocate(address(adapter), 100), 100);
        assertEq(adapter.totalAssets(), 940);
        assertEq(_acceptedSnapshotBlock(), acceptedBlock);
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(rejected)));

        vm.warp(acceptedAt + 10_000);
        assertEq(adapter.totalAssets(), 940);
        (uint48 snapshot,) = oracle.latestSnapshot();
        assertEq(snapshot, acceptedBlock);
        assertEq(adapter.netFlow(), 940);
        assertEq(adapter.releasedLiquidity(), 200);

        assertEq(asset.balanceOf(address(adapter)), 200);
        assertEq(asset.balanceOf(account), 740);
        assertEq(asset.balanceOf(adapter.vault()), 100);
        assertEq(_acceptedSnapshotBlock(), acceptedBlock);
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(rejected)));
    }

    function test_NewerRejectedReportRemainsReviewableAfterOlderReportIsAccepted() public {
        _fundPortfolio(1000);
        _advanceReport();
        ICREOracle.Report memory older = _report(1050);
        _advanceReport();
        ICREOracle.Report memory rejected = _report(3000);
        _deliver(rejected);
        bytes memory payload = abi.encode(rejected);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(oracle.rejectedReportHash(), keccak256(payload));

        _deliver(older);
        assertEq(_acceptedSnapshotBlock(), older.snapshotBlock);
        assertEq(adapter.totalAssets(), 1050);
        assertEq(oracle.rejectedReportHash(), keccak256(payload));
        oracle.acceptReport(payload);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(_acceptedSnapshotBlock(), rejected.snapshotBlock);
        assertEq(adapter.totalAssets(), 3000);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
    }

    function test_RejectedReportCannotBeReviewedAfterItsSnapshotIsAccepted() public {
        _fundPortfolio(1000);
        _advanceReport();
        ICREOracle.Report memory rejected = _report(1800);
        bytes memory payload = abi.encode(rejected);
        _deliver(rejected);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(uint32(ORACLE_LIMIT_PRECISION), uint32(ORACLE_LIMIT_PRECISION), 0);
        _deliver(rejected);
        assertEq(adapter.totalAssets(), 1800);
        assertEq(oracle.rejectedReportHash(), keccak256(payload));

        vm.expectRevert(ICREOracle.StaleReport.selector);
        oracle.acceptReport(payload);
        assertEq(_acceptedSnapshotBlock(), rejected.snapshotBlock);
        assertEq(adapter.totalAssets(), 1800);
        assertEq(oracle.rejectedReportHash(), keccak256(payload));
    }

    function test_LateReviewPreservesSnapshotBlockAndAllowsTheNextCompletedSnapshot() public {
        _fundPortfolio(1000);
        _advanceReport();
        ICREOracle.Report memory rejected = _report(3000);
        _deliver(rejected);
        vm.warp(block.timestamp + 1000);
        oracle.acceptReport(abi.encode(rejected));
        vm.roll(block.number + 1);
        assertEq(_acceptedSnapshotBlock(), rejected.snapshotBlock);
        vm.warp(block.timestamp + 1);
        _deliver(_report(3000));
        assertEq(_acceptedSnapshotBlock(), rejected.snapshotBlock + 1);
    }

    function test_ReviewedRejectedReportIsAppliedWithoutRedelivery() public {
        ICREOracle.Report memory update = _report(1000);
        _deliver(update);

        assertEq(_acceptedSnapshotBlock(), 0);
        oracle.acceptReport(abi.encode(update));

        vm.roll(vm.getBlockNumber() + 1);
        assertEq(_acceptedSnapshotBlock(), update.snapshotBlock);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
    }

    function test_GuardCannotApproveAReportBeforeAuthenticatedRejection() public {
        bytes memory payload = abi.encode(_report(1000));
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.acceptReport(payload);

        assertEq(_acceptedSnapshotBlock(), 0);
        assertEq(adapter.totalAssets(), 0);
        _deliver(_report(0));
        assertEq(_acceptedSnapshotBlock(), 499);
    }

    function testFuzz_MalformedOrUncachedBytesCannotChangeRecovery(bytes memory report) public {
        _deliver(_report(1000));
        bytes32 rejectedHash = oracle.rejectedReportHash();
        vm.assume(keccak256(report) != rejectedHash);
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.acceptReport(report);

        assertEq(oracle.rejectedReportHash(), rejectedHash);
        assertEq(_acceptedSnapshotBlock(), 0);
        assertEq(adapter.totalAssets(), 0);
    }

    function testFuzz_AlteredCachedReportCannotBeReviewed(uint8 field, uint256 change) public {
        ICREOracle.Report memory update = _report(1000);
        _deliver(update);
        bytes32 rejectedHash = oracle.rejectedReportHash();
        change |= 1;
        field %= 4;
        if (field == 0) update.chainId ^= change;
        else if (field == 1) update.adapter = address(uint160(update.adapter) ^ uint160(change));
        else if (field == 2) update.totalAssets ^= change;
        else update.snapshotBlock ^= uint48(change);
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.acceptReport(abi.encode(update));

        assertEq(oracle.rejectedReportHash(), rejectedHash);
        assertEq(_acceptedSnapshotBlock(), 0);
    }

    function test_LatestAuthenticatedRejectionReplacesEarlierCandidate() public {
        _fundPortfolio(1000);
        _advanceReport();
        bytes memory firstPayload = abi.encode(_report(3000));
        _deliver(_report(3000));
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        ICREOracle.Report memory latest = _report(3100);
        _deliver(latest);
        bytes memory latestPayload = abi.encode(latest);

        assertEq(oracle.rejectedReportHash(), keccak256(latestPayload));
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.acceptReport(firstPayload);
        oracle.acceptReport(latestPayload);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(_acceptedSnapshotBlock(), latest.snapshotBlock);
        assertEq(adapter.totalAssets(), 3100);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
    }

    function testFuzz_InvalidReportCannotReplaceCachedRejection(uint8 field) public {
        _fundPortfolio(1000);
        _advanceReport();
        ICREOracle.Report memory update = _report(3000);
        _deliver(update);
        bytes32 rejectedHash = oracle.rejectedReportHash();
        field %= 4;
        bytes4 expected = ICREOracle.InvalidReport.selector;
        if (field == 0) {
            update.chainId++;
        } else if (field == 1) {
            update.adapter = address(oracle);
        } else {
            update.snapshotBlock = field == 2 ? SafeCast.toUint48(block.number) : _acceptedSnapshotBlock();
            expected = ICREOracle.StaleReport.selector;
        }
        _expectReportError(update, expected);

        assertEq(oracle.rejectedReportHash(), rejectedHash);
        assertEq(adapter.totalAssets(), 1000);
    }

    function test_EmptyReportCannotClearCandidateOrChangeActiveState() public {
        _fundPortfolio(1000);
        delegator.requestDeallocate(address(adapter), 300);
        uint48 snapshot = _acceptedSnapshotBlock();
        _advanceReport();
        ICREOracle.Report memory rejected = _report(400);
        _deliver(rejected);
        bytes32 rejectedHash = oracle.rejectedReportHash();
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.acceptReport("");
        assertEq(oracle.rejectedReportHash(), rejectedHash);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(_acceptedSnapshotBlock(), snapshot);

        _deliver(_report(1000));
        assertEq(adapter.totalAssets(), 1000);

        assertEq(oracle.rejectedReportHash(), rejectedHash);
    }

    function test_WorkflowChangePreservesCachedReviewAndActiveAccounting() public {
        _fundPortfolio(1000);
        uint48 acceptedBlock = _acceptedSnapshotBlock();
        _advanceReport();
        ICREOracle.Report memory update = _report(400);
        _deliver(update);
        bytes memory payload = abi.encode(update);
        assertEq(oracle.rejectedReportHash(), keccak256(payload));
        bytes32 nextWorkflow = keccak256("replacement workflow");
        _proposeWorkflow(address(oracle), nextWorkflow);
        _acceptWorkflow(address(oracle), nextWorkflow);
        assertEq(workflowRegistry.workflowId(address(oracle)), nextWorkflow);
        assertEq(oracle.rejectedReportHash(), keccak256(payload));
        assertEq(_acceptedSnapshotBlock(), acceptedBlock);
        _assertReportedAssets(1000);
        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.totalAssets(), 1000);

        oracle.acceptReport(payload);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(_acceptedSnapshotBlock(), update.snapshotBlock);
        _assertReportedAssets(400);
        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.totalAssets(), 400);
    }

    function testFuzz_ReviewAllowsAnyDelay(uint32 age) public {
        _fundPortfolio(1000);
        _advanceReport();
        ICREOracle.Report memory update = _report(400);
        _deliver(update);
        bytes memory payload = abi.encode(update);
        age = uint32(bound(age, 1, 365 days));
        vm.warp(block.timestamp + age);
        oracle.acceptReport(payload);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(adapter.totalAssets(), 400);
    }

    function test_ReviewAfterOneYearIsAccepted() public {
        ICREOracle.Report memory update = _report(1000);
        _deliver(update);
        vm.warp(block.timestamp + 365 days);
        oracle.acceptReport(abi.encode(update));

        vm.roll(vm.getBlockNumber() + 1);
        assertEq(adapter.totalAssets(), 1000);
    }

    function test_UnfundedWithdrawalDefersAndEachReturnNeedsCoveringReport() public {
        _fundPortfolio(1000);
        vm.prank(account);
        _fixtureCashToAccount(1000);
        delegator.requestDeallocate(address(adapter), 600);
        _advanceReport();
        _deliver(_report(1000));

        assertEq(delegator.deallocate(address(adapter), 600), 0);
        vm.prank(account);
        adapter.pull(400);
        assertEq(delegator.deallocate(address(adapter), 1000), 0);
        assertEq(adapter.totalAssets(), 1000);
        _advanceReport();
        _deliver(_report(1000));
        assertEq(delegator.deallocate(address(adapter), 1000), 400);
        assertEq(adapter.totalAssets(), 600);

        vm.prank(account);
        adapter.pull(200);
        assertEq(delegator.deallocate(address(adapter), 1000), 0);
        _advanceReport();
        _deliver(_report(600));

        assertEq(delegator.deallocate(address(adapter), 1000), 200);
        assertEq(adapter.totalAssets(), 400);
    }
}
