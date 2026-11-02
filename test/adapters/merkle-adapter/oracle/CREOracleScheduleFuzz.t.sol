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

    function testFuzz_BootstrapDoesNotDependOnTimestamp(uint48 timestamp) public {
        vm.warp(timestamp);
        _deliver(_report(0));
        assertEq(_acceptedSnapshotBlock(), block.number - 2);
    }

    function testFuzz_AcceptanceRequiresOnlySnapshotBlockToAdvance(uint16 blocksElapsed, uint16 secondsElapsed) public {
        blocksElapsed = uint16(bound(blocksElapsed, 0, 100));
        secondsElapsed = uint16(bound(secondsElapsed, 0, 100));
        ICREOracle.Report memory first = _report(0);
        _deliver(first);
        uint48 acceptedBlock = _acceptedSnapshotBlock();
        vm.roll(block.number + blocksElapsed);
        vm.warp(block.timestamp + secondsElapsed);
        if (blocksElapsed == 0) {
            _expectReportError(first, ICREOracle.StaleReport.selector);
            assertEq(_acceptedSnapshotBlock(), acceptedBlock);
        } else {
            _deliver(_report(0));
            assertEq(_acceptedSnapshotBlock(), uint256(acceptedBlock) + blocksElapsed + 1);
        }
    }

    function test_DelayedDeliveryAllowsANewerCompletedSnapshotAtTheSameArrivalTime() public {
        ICREOracle.Report memory first = _report(0);
        vm.warp(block.timestamp + 365 days);
        _deliver(first);
        _deliver(_report(0));
        assertEq(_acceptedSnapshotBlock(), first.snapshotBlock + 1);
    }

    function test_ReportUsesFourWordsAndRejectsLegacyTimestampPayload() public {
        bytes memory payload = abi.encode(_report(0));
        assertEq(payload.length, 128);
        vm.prank(address(forwarder));
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.onReport(_metadata(), bytes.concat(payload, abi.encode(block.timestamp - 1)));
        _deliver(_report(0));
        assertEq(_acceptedSnapshotBlock(), block.number - 2);
    }

    function test_SnapshotAtUint48MaximumIsAccepted() public {
        vm.roll(uint256(type(uint48).max) + 1);
        _deliver(_report(0));
        assertEq(_acceptedSnapshotBlock(), type(uint48).max);
    }

    function testFuzz_ReportRejectsSnapshotBlockAboveUint48(uint208 highBits) public {
        ICREOracle.Report memory report = _report(0);
        uint256 oversized = (uint256(highBits) | 1) << 48;
        bytes memory payload =
            abi.encode(report.chainId, report.adapter, report.totalAssets, uint256(report.snapshotBlock) | oversized);
        vm.prank(address(forwarder));
        vm.expectRevert();
        oracle.onReport(_metadata(), payload);
        assertEq(_acceptedSnapshotBlock(), 0);
    }
}
