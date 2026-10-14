// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {CREOracleTestBase} from "./CREOracle.t.sol";

contract CREOracleScheduleFuzzTest is CREOracleTestBase {
    function test_UnsetSnapshotReturnsZero() public {
        (uint48 snapshotBlock, uint256 assets) = oracle.latestSnapshot();
        assertEq(snapshotBlock, 0);
        assertEq(assets, 0);
        assertEq(adapter.totalAssets(), 0);
    }

    function testFuzz_BootstrapAcceptsAnyCompletedSnapshotWithoutAdjustingItsTime(uint48 timestamp) public {
        timestamp = uint48(bound(timestamp, 2, type(uint48).max));
        vm.warp(timestamp);
        _deliver(_report(0));
        assertEq(oracle.snapshotTimestamp(), uint256(timestamp) - 1);
        assertEq(oracle.snapshotBlock(), block.number - 1);
    }

    function testFuzz_AcceptanceRequiresBothSnapshotDimensionsToAdvance(uint16 blocksElapsed, uint16 secondsElapsed)
        public
    {
        blocksElapsed = uint16(bound(blocksElapsed, 0, 100));
        secondsElapsed = uint16(bound(secondsElapsed, 0, 100));
        _deliver(_report(0));
        uint48 acceptedBlock = oracle.snapshotBlock();
        uint48 acceptedTimestamp = oracle.snapshotTimestamp();
        vm.roll(block.number + blocksElapsed);
        vm.warp(block.timestamp + secondsElapsed);
        if (blocksElapsed == 0 || secondsElapsed == 0) {
            _expectReportError(_report(0), ICREOracle.StaleReport.selector);
            assertEq(oracle.snapshotBlock(), acceptedBlock);
            assertEq(oracle.snapshotTimestamp(), acceptedTimestamp);
        } else {
            _deliver(_report(0));
            assertEq(oracle.snapshotBlock(), uint256(acceptedBlock) + blocksElapsed);
            assertEq(oracle.snapshotTimestamp(), uint256(acceptedTimestamp) + secondsElapsed);
        }
    }

    function test_DelayedDeliveryAllowsANewerCompletedSnapshotAtTheSameArrivalTime() public {
        vm.warp(10_100);
        ICREOracle.Report memory first = _report(0);
        vm.warp(10_199);
        _deliver(first);
        vm.roll(block.number + 1);
        ICREOracle.Report memory next = _report(0);
        _deliver(next);
        assertEq(oracle.snapshotTimestamp(), 10_198);
    }

    function test_EveryNewSnapshotSecondCanBeAccepted() public {
        _deliver(_report(0));
        for (uint256 i; i < 3; ++i) {
            _advanceReport();
            _deliver(_report(0));
        }
        assertEq(oracle.snapshotTimestamp(), block.timestamp - 1);
    }

    function test_SnapshotAtUint48MaximumDoesNotNeedAFutureCutoff() public {
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
    }
}
