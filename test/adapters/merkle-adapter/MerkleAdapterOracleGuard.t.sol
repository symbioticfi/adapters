// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {Oracle} from "src/contracts/merkle-adapter/oracle/Oracle.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IOracle} from "src/interfaces/merkle-adapter/oracle/IOracle.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {OracleTestBase} from "test/adapters/merkle-adapter/oracle/Oracle.t.sol";

contract MerkleAdapterOracleGuardTest is OracleTestBase {
    /// forge-config: default.isolate = true
    function test_RejectsExcessGrowthWithoutReplacingAcceptedNAV() public {
        _fundPortfolio(1000);
        _next(1101);
        vm.snapshotGasLastCall("MerkleAdapterOracleGuard", "rejectReport");

        assertEq(oracle.totalAssets(), 1000, "bad NAV must not replace accepted NAV");
        assertEq(oracle.nonce(), 3, "bad report must not advance accounting");
        assertEq(oracle.snapshotBlock(), 501);
        assertEq(oracle.snapshotTimestamp(), 10_001);
        assertTrue(oracle.oracleFrozen());
        vm.expectRevert(IOracle.OracleFrozen.selector);
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
        MerkleAccount(payable(account)).grantRole(MerkleAccount(payable(account)).ORACLE_LIMITS_ROLE(), address(this));
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
        MerkleAccount(payable(account)).grantRole(MerkleAccount(payable(account)).ORACLE_LIMITS_ROLE(), address(this));
        oracle.setOracleLimits(10_000, 10_000);
        _next(1000);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 3);
        assertEq(oracle.snapshotTimestamp(), timestamp);

        oracle.unfreezeOracle(bytes32(0));
        _next(1000);
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 4);
    }

    function testFuzz_ReportSequenceKeepsFreezeAndAcceptedState(uint16[16] memory changes, bool[16] memory clear)
        public
    {
        _fundPortfolio(1_000_000);
        for (uint256 i; i < changes.length; ++i) {
            if (clear[i]) oracle.unfreezeOracle(bytes32(0));
            uint256 beforeNonce = oracle.nonce();
            uint256 beforeNAV = oracle.totalAssets();
            uint256 beforeSnapshot = oracle.snapshotTimestamp();
            uint256 candidate = beforeNAV * uint256(changes[i]) / 10_000;
            uint256 difference = candidate > beforeNAV ? candidate - beforeNAV : beforeNAV - candidate;
            bool accepted = !oracle.oracleFrozen() && difference * 10 <= beforeNAV;
            _next(candidate);
            assertEq(oracle.oracleFrozen(), !accepted);
            assertEq(oracle.nonce(), beforeNonce + (accepted ? 1 : 0));
            assertEq(oracle.totalAssets(), accepted ? candidate : beforeNAV);
            assertEq(oracle.snapshotTimestamp(), accepted ? block.timestamp - 1 : beforeSnapshot);
        }
    }

    function test_ZeroLimitsAcceptUnchangedNAVOnly() public {
        _fundPortfolio(1000);
        MerkleAccount(payable(account)).grantRole(MerkleAccount(payable(account)).ORACLE_LIMITS_ROLE(), address(this));
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
        _next(1000);
        assertEq(adapter.totalAssets(), 10_000);
        assertEq(delegator.deallocate(address(adapter), 9000), 9000);
        assertEq(adapter.totalAssets(), 1000);
        assertFalse(oracle.oracleFrozen());
    }

    function test_WorkflowCutoverPreservesQueuedAllocationAndWithdrawal() public {
        _fundPortfolio(1000);
        bytes32 nextWorkflow = keccak256("next NAV workflow");
        oracle.proposeWorkflow(nextWorkflow);
        asset.transfer(adapter.vault(), 9000);
        delegator.allocate(address(adapter), 9000);
        _next(1000);
        assertEq(oracle.workflowId(), WORKFLOW);
        assertEq(oracle.proposedWorkflowId(), nextWorkflow);
        assertEq(oracle.nonce(), 4);
        assertEq(adapter.pendingAllocation(4), 9000);
        assertEq(adapter.totalAssets(), 10_000);

        delegator.requestDeallocate(address(adapter), 800);
        assertEq(adapter.toDeallocate(5), 800);
        oracle.acceptWorkflow(nextWorkflow);
        assertEq(oracle.nonce(), 4);
        assertEq(oracle.totalAssets(), 1000);
        assertEq(adapter.pendingAllocation(4), 9000);
        assertEq(adapter.toDeallocate(5), 800);
        assertEq(adapter.totalAssets(), 10_000);

        _advance();
        IOracle.Report memory update = _report(10_000);
        (bytes memory raw, bytes[] memory signatures) = _signedReport(update, nextWorkflow);
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertEq(oracle.nonce(), 5);
        assertEq(oracle.totalAssets(), 10_000);
        assertEq(adapter.reservedAssets(), 0);
        assertEq(adapter.totalAssets(), 10_000);

        _advance();
        update = _report(9200);
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
        _next(99); // 800 reserved + 99 NAV means an actual 101 loss.
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
        IOracle.Report memory update = _report(0);
        _approveReport(update);
        _deliver(update);
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

    function test_ReviewApprovesExactAuthenticatedReportOnce() public {
        _fundPortfolio(1000);
        _advance();
        IOracle.Report memory update = _report(3000);
        _deliver(update);
        assertTrue(oracle.oracleFrozen());
        bytes32 reportHash = keccak256(abi.encode(update));
        oracle.unfreezeOracle(reportHash);
        assertEq(oracle.totalAssets(), 1000, "review cannot itself write NAV");
        _deliver(update);
        assertEq(oracle.totalAssets(), 3000);
        assertEq(oracle.approvedOracleReport(), bytes32(0));
        _next(4000);
        assertTrue(oracle.oracleFrozen());
    }

    function test_ReviewDoesNotAuthorizeModifiedReport() public {
        _fundPortfolio(1000);
        _advance();
        IOracle.Report memory update = _report(3000);
        _approveReport(update);
        update.totalAssets++;
        _deliver(update);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 1000);
    }

    function test_ReviewCannotBypassOracleAuthentication() public {
        IOracle.Report memory update = _report(1000);
        _approveReport(update);
        vm.expectRevert(IOracle.InvalidSender.selector);
        oracle.onReport(_metadata(), abi.encode(update));
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 0);
        assertEq(oracle.approvedOracleReport(), keccak256(abi.encode(update)));
        vm.prank(address(adapter));
        vm.expectRevert(IOracle.InvalidSender.selector);
        oracle.onReport(_metadata(), abi.encode(update));
        assertFalse(oracle.oracleFrozen());
    }

    /// forge-config: default.isolate = true
    function test_GuardLimitsAndAgeRolesAreIndependentAndEnumerable() public {
        address guard = makeAddr("guard");
        address limits = makeAddr("limits");
        address age = makeAddr("age");
        MerkleAccount(payable(account)).revokeRole(MerkleAccount(payable(account)).ORACLE_GUARD_ROLE(), address(this));
        MerkleAccount(payable(account)).grantRole(MerkleAccount(payable(account)).ORACLE_GUARD_ROLE(), guard);
        MerkleAccount(payable(account)).grantRole(MerkleAccount(payable(account)).ORACLE_LIMITS_ROLE(), limits);
        MerkleAccount(payable(account)).grantRole(MerkleAccount(payable(account)).ORACLE_AGE_ROLE(), age);
        assertEq(
            MerkleAccount(payable(account)).getRoleMemberCount(MerkleAccount(payable(account)).ORACLE_GUARD_ROLE()), 1
        );
        assertEq(
            MerkleAccount(payable(account)).getRoleMember(MerkleAccount(payable(account)).ORACLE_GUARD_ROLE(), 0), guard
        );

        vm.expectRevert(IOracle.InvalidCaller.selector);
        oracle.unfreezeOracle(bytes32(0));
        vm.prank(guard);
        oracle.freezeOracle();
        vm.snapshotGasLastCall("MerkleAdapterOracleGuard", "freezeOracle");
        assertTrue(oracle.oracleFrozen());
        vm.expectRevert(IOracle.InvalidCaller.selector);
        vm.prank(guard);
        oracle.setOracleLimits(100, 200);
        vm.prank(limits);
        oracle.setOracleLimits(100, 200);
        vm.snapshotGasLastCall("MerkleAdapterOracleGuard", "setOracleLimits");
        vm.prank(age);
        oracle.setMaxOracleAge(3 hours);
        vm.snapshotGasLastCall("MerkleAdapterOracleGuard", "setMaxOracleAge");
        assertTrue(oracle.oracleFrozen());
        vm.prank(guard);
        oracle.unfreezeOracle(bytes32(0));
        vm.snapshotGasLastCall("MerkleAdapterOracleGuard", "unfreezeOracle");
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.maxOracleGrowthBps(), 100);
        assertEq(oracle.maxOracleLossBps(), 200);
        assertEq(oracle.maxOracleAge(), 3 hours);
    }

    function test_RejectsInvalidLimitsWithoutChangingPolicy() public {
        MerkleAccount(payable(account)).grantRole(MerkleAccount(payable(account)).ORACLE_LIMITS_ROLE(), address(this));
        MerkleAccount(payable(account)).grantRole(MerkleAccount(payable(account)).ORACLE_AGE_ROLE(), address(this));
        vm.expectRevert(IOracle.InvalidOracleLimit.selector);
        oracle.setOracleLimits(10_001, 1000);
        vm.expectRevert(IOracle.InvalidOracleLimit.selector);
        oracle.setOracleLimits(1000, 10_001);
        vm.expectRevert(IOracle.InvalidOracleLimit.selector);
        oracle.setMaxOracleAge(0);
        assertEq(oracle.maxOracleGrowthBps(), 1000);
        assertEq(oracle.maxOracleLossBps(), 1000);
        assertEq(oracle.maxOracleAge(), 1 days);
    }

    function test_StaleNAVRevertsAtExactAgeBoundaryAndFreshReportRecovers() public {
        _fundPortfolio(1000);
        vm.warp(oracle.snapshotTimestamp() + 1 days);
        assertEq(adapter.totalAssets(), 1000);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(IOracle.OracleStale.selector);
        adapter.totalAssets();
        vm.expectRevert(IOracle.OracleStale.selector);
        adapter.allocatable();
        oracle.unfreezeOracle(bytes32(0));
        vm.expectRevert(IOracle.OracleStale.selector);
        adapter.totalAssets();
        _next(1000);
        assertEq(adapter.totalAssets(), 1000);
    }

    function test_ReviewedReportMustAlsoMeetCuratorAgeLimit() public {
        _fundPortfolio(1000);
        MerkleAccount(payable(account)).grantRole(MerkleAccount(payable(account)).ORACLE_AGE_ROLE(), address(this));
        oracle.setMaxOracleAge(2);
        vm.warp(block.timestamp + 10);
        vm.roll(block.number + 1);
        IOracle.Report memory update = _report(1000);
        update.snapshotTimestamp -= 2;
        _approveReport(update);
        _deliver(update);
        assertTrue(oracle.oracleFrozen());
    }

    function test_FreezeBlocksVaultFlowsButKeepsApprovedManagementAvailable() public {
        _fundPortfolio(1000);
        oracle.freezeOracle();
        asset.transfer(adapter.vault(), 10);
        vm.expectRevert(IOracle.OracleFrozen.selector);
        delegator.allocate(address(adapter), 10);
        vm.expectRevert(IOracle.OracleFrozen.selector);
        delegator.requestDeallocate(address(adapter), 10);
        vm.expectRevert(IOracle.OracleFrozen.selector);
        delegator.deallocate(address(adapter), 10);
        vm.expectRevert(IOracle.OracleFrozen.selector);
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

    function test_RealForwarderDeliveryPersistsFreezeAndRequiresNewExecutionForRecovery() public {
        _fundPortfolio(1000);
        _advance();
        IOracle.Report memory update = _report(2000);
        (bytes memory raw, bytes[] memory signatures) = _signedReport(update, WORKFLOW, bytes32(uint256(100)));
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertTrue(forwarder.getTransmissionInfo(address(oracle), bytes32(uint256(100)), bytes2(0)).success);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.nonce(), 3);
        vm.expectRevert(IOracle.OracleFrozen.selector);
        adapter.totalAssets();
        assertTrue(oracle.oracleFrozen());

        _approveReport(update);
        (raw, signatures) = _signedReport(update, WORKFLOW, bytes32(uint256(101)));
        forwarder.report(address(oracle), raw, bytes(""), signatures);
        assertEq(oracle.nonce(), 4);
        assertEq(adapter.totalAssets(), 2000);
    }

    function test_BootstrapCreatesAddressesBeforeWorkflowWithoutMigration() public {
        address bootstrapped = AdapterFactory(adapter.FACTORY())
            .create(
                1,
                address(this),
                abi.encode(
                    adapter.vault(), abi.encode(IMerkleAdapter.InitParams({defaultAdminRoleHolder: address(this)}))
                )
            );
        address receiver = MerkleAdapter(payable(bootstrapped)).oracle();
        assertEq(Oracle(receiver).FORWARDER(), address(forwarder));
        assertEq(Oracle(receiver).workflowId(), bytes32(0));
        assertEq(Oracle(receiver).version(), 1);
        vm.expectRevert(IOracle.InvalidWorkflow.selector);
        MerkleAdapter(payable(bootstrapped)).totalAssets();

        bytes32 workflow = keccak256(abi.encode("reviewed workflow for deployed adapter", bootstrapped));
        Oracle(receiver).proposeWorkflow(workflow);
        Oracle(receiver).acceptWorkflow(workflow);
        assertEq(MerkleAdapter(payable(bootstrapped)).oracle(), receiver);
        assertEq(Oracle(receiver).adapter(), bootstrapped);
        assertEq(Oracle(receiver).workflowId(), workflow);
        assertEq(Oracle(receiver).version(), 1);
        vm.expectRevert(IOracle.OracleStale.selector);
        MerkleAdapter(payable(bootstrapped)).totalAssets();

        IOracle.Report memory update = IOracle.Report({
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
        assertEq(Oracle(receiver).nonce(), 1);
        assertEq(MerkleAdapter(payable(bootstrapped)).totalAssets(), 0);
    }

    function test_RevokedAdapterRolesImmediatelyLoseOracleAuthority() public {
        address guard = makeAddr("guard");
        MerkleAccount(payable(account)).grantRole(MerkleAccount(payable(account)).ORACLE_GUARD_ROLE(), guard);
        vm.prank(guard);
        oracle.freezeOracle();
        MerkleAccount(payable(account)).revokeRole(MerkleAccount(payable(account)).ORACLE_GUARD_ROLE(), guard);
        vm.expectRevert(IOracle.InvalidCaller.selector);
        vm.prank(guard);
        oracle.unfreezeOracle(bytes32(0));
        assertTrue(oracle.oracleFrozen());
        oracle.unfreezeOracle(bytes32(0));
        assertFalse(oracle.oracleFrozen());
    }

    function _fundPortfolio(uint256 amount) internal {
        _deliver(_report(0));
        asset.transfer(adapter.vault(), amount);
        delegator.allocate(address(adapter), amount);
        _next(0);
        _next(amount);
        assertEq(oracle.nonce(), 3);
        assertEq(adapter.totalAssets(), amount);
    }

    function _advance() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
    }

    function _next(uint256 assets) internal {
        _advance();
        _deliver(_report(assets));
    }
}
