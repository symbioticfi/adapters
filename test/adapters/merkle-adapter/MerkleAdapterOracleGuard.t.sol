// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";
import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {
    ICREOracle,
    ORACLE_GUARD_ROLE,
    ORACLE_LIMITS_ROLE,
    ORACLE_LIMIT_PRECISION
} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";
import {CREOracleTestBase} from "test/adapters/merkle-adapter/oracle/CREOracle.t.sol";

contract MerkleAdapterOracleGuardTest is CREOracleTestBase {
    using stdStorage for StdStorage;

    function test_MulticallEnforcesEveryOracleRoleAndRollsBack() public {
        _fundPortfolio(1000);
        _advance();
        ICREOracle.Report memory update = _report(3000);
        _deliver(update);
        bytes memory payload = abi.encode(update);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.revokeRole(ORACLE_GUARD_ROLE, address(this));
        uint256 previousGrowth = oracle.maxOracleGrowth();
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(oracle.setOracleLimits, (12_300, 45_600, 0));
        calls[1] = abi.encodeCall(oracle.acceptReport, (payload));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), ORACLE_GUARD_ROLE
            )
        );
        oracle.multicall(calls);
        assertEq(oracle.maxOracleGrowth(), previousGrowth);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(oracle.rejectedReportHash(), keccak256(payload));
        oracle.grantRole(ORACLE_GUARD_ROLE, address(this));
        oracle.multicall(calls);
        assertEq(oracle.maxOracleGrowth(), 12_300);
        assertEq(oracle.maxOracleLoss(), 45_600);
        assertEq(adapter.totalAssets(), 3000);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
    }

    function test_SubUnitMovementAllowanceRoundsDown() public {
        _fundPortfolio(ORACLE_LIMIT_PRECISION - 1);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(1, 1, 0);
        _next(ORACLE_LIMIT_PRECISION);

        assertEq(adapter.totalAssets(), ORACLE_LIMIT_PRECISION - 1);
    }

    function test_ReviewAppliesExactAuthenticatedReportOnce() public {
        _fundPortfolio(1000);
        _advance();
        ICREOracle.Report memory update = _report(3000);
        _deliver(update);

        bytes memory payload = abi.encode(update);
        assertEq(oracle.rejectedReportHash(), keccak256(payload));
        vm.expectEmit(false, false, false, true, address(oracle));
        emit ICREOracle.AcceptReport(payload);
        oracle.acceptReport(payload);
        assertEq(adapter.totalAssets(), 3000);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.acceptReport(payload);
        _next(4000);

        assertEq(adapter.totalAssets(), 3000);
        assertNotEq(oracle.rejectedReportHash(), bytes32(0));
    }

    function test_ReviewDoesNotAuthorizeModifiedReport() public {
        _fundPortfolio(1000);
        _advance();
        ICREOracle.Report memory update = _report(3000);
        _deliver(update);
        bytes32 rejectedHash = oracle.rejectedReportHash();
        update.totalAssets++;
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.acceptReport(abi.encode(update));
        assertEq(oracle.rejectedReportHash(), rejectedHash);

        assertEq(adapter.totalAssets(), 1000);
    }

    /// forge-config: default.isolate = true
    function test_GuardAndLimitsRolesAreIndependentAndEnumerable() public {
        _fundPortfolio(1000);
        _advance();
        ICREOracle.Report memory update = _report(3000);
        _deliver(update);
        bytes memory payload = abi.encode(update);
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
        oracle.acceptReport(payload);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guard, ORACLE_LIMITS_ROLE)
        );
        vm.prank(guard);
        oracle.setOracleLimits(10_000, 20_000, 0);
        vm.prank(limits);
        oracle.setOracleLimits(10_000, 20_000, 0);
        vm.snapshotGasLastFrame("MerkleAdapterOracleGuard", "setOracleLimits");
        assertEq(adapter.totalAssets(), 1000);
        assertEq(oracle.rejectedReportHash(), keccak256(payload));
        vm.prank(guard);
        oracle.acceptReport(payload);
        vm.snapshotGasLastFrame("MerkleAdapterOracleGuard", "acceptReport");
        assertEq(adapter.totalAssets(), 3000);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        assertEq(oracle.maxOracleGrowth(), 10_000);
        assertEq(oracle.maxOracleLoss(), 20_000);
    }

    function test_RejectsInvalidLimitsWithoutChangingPolicy() public {
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        uint32[2] memory invalid = [uint32(ORACLE_LIMIT_PRECISION + 1), type(uint32).max];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(ICREOracle.InvalidOracleLimit.selector);
            oracle.setOracleLimits(invalid[i], uint32(ORACLE_LIMIT_PRECISION / 10), 0);
            vm.expectRevert(ICREOracle.InvalidOracleLimit.selector);
            oracle.setOracleLimits(uint32(ORACLE_LIMIT_PRECISION / 10), invalid[i], 0);
            assertEq(oracle.maxOracleGrowth(), ORACLE_LIMIT_PRECISION / 10);
            assertEq(oracle.maxOracleLoss(), ORACLE_LIMIT_PRECISION / 10);
        }
    }

    function testFuzz_RejectsInvalidUint32Limits(uint32 invalid, bool growth) public {
        invalid = uint32(bound(invalid, ORACLE_LIMIT_PRECISION + 1, type(uint32).max));
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        vm.expectRevert(ICREOracle.InvalidOracleLimit.selector);
        oracle.setOracleLimits(
            growth ? invalid : uint32(ORACLE_LIMIT_PRECISION / 10),
            growth ? uint32(ORACLE_LIMIT_PRECISION / 10) : invalid,
            0
        );
        assertEq(oracle.maxOracleGrowth(), ORACLE_LIMIT_PRECISION / 10);
        assertEq(oracle.maxOracleLoss(), ORACLE_LIMIT_PRECISION / 10);
    }

    function testFuzz_RejectsNonCanonicalMovementLimitEncoding(uint256 invalid, bool growth) public {
        invalid = bound(invalid, uint256(type(uint32).max) + 1, type(uint256).max);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(1, 2, 3);
        (bool success, bytes memory result) = address(oracle)
            .call(
                abi.encodeWithSelector(
                    ICREOracle.setOracleLimits.selector, growth ? invalid : 4, growth ? 5 : invalid, 6
                )
            );
        assertFalse(success);
        assertEq(result, bytes(""));
        assertEq(oracle.maxOracleGrowth(), 1);
        assertEq(oracle.maxOracleLoss(), 2);
        assertEq(oracle.oracleTolerance(), 3);
    }

    function testFuzz_PackedLimitsAndReportsRemainIndependent(uint32 growth, uint32 loss, uint128 tolerance) public {
        growth = uint32(bound(growth, 0, ORACLE_LIMIT_PRECISION));
        loss = uint32(bound(loss, 0, ORACLE_LIMIT_PRECISION));
        bytes32 slot = bytes32(
            stdstore.target(address(oracle)).sig(ICREOracle.maxOracleGrowth.selector).enable_packed_slots().find()
        );
        assertEq(
            bytes32(
                stdstore.target(address(oracle)).sig(ICREOracle.oracleTolerance.selector).enable_packed_slots().find()
            ),
            slot
        );
        assertEq(
            bytes32(
                stdstore.target(address(oracle)).sig(ICREOracle.maxOracleLoss.selector).enable_packed_slots().find()
            ),
            slot
        );
        assertNotEq(bytes32(stdstore.target(address(oracle)).sig(ICREOracle.rejectedReportHash.selector).find()), slot);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(growth, loss, tolerance);
        _assertPackedLimits(slot, growth, loss, tolerance);
        ICREOracle.Report memory update = _report(uint256(tolerance) + 1);
        _deliver(update);
        _assertPackedLimits(slot, growth, loss, tolerance);
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(update)));
        oracle.acceptReport(abi.encode(update));
        _assertPackedLimits(slot, growth, loss, tolerance);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        oracle.setOracleLimits(loss, growth, tolerance);
        _assertPackedLimits(slot, loss, growth, tolerance);
        oracle.setOracleLimits(0, uint32(ORACLE_LIMIT_PRECISION), 0);
        _assertPackedLimits(slot, 0, ORACLE_LIMIT_PRECISION, 0);
    }

    function testFuzz_AcceptedNAVRemainsAvailableAfterDelay(uint256 delay) public {
        _fundPortfolio(1000);
        _advance();
        _deliver(_report(1000));
        vm.warp(block.timestamp + bound(delay, 1, 365 days));
        _assertReportedAssets(1000);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(oracle.totalAssets(), 1000);
        assertEq(adapter.allocatable(), type(uint256).max);
        _advance();
        _deliver(_report(1000));
        assertEq(adapter.totalAssets(), 1000);
    }

    function test_DelayedReportCanBeDelivered() public {
        _fundPortfolio(1000);
        _advanceReport();
        ICREOracle.Report memory update = _report(1000);
        vm.warp(block.timestamp + 365 days);
        _deliver(update);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        assertEq(oracle.snapshotBlock(), update.snapshotBlock);
        assertEq(adapter.netFlow(), 1000);
        assertEq(adapter.totalAssets(), 1000);
    }

    function test_RevokedGuardCannotAcceptCachedReport() public {
        address guard = makeAddr("guard");
        oracle.grantRole(ORACLE_GUARD_ROLE, guard);
        ICREOracle.Report memory update = _report(1000);
        _deliver(update);
        bytes memory payload = abi.encode(update);
        oracle.revokeRole(ORACLE_GUARD_ROLE, guard);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guard, ORACLE_GUARD_ROLE)
        );
        vm.prank(guard);
        oracle.acceptReport(payload);
        assertEq(oracle.rejectedReportHash(), keccak256(payload));
        assertEq(oracle.snapshotBlock(), 0);
        oracle.acceptReport(payload);
        assertEq(adapter.totalAssets(), 1000);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
    }

    function _assertPackedLimits(bytes32 slot, uint256 growth, uint256 loss, uint128 tolerance) internal view {
        assertEq(oracle.maxOracleGrowth(), growth);
        assertEq(oracle.maxOracleLoss(), loss);
        assertEq(oracle.oracleTolerance(), tolerance);
        assertEq(oracle.adapter(), address(adapter));
        assertEq(uint256(vm.load(address(oracle), slot)), (uint256(tolerance) << 64) | (loss << 32) | growth);
    }

    function test_ReportRejectionEmitsOneEventAndReplacesCachedReport() public {
        for (uint256 assets = 1; assets <= 2; ++assets) {
            ICREOracle.Report memory update = _report(assets);
            vm.recordLogs();
            _deliver(update);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(logs.length, 1);
            assertEq(logs[0].emitter, address(oracle));
            assertEq(logs[0].topics.length, 1);
            assertEq(logs[0].topics[0], keccak256("OnReport((uint256,address,uint256,uint48),bool)"));
            assertEq(logs[0].data, abi.encode(update, true));
            assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(update)));
        }
    }

    function test_AcceptedReportEmitsOnReportWithIsRejectedFalse() public {
        _fundPortfolio(1000);
        _advance();
        ICREOracle.Report memory update = _report(1050);
        vm.expectEmit(false, false, false, true, address(oracle));
        emit ICREOracle.OnReport(update, false);
        _submitReport(update);
        assertEq(adapter.totalAssets(), 1050);
    }

    /// forge-config: default.isolate = true
    function test_RejectsExcessGrowthWithoutReplacingAcceptedValuation() public {
        _fundPortfolio(1000);
        uint48 acceptedBlock = oracle.snapshotBlock();
        _advance();
        _submitReport(_report(1101));
        vm.snapshotGasLastFrame("MerkleAdapterOracleGuard", "rejectReport");
        assertEq(adapter.totalAssets(), 1000);
        assertEq(oracle.snapshotBlock(), acceptedBlock);

        assertEq(adapter.totalAssets(), 1000);
    }

    function test_ZeroBaselineCannotBeInflatedByFirstReport() public {
        _deliver(_report(1));
        assertEq(oracle.snapshotBlock(), 0);

        assertEq(adapter.totalAssets(), 0);
    }

    /// forge-config: default.isolate = true
    function test_ExactGrowthAndLossBoundariesAreAccepted() public {
        _fundPortfolio(1000);
        _advance();
        _submitReport(_report(1100));
        vm.snapshotGasLastFrame("MerkleAdapterOracleGuard", "onReportAccepted");
        assertEq(adapter.totalAssets(), 1100);
        _next(990);
        assertEq(adapter.totalAssets(), 990);
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

        assertEq(oracle.snapshotBlock(), expected ? block.number - 1 : acceptedBlock);
        assertEq(adapter.totalAssets(), expected ? candidate : baseline);
    }

    function testFuzz_SubBasisPointLimitsAcceptOneUnitAndRejectTwo(bool growth) public {
        _fundPortfolio(ORACLE_LIMIT_PRECISION);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(1, 1, 0);
        uint256 accepted = growth ? ORACLE_LIMIT_PRECISION + 1 : ORACLE_LIMIT_PRECISION - 1;
        _next(accepted);
        assertEq(adapter.totalAssets(), accepted);

        uint48 acceptedBlock = oracle.snapshotBlock();
        _next(growth ? accepted + 2 : accepted - 2);
        assertEq(adapter.totalAssets(), accepted);
        assertEq(oracle.snapshotBlock(), acceptedBlock);
    }

    function test_MaximumLimitsAcceptDoublingAndTotalLoss() public {
        _fundPortfolio(1000);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(uint32(ORACLE_LIMIT_PRECISION), uint32(ORACLE_LIMIT_PRECISION), 0);
        _next(2000);
        assertEq(adapter.totalAssets(), 2000);
        _next(0);
        assertEq(adapter.totalAssets(), 0);
    }

    function testFuzz_ReportSequenceKeepsAcceptedAndRejectedState(uint32[16] memory changes) public {
        _fundPortfolio(1_000_000);
        for (uint256 i; i < changes.length; ++i) {
            uint256 beforeBlock = oracle.snapshotBlock();
            uint256 beforeNAV = adapter.totalAssets();
            bytes32 rejectedHash = oracle.rejectedReportHash();
            uint256 candidate = beforeNAV * bound(changes[i], 0, 150_000_000) / ORACLE_LIMIT_PRECISION;
            uint256 difference = candidate > beforeNAV ? candidate - beforeNAV : beforeNAV - candidate;
            bool accepted = difference * 10 <= beforeNAV;
            _advance();
            ICREOracle.Report memory update = _report(candidate);
            _deliver(update);
            assertEq(oracle.snapshotBlock(), accepted ? update.snapshotBlock : beforeBlock);
            assertEq(adapter.totalAssets(), accepted ? candidate : beforeNAV);
            assertEq(oracle.rejectedReportHash(), accepted ? rejectedHash : keccak256(abi.encode(update)));
        }
    }

    function test_ZeroLimitsAcceptUnchangedNAVOnly() public {
        _fundPortfolio(1000);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(0, 0, 0);
        _next(1000);

        _next(999);

        assertEq(adapter.totalAssets(), 1000);
        assertNotEq(oracle.rejectedReportHash(), bytes32(0));
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
    }

    function test_ReportLimitsUseSnapshotFlowsNotFlowsAtDelivery() public {
        _fundPortfolio(1000);
        _advance();
        ICREOracle.Report memory update = _report(899);
        asset.transfer(adapter.vault(), 1_000_000);
        delegator.allocate(address(adapter), 1_000_000);
        _deliver(update);

        assertEq(adapter.totalAssets(), 1_001_000);
    }

    function test_WithdrawalAfterSnapshotDoesNotShrinkThatReportsBaseline() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        _advance();
        ICREOracle.Report memory update = _report(900);
        assertEq(delegator.deallocate(address(adapter), 800), 800);
        _deliver(update);

        assertEq(adapter.totalAssets(), 100);
    }

    function test_ExpectedOutflowCannotHideAdditionalLoss() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        assertEq(delegator.deallocate(address(adapter), 800), 800);
        _next(179);

        assertEq(adapter.totalAssets(), 200);
    }

    function test_ReviewCannotBypassOracleAuthentication() public {
        ICREOracle.Report memory update = _report(1000);
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.acceptReport(abi.encode(update));
        vm.expectRevert(ICREOracle.InvalidSender.selector);
        oracle.onReport(_metadata(), abi.encode(update));

        assertEq(oracle.snapshotBlock(), 0);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        vm.prank(address(adapter));
        vm.expectRevert(ICREOracle.InvalidSender.selector);
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

        assertEq(delegator.deallocate(address(adapter), 800), 800);
        assertEq(adapter.totalAssets(), 9200);
        assertEq(adapter.pendingDeallocation(), 0);
    }

    function test_DelayedNAVAllowsVaultFlowsAndManagement() public {
        _fundPortfolio(1000);
        vm.warp(block.timestamp + 365 days);
        asset.transfer(adapter.vault(), 10);
        assertEq(delegator.allocate(address(adapter), 10), 10);
        assertEq(adapter.netFlow(), 1010);
        assertEq(asset.balanceOf(adapter.vault()), 0);
        delegator.requestDeallocate(address(adapter), 10);
        assertEq(adapter.pendingDeallocation(), 10);
        assertEq(delegator.deallocate(address(adapter), 10), 0);
        assertEq(adapter.pendingDeallocation(), 10);
        assertEq(adapter.netFlow(), 1010);
        assertEq(adapter.allocatable(), type(uint256).max);
        bytes memory data = abi.encodeCall(IERC20.approve, (address(123), 10));
        bytes memory mask = new bytes(data.length);
        bytes32 leaf = ActionMasker.mask(address(asset), 0, data, mask);
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

        oracle.acceptReport(abi.encode(update));
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
        candidateSnapshot = update.snapshotBlock;
        _deliver(update);
    }
}
