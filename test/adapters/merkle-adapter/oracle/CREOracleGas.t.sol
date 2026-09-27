// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {
    ICREOracleBase,
    ORACLE_LIMITS_ROLE,
    ORACLE_LIMIT_PRECISION
} from "src/interfaces/merkle-adapter/oracle/ICREOracleBase.sol";

import {CREOracleTestBase} from "./CREOracle.t.sol";

/// @dev Reverting calls use region snapshots because Foundry does not retain a reverted last-call frame.
contract CREOracleGasTest is CREOracleTestBase {
    /// forge-config: default.isolate = true
    function test_GasBootstrapReportAndReceiverInterfaces() public {
        _deliver(_report(0));
        vm.snapshotGasLastCall("CREOracle", "onReportBootstrap");
        assertEq(oracle.snapshotBlock(), block.number - 1);
        assertFalse(oracle.oracleFrozen());

        bool supported = oracle.supportsInterface(ICREOracleBase.onReport.selector);
        vm.snapshotGasLastCall("CREOracle", "supportsInterfaceReceiver");
        assertTrue(supported);
        supported = oracle.supportsInterface(0xffffffff);
        vm.snapshotGasLastCall("CREOracle", "supportsInterfaceUnknown");
        assertFalse(supported);
    }

    /// forge-config: default.isolate = true
    function test_GasAcceptedRejectedFrozenAndReviewedReports() public {
        _fundPortfolio(1000);
        _advanceReport();
        _deliver(_report(1050));
        vm.snapshotGasLastCall("CREOracle", "onReportGrowth");
        assertEq(oracle.totalAssets(), 1050);
        assertFalse(oracle.oracleFrozen());

        _advanceReport();
        _deliver(_report(1000));
        vm.snapshotGasLastCall("CREOracle", "onReportLoss");
        assertEq(oracle.totalAssets(), 1000);
        assertFalse(oracle.oracleFrozen());

        _advanceReport();
        ICREOracle.Report memory update = _report(2000);
        _deliver(update);
        vm.snapshotGasLastCall("CREOracle", "onReportRejectMovement");
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(update)));
        assertEq(oracle.totalAssets(), 1000);

        _advanceReport();
        update = _report(1050);
        _deliver(update);
        vm.snapshotGasLastCall("CREOracle", "onReportWhileFrozen");
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(update)));
        assertEq(oracle.totalAssets(), 1000);

        oracle.unfreezeOracle(abi.encode(update));
        vm.snapshotGasLastCall("CREOracle", "unfreezeOracleReviewed");
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        assertEq(oracle.totalAssets(), 1050);
        assertEq(oracle.snapshotBlock(), update.snapshotBlock);
    }

    /// forge-config: default.isolate = true
    function test_GasFreshFrozenAndStaleValuation() public {
        _fundPortfolio(1000);
        uint256 assets = oracle.totalAssets();
        vm.snapshotGasLastCall("CREOracle", "totalAssets");
        assertEq(assets, 1000);
        assets = oracle.validate();
        vm.snapshotGasLastCall("CREOracle", "validateFresh");
        assertEq(assets, 1000);

        oracle.freezeOracle();
        vm.snapshotGasLastCall("CREOracle", "freezeOracle");
        assertTrue(oracle.oracleFrozen());
        vm.expectRevert(ICREOracle.OracleFrozen.selector);
        vm.startSnapshotGas("CREOracle", "validateFrozenRegion");
        oracle.validate();
        vm.stopSnapshotGas();

        oracle.unfreezeOracle("");
        vm.snapshotGasLastCall("CREOracle", "unfreezeOracleEmpty");
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 1000);
        vm.warp(uint256(oracle.snapshotTimestamp()) + oracle.MAX_ORACLE_AGE() + 1);
        vm.expectRevert(ICREOracle.OracleStale.selector);
        vm.startSnapshotGas("CREOracle", "validateStaleRegion");
        oracle.validate();
        vm.stopSnapshotGas();
    }

    /// forge-config: default.isolate = true
    function test_GasLimitsAndWorkflowChanges() public {
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(20_000, 30_000, 5);
        vm.snapshotGasLastCall("CREOracle", "setOracleLimits");
        assertEq(oracle.maxOracleGrowth(), 20_000);
        assertEq(oracle.maxOracleLoss(), 30_000);
        assertEq(oracle.oracleTolerance(), 5);
        vm.expectRevert(ICREOracleBase.InvalidOracleLimit.selector);
        vm.startSnapshotGas("CREOracle", "setOracleLimitsInvalidRegion");
        oracle.setOracleLimits(ORACLE_LIMIT_PRECISION + 1, 30_000, 5);
        vm.stopSnapshotGas();
        assertEq(oracle.maxOracleGrowth(), 20_000);

        _deliver(_report(1000));
        assertTrue(oracle.oracleFrozen());
        assertNotEq(oracle.rejectedReportHash(), bytes32(0));
        bytes32 replacement = keccak256("gas replacement workflow");
        vm.prank(address(workflowRegistry));
        oracle.setWorkflowId(replacement);
        vm.snapshotGasLastCall("CREOracle", "setWorkflowId");
        assertEq(oracle.workflowId(), replacement);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        assertTrue(oracle.oracleFrozen());
    }

    /// forge-config: default.isolate = true
    function test_GasStaleReportRejectionPreservesAcceptedSnapshot() public {
        ICREOracle.Report memory update = _report(0);
        _deliver(update);
        bytes memory metadata = _metadata();
        bytes memory payload = abi.encode(update);
        vm.expectRevert(ICREOracle.StaleReport.selector);
        vm.prank(address(forwarder));
        vm.startSnapshotGas("CREOracle", "onReportStaleRegion");
        oracle.onReport(metadata, payload);
        vm.stopSnapshotGas();
        assertEq(oracle.snapshotBlock(), update.snapshotBlock);
        assertFalse(oracle.oracleFrozen());
    }
}
