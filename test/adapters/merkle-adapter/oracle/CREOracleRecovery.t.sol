// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IMerkleAdapterOracle} from "src/interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
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
        uint48 acceptedBlock = oracle.snapshotBlock();
        uint48 acceptedTimestamp = oracle.snapshotTimestamp();
        delegator.requestDeallocate(address(adapter), 300);
        _advanceReport();
        ICREOracle.Report memory rejected = _report(1800);
        bytes memory rejectedPayload = abi.encode(rejected);
        _deliver(rejected);

        assertEq(oracle.rejectedReportHash(), keccak256(rejectedPayload));
        assertEq(oracle.snapshotBlock(), acceptedBlock);
        assertEq(oracle.snapshotTimestamp(), acceptedTimestamp);
        _assertReportedAssets(1000);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.stagedLiquidity(), 300);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.pendingDeallocation(), 300);
        assertEq(asset.balanceOf(address(adapter)), 1000);
        assertEq(asset.balanceOf(adapter.vault()), 0);

        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(uint32(ORACLE_LIMIT_PRECISION), uint32(ORACLE_LIMIT_PRECISION), 0);
        assertEq(oracle.snapshotBlock(), acceptedBlock);
        assertEq(adapter.totalAssets(), 1000);

        _advanceReport();
        ICREOracle.Report memory accepted = _report(1900);
        _deliver(accepted);

        assertEq(oracle.snapshotBlock(), accepted.snapshotBlock);
        assertEq(oracle.snapshotTimestamp(), accepted.snapshotTimestamp);
        _assertReportedAssets(1900);
        assertEq(adapter.totalAssets(), 1900);
        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(adapter.releasedLiquidity(), 300);
        assertEq(adapter.pendingDeallocation(), 300);
        assertEq(asset.balanceOf(address(adapter)), 1000);
        assertEq(asset.balanceOf(adapter.vault()), 0);

        assertEq(oracle.rejectedReportHash(), keccak256(rejectedPayload));
        vm.expectRevert(ICREOracle.StaleReport.selector);
        oracle.acceptReport(rejectedPayload);
        assertEq(oracle.snapshotBlock(), accepted.snapshotBlock);
        assertEq(oracle.snapshotTimestamp(), accepted.snapshotTimestamp);
        assertEq(adapter.totalAssets(), 1900);
        assertEq(adapter.releasedLiquidity(), 300);
        assertEq(oracle.rejectedReportHash(), keccak256(rejectedPayload));
    }

    function test_WithinLimitsReportAfterDeviationRejectionUsesActiveBaseline() public {
        _fundPortfolio(1000);
        uint48 acceptedBlock = oracle.snapshotBlock();
        uint48 acceptedTimestamp = oracle.snapshotTimestamp();
        delegator.requestDeallocate(address(adapter), 300);
        _advanceReport();
        ICREOracle.Report memory rejected = _report(3000);
        bytes memory rejectedPayload = abi.encode(rejected);
        _deliver(rejected);

        assertEq(oracle.rejectedReportHash(), keccak256(rejectedPayload));
        assertEq(oracle.snapshotBlock(), acceptedBlock);
        assertEq(oracle.snapshotTimestamp(), acceptedTimestamp);
        _assertReportedAssets(1000);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.stagedLiquidity(), 300);
        assertEq(adapter.releasedLiquidity(), 0);
        assertEq(adapter.pendingDeallocation(), 300);
        assertEq(asset.balanceOf(address(adapter)), 1000);
        assertEq(asset.balanceOf(adapter.vault()), 0);

        _advanceReport();
        ICREOracle.Report memory accepted = _report(1050);
        _deliver(accepted);

        assertEq(oracle.snapshotBlock(), accepted.snapshotBlock);
        assertEq(oracle.snapshotTimestamp(), accepted.snapshotTimestamp);
        _assertReportedAssets(1050);
        assertEq(adapter.totalAssets(), 1050);
        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.stagedLiquidity(), 0);
        assertEq(adapter.releasedLiquidity(), 300);
        assertEq(adapter.pendingDeallocation(), 300);
        assertEq(asset.balanceOf(address(adapter)), 1000);
        assertEq(asset.balanceOf(adapter.vault()), 0);

        assertEq(oracle.rejectedReportHash(), keccak256(rejectedPayload));
        vm.expectRevert(ICREOracle.StaleReport.selector);
        oracle.acceptReport(rejectedPayload);
        assertEq(oracle.snapshotBlock(), accepted.snapshotBlock);
        assertEq(oracle.snapshotTimestamp(), accepted.snapshotTimestamp);
        assertEq(adapter.totalAssets(), 1050);
        assertEq(adapter.releasedLiquidity(), 300);
        assertEq(oracle.rejectedReportHash(), keccak256(rejectedPayload));
    }

    function test_RejectedReportKeepsActiveNAVUsableAfterLongDelay() public {
        _fundPortfolio(1000);
        _releasePortfolio(300);
        uint48 acceptedBlock = oracle.snapshotBlock();
        uint48 acceptedTimestamp = oracle.snapshotTimestamp();
        vm.warp(uint256(acceptedTimestamp) + 1000);
        vm.roll(vm.getBlockNumber() + 1);
        ICREOracle.Report memory rejected = _report(3000);
        _deliver(rejected);

        assertEq(adapter.totalAssets(), 1000);
        asset.transfer(adapter.vault(), 40);
        assertEq(delegator.allocate(address(adapter), 40), 40);
        assertEq(delegator.deallocate(address(adapter), 100), 100);
        assertEq(adapter.totalAssets(), 940);
        assertEq(oracle.snapshotBlock(), acceptedBlock);
        assertEq(oracle.snapshotTimestamp(), acceptedTimestamp);
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(rejected)));

        vm.warp(uint256(acceptedTimestamp) + 10_000);
        assertEq(adapter.totalAssets(), 940);
        (uint48 snapshot,) = oracle.latestSnapshot();
        assertEq(snapshot, acceptedBlock);
        assertEq(adapter.netFlow(), 940);
        assertEq(adapter.releasedLiquidity(), 200);
        assertEq(adapter.pendingDeallocation(), 200);
        assertEq(asset.balanceOf(address(adapter)), 940);
        assertEq(asset.balanceOf(adapter.vault()), 100);
        assertEq(oracle.snapshotBlock(), acceptedBlock);
        assertEq(oracle.snapshotTimestamp(), acceptedTimestamp);
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
        assertEq(oracle.snapshotBlock(), older.snapshotBlock);
        assertEq(oracle.snapshotTimestamp(), older.snapshotTimestamp);
        assertEq(adapter.totalAssets(), 1050);
        assertEq(oracle.rejectedReportHash(), keccak256(payload));
        oracle.acceptReport(payload);
        assertEq(oracle.snapshotBlock(), rejected.snapshotBlock);
        assertEq(oracle.snapshotTimestamp(), rejected.snapshotTimestamp);
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
        assertEq(oracle.snapshotBlock(), rejected.snapshotBlock);
        assertEq(oracle.snapshotTimestamp(), rejected.snapshotTimestamp);
        assertEq(adapter.totalAssets(), 1800);
        assertEq(oracle.rejectedReportHash(), keccak256(payload));
    }

    function test_LateReviewPreservesSnapshotTimeAndAllowsTheNextCompletedSnapshot() public {
        _fundPortfolio(1000);
        _advanceReport();
        ICREOracle.Report memory rejected = _report(3000);
        _deliver(rejected);
        vm.warp(rejected.snapshotTimestamp + 1000);
        oracle.acceptReport(abi.encode(rejected));
        assertEq(oracle.snapshotTimestamp(), rejected.snapshotTimestamp);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        _deliver(_report(3000));

        assertEq(oracle.snapshotTimestamp(), rejected.snapshotTimestamp + 1000);
    }

    function test_ReviewedRejectedReportIsAppliedWithoutRedelivery() public {
        ICREOracle.Report memory update = _report(1000);
        _deliver(update);

        assertEq(oracle.snapshotBlock(), 0);
        oracle.acceptReport(abi.encode(update));

        assertEq(oracle.snapshotBlock(), update.snapshotBlock);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
    }

    function test_GuardCannotApproveAReportBeforeAuthenticatedRejection() public {
        bytes memory payload = abi.encode(_report(1000));
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.acceptReport(payload);

        assertEq(oracle.snapshotBlock(), 0);
        vm.expectRevert(IMerkleAdapterOracle.OracleStale.selector);
        adapter.totalAssets();
        _deliver(_report(0));
        assertEq(oracle.snapshotBlock(), 499);
    }

    function testFuzz_MalformedOrUncachedBytesCannotChangeRecovery(bytes memory report) public {
        _deliver(_report(1000));
        bytes32 rejectedHash = oracle.rejectedReportHash();
        vm.assume(keccak256(report) != rejectedHash);
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.acceptReport(report);

        assertEq(oracle.rejectedReportHash(), rejectedHash);
        assertEq(oracle.snapshotBlock(), 0);
        vm.expectRevert(IMerkleAdapterOracle.OracleStale.selector);
        adapter.totalAssets();
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
        oracle.acceptReport(abi.encode(update));

        assertEq(oracle.rejectedReportHash(), rejectedHash);
        assertEq(oracle.snapshotBlock(), 0);
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
        assertEq(oracle.snapshotBlock(), latest.snapshotBlock);
        assertEq(adapter.totalAssets(), 3100);
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

        assertEq(oracle.rejectedReportHash(), rejectedHash);
        assertEq(adapter.totalAssets(), 1000);
    }

    function test_EmptyReportCannotClearCandidateOrChangeActiveState() public {
        _fundPortfolio(1000);
        delegator.requestDeallocate(address(adapter), 300);
        uint48 snapshot = oracle.snapshotTimestamp();
        _advanceReport();
        ICREOracle.Report memory rejected = _report(400);
        _deliver(rejected);
        bytes32 rejectedHash = oracle.rejectedReportHash();
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.acceptReport("");
        assertEq(oracle.rejectedReportHash(), rejectedHash);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(oracle.snapshotTimestamp(), snapshot);
        assertEq(adapter.pendingDeallocation(), 300);
        _deliver(_report(1000));
        assertEq(adapter.totalAssets(), 1000);
        assertEq(adapter.pendingDeallocation(), 300);
        assertEq(oracle.rejectedReportHash(), rejectedHash);
    }

    function test_WorkflowChangePreservesCachedReviewAndActiveAccounting() public {
        _fundPortfolio(1000);
        uint48 acceptedBlock = oracle.snapshotBlock();
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
        assertEq(oracle.snapshotBlock(), acceptedBlock);
        _assertReportedAssets(1000);
        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.totalAssets(), 1000);

        oracle.acceptReport(payload);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        assertEq(oracle.snapshotBlock(), update.snapshotBlock);
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
        vm.warp(update.snapshotTimestamp + age);
        oracle.acceptReport(payload);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        assertEq(adapter.totalAssets(), 400);
    }

    function test_ReviewAfterOneYearIsAccepted() public {
        ICREOracle.Report memory update = _report(1000);
        _deliver(update);
        vm.warp(update.snapshotTimestamp + 365 days);
        oracle.acceptReport(abi.encode(update));

        assertEq(adapter.totalAssets(), 1000);
    }

    function test_UnfundedWithdrawalDefersAndEachReturnNeedsCoveringReport() public {
        _fundPortfolio(1000);
        vm.prank(account);
        adapter.push(1000);
        delegator.requestDeallocate(address(adapter), 600);
        _advanceReport();
        _deliver(_report(1000));

        assertEq(adapter.pendingDeallocation(), 600);
        assertEq(delegator.deallocate(address(adapter), 600), 0);
        vm.prank(account);
        adapter.pull(400);
        assertEq(delegator.deallocate(address(adapter), 1000), 0);
        assertEq(adapter.totalAssets(), 1000);
        _advanceReport();
        _deliver(_report(1000));
        assertEq(delegator.deallocate(address(adapter), 1000), 400);
        assertEq(adapter.totalAssets(), 600);
        assertEq(adapter.pendingDeallocation(), 200);
        vm.prank(account);
        adapter.pull(200);
        assertEq(delegator.deallocate(address(adapter), 1000), 0);
        _advanceReport();
        _deliver(_report(600));

        assertEq(delegator.deallocate(address(adapter), 1000), 200);
        assertEq(adapter.totalAssets(), 400);
        assertEq(adapter.pendingDeallocation(), 0);
    }
}
