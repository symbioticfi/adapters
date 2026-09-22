// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {merkleAdapterInitParams} from "test/helpers/MerkleInitialization.sol";

import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {CREOracle} from "src/contracts/merkle-adapter/oracle/CREOracle.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ORACLE_GUARD_ROLE, ORACLE_LIMITS_ROLE} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {stdError} from "forge-std/StdError.sol";
import {Vm} from "forge-std/Vm.sol";

import {CREOracleTestBase} from "test/adapters/merkle-adapter/oracle/CREOracle.t.sol";

contract MerkleAdapterOracleGuardTest is CREOracleTestBase {
    function test_ReportRejectionEmitsOneEventAndReplacesTheCachedReport() public {
        for (uint256 assets = 1; assets <= 2; ++assets) {
            ICREOracle.Report memory update = _report(assets);
            vm.recordLogs();
            _deliver(update);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(logs.length, 1);
            assertEq(logs[0].emitter, address(oracle));
            assertEq(
                logs[0].topics[0],
                keccak256("RejectReport(bytes32,(uint256,address,address,uint256,uint256,uint256,uint256))")
            );
            assertEq(logs[0].topics[1], keccak256(abi.encode(update)));
            assertEq(logs[0].data, abi.encode(update));
            assertEq(oracle.rejectedReportHash(), logs[0].topics[1]);
            assertTrue(oracle.oracleFrozen());
        }
    }

    function test_ManualFreezeEmitsFreezeEventWithoutReportHash() public {
        vm.recordLogs();
        oracle.freezeOracle();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(oracle));
        assertEq(logs[0].topics.length, 1);
        assertEq(logs[0].topics[0], keccak256("FreezeOracle()"));
        assertEq(logs[0].data.length, 0);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.rejectedReportHash(), bytes32(0));
    }

    function test_MulticallEnforcesEveryOracleRoleAndRollsBack() public {
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.revokeRole(ORACLE_GUARD_ROLE, address(this));
        uint256 previousGrowth = oracle.maxOracleGrowthBps();
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(oracle.setOracleLimits, (123, 456));
        calls[1] = abi.encodeCall(oracle.freezeOracle, ());
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), ORACLE_GUARD_ROLE
            )
        );
        oracle.multicall(calls);
        assertEq(oracle.maxOracleGrowthBps(), previousGrowth);
        assertFalse(oracle.oracleFrozen());
        oracle.grantRole(ORACLE_GUARD_ROLE, address(this));
        oracle.multicall(calls);
        assertEq(oracle.maxOracleGrowthBps(), 123);
        assertEq(oracle.maxOracleLossBps(), 456);
        assertTrue(oracle.oracleFrozen());
    }

    /// forge-config: default.isolate = true
    function test_RejectsExcessGrowthWithoutReplacingAcceptedNAV() public {
        _fundPortfolio(1000);
        _next(1101);
        vm.snapshotGasLastCall("MerkleAdapterOracleGuard", "rejectReport");

        assertEq(oracle.totalAssets(), 1000, "bad NAV must not replace accepted NAV");
        assertEq(oracle.nonce(), 3, "bad report must not advance accounting");
        assertEq(oracle.snapshotBlock(), 501);
        assertEq(oracle.snapshotTimestamp(), 10_190);
        assertTrue(oracle.oracleFrozen());
        vm.expectRevert(ICREOracle.OracleFrozen.selector);
        adapter.totalAssets();
    }

    function test_ZeroBaselineCannotBeInflatedByFirstReport() public {
        _deliver(_report(1));
        assertEq(oracle.nonce(), 0);
        assertTrue(oracle.oracleFrozen());
    }

    /// forge-config: default.isolate = true
    function test_ExactGrowthAndLossBoundariesAreAccepted() public {
        _fundPortfolio(1000);
        _next(1100);
        vm.snapshotGasLastCall("MerkleAdapterOracleGuard", "acceptReport");
        assertEq(oracle.totalAssets(), 1100);
        _next(990);
        assertEq(oracle.totalAssets(), 990);
        assertFalse(oracle.oracleFrozen());
    }

    function testFuzz_GrowthAndLossLimits(uint64 baseline, uint16 growthBps, uint16 lossBps, uint64 candidate) public {
        baseline = uint64(bound(baseline, 1, 1e12));
        growthBps = uint16(bound(growthBps, 0, 10_000));
        lossBps = uint16(bound(lossBps, 0, 10_000));
        candidate = uint64(bound(candidate, 0, uint256(baseline) * 3));
        _fundPortfolio(baseline);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(growthBps, lossBps);
        bool expected = candidate >= baseline
            ? uint256(candidate - baseline) * 10_000 <= uint256(baseline) * growthBps
            : uint256(baseline - candidate) * 10_000 <= uint256(baseline) * lossBps;
        _next(candidate);
        assertEq(oracle.oracleFrozen(), !expected);
        assertEq(oracle.nonce(), expected ? 4 : 3);
        assertEq(oracle.totalAssets(), expected ? candidate : baseline);
    }

    function test_FreezeLatchesAcrossGoodReportsAndLimitChanges() public {
        _fundPortfolio(1000);
        _next(899);
        uint256 timestamp = oracle.snapshotTimestamp();
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(10_000, 10_000);
        _next(1000);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 3);
        assertEq(oracle.snapshotTimestamp(), timestamp);

        oracle.unfreezeOracle(bytes(""));
        _next(1000);
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 4);
    }

    function testFuzz_ReportSequenceKeepsFreezeAndAcceptedState(uint16[16] memory changes, bool[16] memory clear)
        public
    {
        _fundPortfolio(1_000_000);
        for (uint256 i; i < changes.length; ++i) {
            if (clear[i]) oracle.unfreezeOracle(bytes(""));
            uint256 beforeNonce = oracle.nonce();
            uint256 beforeNAV = oracle.totalAssets();
            uint256 beforeSnapshot = oracle.snapshotTimestamp();
            uint256 candidate = beforeNAV * uint256(changes[i]) / 10_000;
            uint256 difference = candidate > beforeNAV ? candidate - beforeNAV : beforeNAV - candidate;
            bool accepted = !oracle.oracleFrozen() && difference * 10 <= beforeNAV;
            uint256 candidateSnapshot = _next(candidate);
            assertEq(oracle.oracleFrozen(), !accepted);
            assertEq(oracle.nonce(), beforeNonce + (accepted ? 1 : 0));
            assertEq(oracle.totalAssets(), accepted ? candidate : beforeNAV);
            assertEq(oracle.snapshotTimestamp(), accepted ? candidateSnapshot : beforeSnapshot);
        }
    }

    function test_ZeroLimitsAcceptUnchangedNAVOnly() public {
        _fundPortfolio(1000);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(0, 0);
        _next(1000);
        assertEq(oracle.nonce(), 4);
        _next(999);
        assertTrue(oracle.oracleFrozen());
    }

    function test_AllocationAndWithdrawalAreNotPerformanceChanges() public {
        _fundPortfolio(1000);
        asset.transfer(adapter.vault(), 9000);
        delegator.allocate(address(adapter), 9000);
        _next(1000);
        _next(10_000);
        assertEq(adapter.totalAssets(), 10_000);
        delegator.requestDeallocate(address(adapter), 9000);
        _next(10_000);
        _next(10_000);
        assertEq(adapter.totalAssets(), 10_000);
        assertEq(delegator.deallocate(address(adapter), 9000), 9000);
        assertEq(adapter.totalAssets(), 1000);
        assertFalse(oracle.oracleFrozen());
    }

    function test_WorkflowCutoverPreservesQueuedAllocationAndWithdrawal() public {
        _fundPortfolio(1000);
        bytes32 nextWorkflow = keccak256("next NAV workflow");
        _proposeWorkflow(address(oracle), nextWorkflow);
        asset.transfer(adapter.vault(), 9000);
        delegator.allocate(address(adapter), 9000);
        _next(1000);
        assertEq(oracle.workflowId(), WORKFLOW);
        assertEq(workflowRegistry.proposals(address(oracle)), _proposalHash(nextWorkflow));
        assertEq(oracle.nonce(), 4);
        assertEq(_batch(false).allocation, 9000);
        assertEq(adapter.totalAssets(), 10_000);

        delegator.requestDeallocate(address(adapter), 800);
        assertEq(_batch(true).deallocation, 800);
        _acceptWorkflow(address(oracle), nextWorkflow);
        assertEq(oracle.nonce(), 4);
        assertEq(oracle.totalAssets(), 1000);
        assertEq(_batch(false).allocation, 9000);
        assertEq(_batch(true).deallocation, 800);
        assertEq(adapter.totalAssets(), 10_000);

        _advance();
        ICREOracle.Report memory update = _report(10_000);
        (bytes memory raw, bytes[] memory signatures) = _signedReport(update, nextWorkflow);
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertEq(oracle.nonce(), 5);
        assertEq(oracle.totalAssets(), 10_000);
        assertEq(adapter.reservedAssets(), 0);
        assertEq(adapter.totalAssets(), 10_000);

        _advance();
        update = _report(10_000);
        (raw, signatures) = _signedReport(update, nextWorkflow);
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertEq(oracle.nonce(), 6);
        assertEq(oracle.totalAssets(), 9200);
        assertEq(adapter.reservedAssets(), 800);
        assertEq(adapter.totalAssets(), 10_000);
        assertFalse(oracle.oracleFrozen());
        assertEq(delegator.deallocate(address(adapter), 800), 800);
        assertEq(adapter.totalAssets(), 9200);
    }

    function test_UninvestedQueueDoesNotDiluteNAVLossLimit() public {
        _fundPortfolio(1000);
        asset.transfer(adapter.vault(), 1_000_000);
        delegator.allocate(address(adapter), 1_000_000);
        _next(899);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 1000);
    }

    function test_ExpectedOutflowCannotHideAdditionalLoss() public {
        _fundPortfolio(1000);
        delegator.requestDeallocate(address(adapter), 800);
        _next(1000);
        _next(899); // 800 reserved + 99 remaining NAV means an actual 101 loss.
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 1000);
    }

    function test_MaturedReservesMustBeFundedEvenWithReviewedReport() public {
        _fundPortfolio(1000);
        delegator.requestDeallocate(address(adapter), 1000);
        _next(1000);
        vm.prank(address(adapter));
        asset.transfer(address(123), 1);
        _advance();
        ICREOracle.Report memory update = _report(1000);
        _expectRecoveryFailure(update, ICREOracle.InvalidReport.selector);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 4);
    }

    function test_OverflowingReportFreezesInsteadOfRollingBackDetection() public {
        _fundPortfolio(1000);
        delegator.requestDeallocate(address(adapter), 1);
        _next(1000);
        _next(type(uint256).max);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 1000);
    }

    function testFuzz_BaselineOverflowRevertsWithoutChangingOracle(bool reviewed) public {
        _fundPortfolio(1000);
        _advance();
        ICREOracle.Report memory update = _report(3000);
        bytes memory payload = abi.encode(update);
        if (reviewed) _deliver(update);
        bytes32 rejectedHash = oracle.rejectedReportHash();
        vm.mockCall(address(adapter), abi.encodeCall(IMerkleAdapter.currentBatch, ()), abi.encode(type(uint256).max, 0));
        vm.expectRevert(stdError.arithmeticError);
        if (reviewed) oracle.unfreezeOracle(payload);
        else _deliver(update);
        assertEq(oracle.oracleFrozen(), reviewed);
        assertEq(oracle.rejectedReportHash(), rejectedHash);
        assertEq(oracle.nonce(), update.nonce - 1);
        assertEq(oracle.totalAssets(), 1000);
    }

    function testFuzz_ReserveOverflowCannotBeReviewed(bool matured) public {
        _fundPortfolio(1000);
        _advance();
        ICREOracle.Report memory update = _report(type(uint256).max);
        if (matured) {
            _setAdapterState(IMerkleAdapter.deallocatable.selector, 0, 1);
        } else {
            _setAdapterState(IMerkleAdapter.nextBatch.selector, 0, 1);
        }
        _expectRecoveryFailure(update, ICREOracle.InvalidReport.selector);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.nonce(), update.nonce - 1);
        assertEq(oracle.totalAssets(), 1000);
    }

    function test_MaximumNonOverflowingBaselineIsAccepted() public {
        _fundPortfolio(1000);
        vm.mockCall(
            address(adapter), abi.encodeCall(IMerkleAdapter.currentBatch, ()), abi.encode(type(uint256).max - 1000, 0)
        );
        _next(type(uint256).max);
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), type(uint256).max);
    }

    function test_ReviewAppliesExactAuthenticatedReportOnce() public {
        _fundPortfolio(1000);
        _advance();
        ICREOracle.Report memory update = _report(3000);
        _deliver(update);
        assertTrue(oracle.oracleFrozen());
        bytes memory payload = abi.encode(update);
        assertEq(oracle.rejectedReportHash(), keccak256(payload));
        oracle.unfreezeOracle(payload);
        assertEq(oracle.totalAssets(), 3000);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(payload);
        _next(4000);
        assertTrue(oracle.oracleFrozen());
    }

    function test_ReviewDoesNotAuthorizeModifiedReport() public {
        _fundPortfolio(1000);
        _advance();
        ICREOracle.Report memory update = _report(3000);
        _deliver(update);
        bytes32 rejectedHash = oracle.rejectedReportHash();
        update.totalAssets++;
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(abi.encode(update));
        assertEq(oracle.rejectedReportHash(), rejectedHash);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 1000);
    }

    function test_ReviewCannotBypassOracleAuthentication() public {
        ICREOracle.Report memory update = _report(1000);
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(abi.encode(update));
        vm.expectRevert(ICREOracle.InvalidSender.selector);
        oracle.onReport(_metadata(), abi.encode(update));
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 0);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        vm.prank(address(adapter));
        vm.expectRevert(ICREOracle.InvalidSender.selector);
        oracle.onReport(_metadata(), abi.encode(update));
        assertFalse(oracle.oracleFrozen());
    }

    /// forge-config: default.isolate = true
    function test_GuardAndLimitsRolesAreIndependentAndEnumerable() public {
        address guard = makeAddr("guard");
        address limits = makeAddr("limits");
        oracle.revokeRole(ORACLE_GUARD_ROLE, address(this));
        oracle.grantRole(ORACLE_GUARD_ROLE, guard);
        oracle.grantRole(ORACLE_LIMITS_ROLE, limits);
        assertEq(oracle.getRoleMemberCount(ORACLE_GUARD_ROLE), 1);
        assertEq(oracle.getRoleMember(ORACLE_GUARD_ROLE, 0), guard);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), ORACLE_GUARD_ROLE
            )
        );
        oracle.unfreezeOracle(bytes(""));
        vm.prank(guard);
        oracle.freezeOracle();
        vm.snapshotGasLastCall("MerkleAdapterOracleGuard", "freezeOracle");
        assertTrue(oracle.oracleFrozen());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guard, ORACLE_LIMITS_ROLE)
        );
        vm.prank(guard);
        oracle.setOracleLimits(100, 200);
        vm.prank(limits);
        oracle.setOracleLimits(100, 200);
        vm.snapshotGasLastCall("MerkleAdapterOracleGuard", "setOracleLimits");
        assertTrue(oracle.oracleFrozen());
        vm.prank(guard);
        oracle.unfreezeOracle(bytes(""));
        vm.snapshotGasLastCall("MerkleAdapterOracleGuard", "unfreezeOracle");
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.maxOracleGrowthBps(), 100);
        assertEq(oracle.maxOracleLossBps(), 200);
    }

    function test_RejectsInvalidLimitsWithoutChangingPolicy() public {
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        vm.expectRevert(ICREOracle.InvalidOracleLimit.selector);
        oracle.setOracleLimits(10_001, 1000);
        vm.expectRevert(ICREOracle.InvalidOracleLimit.selector);
        oracle.setOracleLimits(1000, 10_001);
        assertEq(oracle.maxOracleGrowthBps(), 1000);
        assertEq(oracle.maxOracleLossBps(), 1000);
        assertEq(oracle.MAX_ORACLE_AGE(), 1 days);
    }

    function testFuzz_ImmutableAgeBoundaryAndFreshReportRecovery(uint256 maxAge) public {
        _fundPortfolio(1000);
        _advance();
        _deliver(_report(1000));
        _migrateWithMaxOracleAge(bound(maxAge, 1, 30 days));
        vm.warp(oracle.snapshotTimestamp() + oracle.MAX_ORACLE_AGE());
        assertEq(adapter.totalAssets(), 1000);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(ICREOracle.OracleStale.selector);
        adapter.totalAssets();
        vm.expectRevert(ICREOracle.OracleStale.selector);
        adapter.allocatable();
        oracle.unfreezeOracle(bytes(""));
        vm.expectRevert(ICREOracle.OracleStale.selector);
        adapter.totalAssets();
        _advance();
        _deliver(_report(1000));
        assertEq(adapter.totalAssets(), 1000);
    }

    function test_ReviewedReportMustAlsoMeetImmutableAgeLimit() public {
        _fundPortfolio(1000);
        _migrateWithMaxOracleAge(2);
        vm.warp(block.timestamp + 10);
        vm.roll(block.number + 1);
        ICREOracle.Report memory update = _report(1000);
        update.snapshotTimestamp -= 2;
        _expectRecoveryFailure(update, ICREOracle.InvalidReport.selector);
        assertTrue(oracle.oracleFrozen());
    }

    function test_FreezeBlocksVaultFlowsButKeepsApprovedManagementAvailable() public {
        _fundPortfolio(1000);
        oracle.freezeOracle();
        asset.transfer(adapter.vault(), 10);
        vm.expectRevert(ICREOracle.OracleFrozen.selector);
        delegator.allocate(address(adapter), 10);
        vm.expectRevert(ICREOracle.OracleFrozen.selector);
        delegator.requestDeallocate(address(adapter), 10);
        vm.expectRevert(ICREOracle.OracleFrozen.selector);
        delegator.deallocate(address(adapter), 10);
        vm.expectRevert(ICREOracle.OracleFrozen.selector);
        adapter.allocatable();

        bytes memory data = abi.encodeCall(IERC20.approve, (address(123), 10));
        bytes memory mask = new bytes(data.length);
        bytes32 leaf = MerkleAdapterVerifier.leaf(address(asset), 0, data, mask);
        RootRegistry(MerkleAccount(payable(account)).ROOT_REGISTRY()).setRoot(account, leaf);
        MerkleAccount(payable(account)).acceptRoot(leaf);
        MerkleAccount(payable(account)).grantRole(leaf, address(this));
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = IMerkleAccount.Action({
            target: address(asset), value: 0, data: data, dataMask: mask, proof: new bytes32[](0)
        });
        MerkleAccount(payable(account)).manage(actions);
        assertEq(asset.allowance(adapter.account(), address(123)), 10);
        assertTrue(oracle.oracleFrozen());
    }

    function test_RealForwarderDeliveryCanBeRecoveredWithoutNewExecution() public {
        _fundPortfolio(1000);
        _advance();
        ICREOracle.Report memory update = _report(2000);
        (bytes memory raw, bytes[] memory signatures) = _signedReport(update, WORKFLOW, bytes32(uint256(100)));
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertTrue(forwarder.getTransmissionInfo(address(oracle), bytes32(uint256(100)), bytes2(0)).success);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 3);
        vm.expectRevert(ICREOracle.OracleFrozen.selector);
        adapter.totalAssets();
        assertTrue(oracle.oracleFrozen());

        oracle.unfreezeOracle(abi.encode(update));
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        assertEq(oracle.nonce(), 4);
        assertEq(adapter.totalAssets(), 2000);
    }

    function test_BootstrapCreatesAddressesBeforeWorkflowWithoutMigration() public {
        address bootstrapped = AdapterFactory(adapter.FACTORY())
            .create(1, address(this), abi.encode(adapter.vault(), abi.encode(merkleAdapterInitParams(address(this)))));
        address receiver = MerkleAdapter(payable(bootstrapped)).oracle();
        assertEq(CREOracle(receiver).FORWARDER(), address(forwarder));
        assertEq(CREOracle(receiver).workflowId(), bytes32(0));
        assertEq(CREOracle(receiver).version(), 1);
        vm.expectRevert(ICREOracle.OracleStale.selector);
        MerkleAdapter(payable(bootstrapped)).totalAssets();

        bytes32 workflow = keccak256(abi.encode("reviewed workflow for deployed adapter", bootstrapped));
        _proposeWorkflow(receiver, workflow);
        _acceptWorkflow(receiver, workflow);
        assertEq(MerkleAdapter(payable(bootstrapped)).oracle(), receiver);
        assertEq(CREOracle(receiver).adapter(), bootstrapped);
        assertEq(CREOracle(receiver).workflowId(), workflow);
        assertEq(CREOracle(receiver).version(), 1);
        vm.expectRevert(ICREOracle.OracleStale.selector);
        MerkleAdapter(payable(bootstrapped)).totalAssets();

        ICREOracle.Report memory update = ICREOracle.Report({
            chainId: block.chainid,
            oracle: receiver,
            adapter: bootstrapped,
            nonce: 1,
            totalAssets: 0,
            snapshotBlock: block.number - 1,
            snapshotTimestamp: block.timestamp - 1
        });
        (bytes memory raw, bytes[] memory signatures) = _signedReport(update, workflow);
        forwarder.report(receiver, raw, bytes(""), signatures);
        assertEq(CREOracle(receiver).nonce(), 1);
        assertEq(MerkleAdapter(payable(bootstrapped)).totalAssets(), 0);
    }

    function test_RevokedOracleRolesImmediatelyLoseAuthority() public {
        address guard = makeAddr("guard");
        oracle.grantRole(ORACLE_GUARD_ROLE, guard);
        vm.prank(guard);
        oracle.freezeOracle();
        oracle.revokeRole(ORACLE_GUARD_ROLE, guard);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guard, ORACLE_GUARD_ROLE)
        );
        vm.prank(guard);
        oracle.unfreezeOracle(bytes(""));
        assertTrue(oracle.oracleFrozen());
        oracle.unfreezeOracle(bytes(""));
        assertFalse(oracle.oracleFrozen());
    }

    function _fundPortfolio(uint256 amount) internal {
        _deliver(_report(0));
        _afterCutoff();
        asset.transfer(adapter.vault(), amount);
        delegator.allocate(address(adapter), amount);
        _next(0);
        _next(amount);
        assertEq(oracle.nonce(), 3);
        assertEq(adapter.totalAssets(), amount);
    }

    function _advance() internal {
        _advanceReport();
    }

    function _next(uint256 assets) internal returns (uint256 candidateSnapshot) {
        _advance();
        ICREOracle.Report memory update = _report(assets);
        candidateSnapshot = update.snapshotTimestamp;
        _deliver(update);
        _afterCutoff();
    }
}
