// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";
import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {ICREOracle, ORACLE_GUARD_ROLE} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {
    ICREOracleBase,
    ORACLE_LIMITS_ROLE,
    ORACLE_LIMIT_PRECISION
} from "src/interfaces/merkle-adapter/oracle/ICREOracleBase.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";
import {CREOracleTestBase} from "test/adapters/merkle-adapter/oracle/CREOracle.t.sol";

contract MerkleAdapterOracleGuardTest is CREOracleTestBase {
    using stdStorage for StdStorage;

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
        uint256 previousGrowth = oracle.maxOracleGrowth();
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(oracle.setOracleLimits, (12_300, 45_600, 0));
        calls[1] = abi.encodeCall(oracle.freezeOracle, ());
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), ORACLE_GUARD_ROLE
            )
        );
        oracle.multicall(calls);
        assertEq(oracle.maxOracleGrowth(), previousGrowth);
        assertFalse(oracle.oracleFrozen());
        oracle.grantRole(ORACLE_GUARD_ROLE, address(this));
        oracle.multicall(calls);
        assertEq(oracle.maxOracleGrowth(), 12_300);
        assertEq(oracle.maxOracleLoss(), 45_600);
        assertTrue(oracle.oracleFrozen());
    }

    function test_SubUnitMovementAllowanceRoundsDown() public {
        _fundPortfolio(ORACLE_LIMIT_PRECISION - 1);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(1, 1, 0);
        _next(ORACLE_LIMIT_PRECISION);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), ORACLE_LIMIT_PRECISION - 1);
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
        vm.snapshotGasLastFrame("MerkleAdapterOracleGuard", "freezeOracle");
        assertTrue(oracle.oracleFrozen());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guard, ORACLE_LIMITS_ROLE)
        );
        vm.prank(guard);
        oracle.setOracleLimits(10_000, 20_000, 0);
        vm.prank(limits);
        oracle.setOracleLimits(10_000, 20_000, 0);
        vm.snapshotGasLastFrame("MerkleAdapterOracleGuard", "setOracleLimits");
        assertTrue(oracle.oracleFrozen());
        vm.prank(guard);
        oracle.unfreezeOracle(bytes(""));
        vm.snapshotGasLastFrame("MerkleAdapterOracleGuard", "unfreezeOracle");
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.maxOracleGrowth(), 10_000);
        assertEq(oracle.maxOracleLoss(), 20_000);
    }

    function test_RejectsInvalidLimitsWithoutChangingPolicy() public {
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.freezeOracle();
        uint256[3] memory invalid =
            [ORACLE_LIMIT_PRECISION + 1, (uint256(1) << 32) | ORACLE_LIMIT_PRECISION / 10, type(uint256).max];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(ICREOracleBase.InvalidOracleLimit.selector);
            oracle.setOracleLimits(invalid[i], ORACLE_LIMIT_PRECISION / 10, 0);
            vm.expectRevert(ICREOracleBase.InvalidOracleLimit.selector);
            oracle.setOracleLimits(ORACLE_LIMIT_PRECISION / 10, invalid[i], 0);
            assertEq(oracle.maxOracleGrowth(), ORACLE_LIMIT_PRECISION / 10);
            assertEq(oracle.maxOracleLoss(), ORACLE_LIMIT_PRECISION / 10);
            assertTrue(oracle.oracleFrozen());
        }
        assertEq(oracle.MAX_ORACLE_AGE(), 1 days);
    }

    function testFuzz_RejectsFullWidthInvalidLimits(uint256 invalid, bool growth) public {
        invalid = bound(invalid, ORACLE_LIMIT_PRECISION + 1, type(uint256).max);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        vm.expectRevert(ICREOracleBase.InvalidOracleLimit.selector);
        oracle.setOracleLimits(
            growth ? invalid : ORACLE_LIMIT_PRECISION / 10, growth ? ORACLE_LIMIT_PRECISION / 10 : invalid, 0
        );
        assertEq(oracle.maxOracleGrowth(), ORACLE_LIMIT_PRECISION / 10);
        assertEq(oracle.maxOracleLoss(), ORACLE_LIMIT_PRECISION / 10);
        assertFalse(oracle.oracleFrozen());
    }

    function testFuzz_PackedLimitsAndFreezeRemainIndependent(uint32 growth, uint32 loss, uint128 tolerance) public {
        growth = uint32(bound(growth, 0, ORACLE_LIMIT_PRECISION));
        loss = uint32(bound(loss, 0, ORACLE_LIMIT_PRECISION));
        bytes32 slot = bytes32(
            stdstore.target(address(oracle)).sig(ICREOracleBase.maxOracleGrowth.selector).enable_packed_slots().find()
        );
        assertEq(
            bytes32(
                stdstore.target(address(oracle))
                    .sig(ICREOracleBase.oracleTolerance.selector)
                    .enable_packed_slots()
                    .find()
            ),
            slot
        );
        assertEq(
            bytes32(
                stdstore.target(address(oracle)).sig(ICREOracleBase.maxOracleLoss.selector).enable_packed_slots().find()
            ),
            slot
        );
        assertNotEq(
            bytes32(
                stdstore.target(address(oracle)).sig(ICREOracle.oracleFrozen.selector).enable_packed_slots().find()
            ),
            slot
        );
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(growth, loss, tolerance);
        _assertPackedLimits(slot, growth, loss, tolerance, false);
        oracle.freezeOracle();
        _assertPackedLimits(slot, growth, loss, tolerance, true);
        oracle.setOracleLimits(loss, growth, tolerance);
        _assertPackedLimits(slot, loss, growth, tolerance, true);
        oracle.unfreezeOracle("");
        _assertPackedLimits(slot, loss, growth, tolerance, false);

        _deliver(_report(uint256(tolerance) + 1)); // Rejection changes only the separate freeze flag.
        _assertPackedLimits(slot, loss, growth, tolerance, true);
        oracle.unfreezeOracle("");
        oracle.setOracleLimits(0, ORACLE_LIMIT_PRECISION, 0);
        _assertPackedLimits(slot, 0, ORACLE_LIMIT_PRECISION, 0, false);
    }

    function testFuzz_ImmutableAgeBoundaryAndFreshReportRecovery(uint256 maxAge) public {
        _fundPortfolio(1000);
        _advance();
        _deliver(_report(1000));
        _migrateWithMaxOracleAge(uint48(bound(maxAge, 1, 30 days)));
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
        _advanceReport();
        ICREOracle.Report memory update = _report(1000);
        vm.warp(block.timestamp + 3);
        _expectRecoveryFailure(update, ICREOracle.InvalidReport.selector);
        assertTrue(oracle.oracleFrozen());
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

    function _assertPackedLimits(bytes32 slot, uint256 growth, uint256 loss, uint256 tolerance, bool frozen)
        internal
        view
    {
        assertEq(oracle.maxOracleGrowth(), growth);
        assertEq(oracle.maxOracleLoss(), loss);
        assertEq(oracle.oracleTolerance(), tolerance);
        assertEq(oracle.oracleFrozen(), frozen);
        assertEq(oracle.adapter(), address(adapter));
        assertEq(uint256(vm.load(address(oracle), slot)), (tolerance << 64) | (loss << 32) | growth);
    }

    function test_ReportRejectionEmitsOneEventAndReplacesCachedReport() public {
        for (uint256 assets = 1; assets <= 2; ++assets) {
            ICREOracle.Report memory update = _report(assets);
            vm.recordLogs();
            _deliver(update);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(logs.length, 1);
            assertEq(logs[0].emitter, address(oracle));
            assertEq(logs[0].topics[0], keccak256("RejectReport(bytes32,(uint256,address,uint256,uint48,uint48))"));
            assertEq(logs[0].topics[1], keccak256(abi.encode(update)));
            assertEq(logs[0].data, abi.encode(update));
            assertEq(oracle.rejectedReportHash(), logs[0].topics[1]);
            assertTrue(oracle.oracleFrozen());
        }
    }

    /// forge-config: default.isolate = true
    function test_RejectsExcessGrowthWithoutReplacingAcceptedValuation() public {
        _fundPortfolio(1000);
        uint48 acceptedBlock = oracle.snapshotBlock();
        uint48 acceptedTime = oracle.snapshotTimestamp();
        _advance();
        _deliver(_report(1101));
        vm.snapshotGasLastFrame("MerkleAdapterOracleGuard", "rejectReport");
        assertEq(oracle.totalAssets(), 1000);
        assertEq(oracle.snapshotBlock(), acceptedBlock);
        assertEq(oracle.snapshotTimestamp(), acceptedTime);
        assertTrue(oracle.oracleFrozen());
        vm.expectRevert(ICREOracle.OracleFrozen.selector);
        adapter.totalAssets();
    }

    function test_ZeroBaselineCannotBeInflatedByFirstReport() public {
        _deliver(_report(1));
        assertEq(oracle.snapshotBlock(), 0);
        assertTrue(oracle.oracleFrozen());
    }

    /// forge-config: default.isolate = true
    function test_ExactGrowthAndLossBoundariesAreAccepted() public {
        _fundPortfolio(1000);
        _advance();
        _deliver(_report(1100));
        vm.snapshotGasLastFrame("MerkleAdapterOracleGuard", "acceptReport");
        assertEq(oracle.totalAssets(), 1100);
        _next(990);
        assertEq(oracle.totalAssets(), 990);
        assertFalse(oracle.oracleFrozen());
    }

    function testFuzz_GrowthAndLossLimits(uint64 baseline, uint32 growth, uint32 loss, uint64 candidate) public {
        baseline = uint64(bound(baseline, 1, 1e12));
        growth = uint32(bound(growth, 0, ORACLE_LIMIT_PRECISION));
        loss = uint32(bound(loss, 0, ORACLE_LIMIT_PRECISION));
        candidate = uint64(bound(candidate, 0, uint256(baseline) * 3));
        _fundPortfolio(baseline);
        uint48 acceptedBlock = oracle.snapshotBlock();
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(growth, loss, 0);
        bool expected = candidate >= baseline
            ? uint256(candidate - baseline) * ORACLE_LIMIT_PRECISION <= uint256(baseline) * growth
            : uint256(baseline - candidate) * ORACLE_LIMIT_PRECISION <= uint256(baseline) * loss;
        _next(candidate);
        assertEq(oracle.oracleFrozen(), !expected);
        assertEq(oracle.snapshotBlock(), expected ? block.number - 1 : acceptedBlock);
        assertEq(oracle.totalAssets(), expected ? candidate : baseline);
    }

    function testFuzz_SubBasisPointLimitsAcceptOneUnitAndRejectTwo(bool growth) public {
        _fundPortfolio(ORACLE_LIMIT_PRECISION);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(1, 1, 0);
        uint256 accepted = growth ? ORACLE_LIMIT_PRECISION + 1 : ORACLE_LIMIT_PRECISION - 1;
        _next(accepted);
        assertEq(oracle.totalAssets(), accepted);
        assertFalse(oracle.oracleFrozen());
        uint48 acceptedBlock = oracle.snapshotBlock();
        _next(growth ? accepted + 2 : accepted - 2);
        assertEq(oracle.totalAssets(), accepted);
        assertEq(oracle.snapshotBlock(), acceptedBlock);
        assertTrue(oracle.oracleFrozen());
    }

    function test_MaximumLimitsAcceptDoublingAndTotalLoss() public {
        _fundPortfolio(1000);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(ORACLE_LIMIT_PRECISION, ORACLE_LIMIT_PRECISION, 0);
        _next(2000);
        assertEq(oracle.totalAssets(), 2000);
        _next(0);
        assertEq(oracle.totalAssets(), 0);
        assertFalse(oracle.oracleFrozen());
    }

    function test_FreezeLatchesAcrossGoodReportsAndLimitChanges() public {
        _fundPortfolio(1000);
        uint48 acceptedBlock = oracle.snapshotBlock();
        _next(899);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(ORACLE_LIMIT_PRECISION, ORACLE_LIMIT_PRECISION, 0);
        _next(1000);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.snapshotBlock(), acceptedBlock);
        oracle.unfreezeOracle(bytes(""));
        _next(1000);
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.snapshotBlock(), block.number - 1);
    }

    function testFuzz_ReportSequenceKeepsFreezeAndAcceptedState(uint32[16] memory changes, bool[16] memory clear)
        public
    {
        _fundPortfolio(1_000_000);
        for (uint256 i; i < changes.length; ++i) {
            if (clear[i]) oracle.unfreezeOracle(bytes(""));
            uint256 beforeBlock = oracle.snapshotBlock();
            uint256 beforeNAV = oracle.totalAssets();
            uint256 beforeSnapshot = oracle.snapshotTimestamp();
            uint256 candidate = beforeNAV * bound(changes[i], 0, 150_000_000) / ORACLE_LIMIT_PRECISION;
            uint256 difference = candidate > beforeNAV ? candidate - beforeNAV : beforeNAV - candidate;
            bool accepted = !oracle.oracleFrozen() && difference * 10 <= beforeNAV;
            uint256 candidateSnapshot = _next(candidate);
            assertEq(oracle.oracleFrozen(), !accepted);
            assertEq(oracle.snapshotBlock(), accepted ? block.number - 1 : beforeBlock);
            assertEq(oracle.totalAssets(), accepted ? candidate : beforeNAV);
            assertEq(oracle.snapshotTimestamp(), accepted ? candidateSnapshot : beforeSnapshot);
        }
    }

    function test_ZeroLimitsAcceptUnchangedNAVOnly() public {
        _fundPortfolio(1000);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(0, 0, 0);
        _next(1000);
        assertFalse(oracle.oracleFrozen());
        _next(999);
        assertTrue(oracle.oracleFrozen());
    }

    function test_AllocationAndWithdrawalAreNotPerformanceChanges() public {
        _fundPortfolio(1000);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(0, 0, 0);
        asset.transfer(adapter.vault(), 9000);
        delegator.allocate(address(adapter), 9000);
        delegator.requestDeallocate(address(adapter), 9000);
        _next(10_000);
        assertEq(adapter.totalAssets(), 10_000);
        assertEq(delegator.deallocate(address(adapter), 9000), 9000);
        _next(1000);
        assertEq(adapter.totalAssets(), 1000);
        assertFalse(oracle.oracleFrozen());
    }

    function test_ReportLimitsUseSnapshotFlowsNotFlowsAtDelivery() public {
        _fundPortfolio(1000);
        _advance();
        ICREOracle.Report memory update = _report(899);
        asset.transfer(adapter.vault(), 1_000_000);
        delegator.allocate(address(adapter), 1_000_000);
        _deliver(update);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 1_001_000);
    }

    function test_WithdrawalAfterSnapshotDoesNotShrinkThatReportsBaseline() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        _advance();
        ICREOracle.Report memory update = _report(900);
        assertEq(delegator.deallocate(address(adapter), 800), 800);
        _deliver(update);
        assertFalse(oracle.oracleFrozen());
        assertEq(adapter.totalAssets(), 100);
    }

    function test_ExpectedOutflowCannotHideAdditionalLoss() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        assertEq(delegator.deallocate(address(adapter), 800), 800);
        _next(179);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 200);
    }

    function test_ReviewCannotBypassOracleAuthentication() public {
        ICREOracle.Report memory update = _report(1000);
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(abi.encode(update));
        vm.expectRevert(ICREOracleBase.InvalidSender.selector);
        oracle.onReport(_metadata(), abi.encode(update));
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.snapshotBlock(), 0);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        vm.prank(address(adapter));
        vm.expectRevert(ICREOracleBase.InvalidSender.selector);
        oracle.onReport(_metadata(), abi.encode(update));
    }

    function test_WorkflowCutoverPreservesFlowAndLiquidityRequests() public {
        _fundPortfolio(1000);
        bytes32 nextWorkflow = keccak256("next NAV workflow");
        _proposeWorkflow(address(oracle), nextWorkflow);
        asset.transfer(adapter.vault(), 9000);
        delegator.allocate(address(adapter), 9000);
        delegator.requestDeallocate(address(adapter), 800);
        int256 flow = adapter.netFlow();
        uint48 acceptedBlock = oracle.snapshotBlock();
        _acceptWorkflow(address(oracle), nextWorkflow);
        assertEq(adapter.netFlow(), flow);
        assertEq(adapter.pendingDeallocation(), 800);
        assertEq(oracle.snapshotBlock(), acceptedBlock);
        assertEq(adapter.totalAssets(), 10_000);
        _advance();
        ICREOracle.Report memory update = _report(10_000);
        (bytes memory raw, bytes[] memory signatures) = _signedReport(update, nextWorkflow);
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertEq(oracle.snapshotBlock(), update.snapshotBlock);
        assertFalse(oracle.oracleFrozen());
        assertEq(delegator.deallocate(address(adapter), 800), 800);
        assertEq(adapter.totalAssets(), 9200);
        assertEq(adapter.pendingDeallocation(), 0);
    }

    function test_FrozenVaultFlowsRollbackButManagementAndDemandUpdatesRemainAvailable() public {
        _fundPortfolio(1000);
        oracle.freezeOracle();
        asset.transfer(adapter.vault(), 10);
        vm.expectRevert(ICREOracle.OracleFrozen.selector);
        delegator.allocate(address(adapter), 10);
        assertEq(adapter.netFlow(), 1000);
        assertEq(asset.balanceOf(adapter.vault()), 10);
        delegator.requestDeallocate(address(adapter), 10);
        assertEq(adapter.pendingDeallocation(), 10);
        vm.expectRevert(ICREOracle.OracleFrozen.selector);
        delegator.deallocate(address(adapter), 10);
        assertEq(adapter.pendingDeallocation(), 10);
        assertEq(adapter.netFlow(), 1000);
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
    }

    function test_RealForwarderDeliveryCanBeReviewedWithoutNewExecution() public {
        _fundPortfolio(1000);
        _advance();
        ICREOracle.Report memory update = _report(2000);
        (bytes memory raw, bytes[] memory signatures) = _signedReport(update, WORKFLOW, bytes32(uint256(100)));
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertTrue(forwarder.getTransmissionInfo(address(oracle), bytes32(uint256(100)), bytes2(0)).success);
        assertTrue(oracle.oracleFrozen());
        oracle.unfreezeOracle(abi.encode(update));
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        assertEq(oracle.snapshotBlock(), update.snapshotBlock);
        assertEq(adapter.totalAssets(), 2000);
    }

    function _advance() internal {
        _advanceReport();
    }

    function _next(uint256 assets) internal returns (uint256 candidateSnapshot) {
        _advance();
        ICREOracle.Report memory update = _report(assets);
        candidateSnapshot = update.snapshotTimestamp;
        _deliver(update);
    }
}
