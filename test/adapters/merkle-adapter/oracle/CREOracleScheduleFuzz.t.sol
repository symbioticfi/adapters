// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {CREOracle} from "src/contracts/merkle-adapter/oracle/CREOracle.sol";
import {CREOracleTestBase} from "./CREOracle.t.sol";

contract CREOracleScheduleFuzzTest is CREOracleTestBase {
    function testFuzz_BootstrapAcceptsAnyFreshSnapshotWithoutAdjustingItsTime(uint48 interval, uint48 timestamp)
        public
    {
        interval = uint48(bound(interval, 1, type(uint48).max));
        timestamp = uint48(bound(timestamp, 2, type(uint48).max));
        _setSchedule(interval);
        vm.warp(timestamp);
        _deliver(_report(0));
        assertEq(oracle.snapshotTimestamp(), uint256(timestamp) - 1);
        assertEq(oracle.snapshotBlock(), block.number - 1);
    }

    function testFuzz_OnlyOneAcceptedSnapshotPerAlignedInterval(uint32 interval, uint32 slot) public {
        interval = uint32(bound(interval, 3, type(uint32).max));
        slot = uint32(bound(slot, 0, type(uint48).max / interval - 3));
        _setSchedule(interval);
        uint256 start = (uint256(slot) + 1) * interval;
        vm.warp(start + 1);
        _deliver(_report(0));
        vm.roll(block.number + 1);
        vm.warp(start + 2);
        _expectReportError(_report(0), ICREOracle.StaleReport.selector);
        vm.warp(start + interval + 1);
        _deliver(_report(0));
        assertEq(oracle.snapshotTimestamp(), start + interval);
    }

    function test_DelayedDeliveryDoesNotConsumeTheArrivalInterval() public {
        vm.warp(10_100);
        ICREOracle.Report memory first = _report(0); // Snapshot 10_099 belongs to slot 100.
        vm.warp(10_199);
        _deliver(first); // Arrival belongs to slot 101.
        vm.roll(block.number + 1);
        ICREOracle.Report memory next = _report(0); // Snapshot 10_198 still belongs to slot 101.
        _deliver(next);
        assertEq(oracle.snapshotTimestamp(), 10_198);
    }

    function test_OneSecondIntervalAcceptsEveryNewSecond() public {
        _setSchedule(1);
        _deliver(_report(0));
        _advanceReport();
        _deliver(_report(0));
        assertEq(oracle.snapshotTimestamp(), block.timestamp - 1);
    }

    function test_SnapshotAtUint48MaximumDoesNotNeedAFutureCutoff() public {
        _setSchedule(type(uint48).max);
        vm.warp(uint256(type(uint48).max) + 1);
        _deliver(_report(0));
        assertEq(oracle.snapshotTimestamp(), type(uint48).max);
    }

    function testFuzz_ReportRejectsSnapshotWordsAboveUint48(bool timestamp, uint208 highBits) public {
        ICREOracle.Report memory report = _report(0);
        uint256 oversized = (uint256(highBits) | 1) << 48;
        bytes memory payload = abi.encode(
            report.chainId,
            report.adapter,
            report.totalAssets,
            uint256(report.snapshotBlock) | (timestamp ? 0 : oversized),
            uint256(report.snapshotTimestamp) | (timestamp ? oversized : 0)
        );
        vm.prank(address(forwarder));
        vm.expectRevert();
        oracle.onReport(_metadata(), payload);
        assertEq(oracle.snapshotBlock(), 0);
        assertFalse(oracle.oracleFrozen());
    }

    function _setSchedule(uint48 interval) internal {
        factory.whitelist(address(new CREOracle(address(factory), address(workflowRegistry), 100, 1 days, interval)));
        factory.migrate(address(oracle), 2, "");
        assertEq(oracle.REPORT_INTERVAL(), interval);
    }
}
