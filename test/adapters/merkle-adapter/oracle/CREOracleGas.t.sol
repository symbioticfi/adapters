// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {
    ICREOracle,
    ORACLE_LIMITS_ROLE,
    ORACLE_LIMIT_PRECISION
} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";

import {CREOracleTestBase} from "./CREOracle.t.sol";

contract CREOracleGasTest is CREOracleTestBase {
    /// forge-config: default.isolate = true
    function test_GasBootstrapReportAndReceiverInterfaces() public {
        ICREOracle.Report memory update = _report(0);
        _submitReport(update);
        vm.snapshotGasLastCall("CREOracle", "onReportBootstrap");
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(_acceptedSnapshotBlock(), update.snapshotBlock);

        bool supported = oracle.supportsInterface(ICREOracle.onReport.selector);
        vm.snapshotGasLastCall("CREOracle", "supportsInterfaceReceiver");
        assertTrue(supported);
        supported = oracle.supportsInterface(0xffffffff);
        vm.snapshotGasLastCall("CREOracle", "supportsInterfaceUnknown");
        assertFalse(supported);
    }

    /// forge-config: default.isolate = true
    function test_GasAcceptedRejectedAndReviewedReports() public {
        _fundPortfolio(1000);
        _advanceReport();
        _submitReport(_report(1050));
        vm.snapshotGasLastCall("CREOracle", "onReportGrowth");
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(adapter.totalAssets(), 1050);

        _advanceReport();
        _submitReport(_report(1000));
        vm.snapshotGasLastCall("CREOracle", "onReportLoss");
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(adapter.totalAssets(), 1000);

        _advanceReport();
        ICREOracle.Report memory update = _report(2000);
        _submitReport(update);
        vm.snapshotGasLastCall("CREOracle", "onReportRejectMovement");
        bytes32 rejected = keccak256(abi.encode(update));
        assertEq(oracle.rejectedReportHash(), rejected);
        assertEq(adapter.totalAssets(), 1000);

        _advanceReport();
        update = _report(1050);
        _submitReport(update);
        vm.snapshotGasLastCall("CREOracle", "onReportAcceptWithPending");
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(oracle.rejectedReportHash(), rejected);
        assertEq(adapter.totalAssets(), 1050);
        assertEq(_acceptedSnapshotBlock(), update.snapshotBlock);

        _advanceReport();
        update = _report(2200);
        _submitReport(update);
        vm.snapshotGasLastCall("CREOracle", "onReportReplaceRejected");
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(update)));
        assertEq(adapter.totalAssets(), 1050);

        oracle.acceptReport(abi.encode(update));
        vm.snapshotGasLastCall("CREOracle", "acceptReport");
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        assertEq(adapter.totalAssets(), 2200);
        assertEq(_acceptedSnapshotBlock(), update.snapshotBlock);
    }

    /// forge-config: default.isolate = true
    function test_GasLimits() public {
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(20_000, 30_000, 5);
        vm.snapshotGasLastCall("CREOracle", "setOracleLimits");
        assertEq(oracle.maxOracleGrowth(), 20_000);
        assertEq(oracle.maxOracleLoss(), 30_000);
        assertEq(oracle.oracleTolerance(), 5);
        vm.expectRevert(ICREOracle.InvalidOracleLimit.selector);
        vm.startSnapshotGas("CREOracle", "setOracleLimitsInvalidRegion");
        oracle.setOracleLimits(uint32(ORACLE_LIMIT_PRECISION + 1), 30_000, 5);
        vm.stopSnapshotGas();
        assertEq(oracle.maxOracleGrowth(), 20_000);
    }

    /// forge-config: default.isolate = true
    function test_GasStaleReportRejectionPreservesAcceptedSnapshot() public {
        ICREOracle.Report memory update = _report(0);
        _submitReport(update);
        bytes memory metadata = _metadata();
        bytes memory payload = abi.encode(update);
        vm.expectRevert(ICREOracle.StaleReport.selector);
        vm.prank(address(forwarder));
        vm.startSnapshotGas("CREOracle", "onReportStaleRegion");
        oracle.onReport(metadata, payload);
        vm.stopSnapshotGas();
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(_acceptedSnapshotBlock(), update.snapshotBlock);
    }
}
