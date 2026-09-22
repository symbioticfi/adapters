// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {CREOracle} from "src/contracts/merkle-adapter/oracle/CREOracle.sol";

import {CREOracleTestBase} from "test/adapters/merkle-adapter/oracle/CREOracle.t.sol";

contract CREOracleScheduleFuzzTest is CREOracleTestBase {
    function testFuzz_BootstrapSchedulesFirstFutureGridCutoff(
        uint48 interval,
        uint48 buffer,
        uint64 acceptanceTimestamp
    ) public {
        interval = uint48(bound(interval, 1, type(uint48).max));
        buffer = uint48(bound(buffer, 0, interval - 1));
        acceptanceTimestamp = uint64(bound(acceptanceTimestamp, 2, type(uint64).max));
        _setSchedule(interval, buffer);

        vm.warp(acceptanceTimestamp);
        _deliver(_report(0));

        assertEq(oracle.nonce(), 1);
        assertEq(oracle.snapshotTimestamp(), uint256(acceptanceTimestamp) - 1);
        _assertFutureGridCutoff(interval, buffer);
    }

    function testFuzz_AcceptanceExactlyOnGridSchedulesFullInterval(uint48 interval, uint48 buffer, uint32 gridIndex)
        public
    {
        interval = uint48(bound(interval, 1, type(uint48).max));
        buffer = uint48(bound(buffer, 0, interval - 1));
        _setSchedule(interval, buffer);
        uint256 acceptanceTimestamp = (uint256(gridIndex) + 2) * interval - buffer;
        vm.warp(acceptanceTimestamp);

        _deliver(_report(0));

        assertEq(oracle.nonce(), 1);
        assertEq(oracle.cutoff(), acceptanceTimestamp + interval);
        _assertFutureGridCutoff(interval, buffer);
    }

    function test_MaximumUint48ScheduleDoesNotTruncateCutoff() public {
        uint48 interval = type(uint48).max;
        uint48 buffer = interval - 1;
        _setSchedule(interval, buffer);
        vm.warp(interval);
        _deliver(_report(0));

        assertEq(oracle.cutoff(), uint256(interval) + 1);
        _assertFutureGridCutoff(interval, buffer);

        vm.roll(block.number + 1);
        vm.warp(uint256(interval) * 2 + 1);
        _deliver(_report(0));

        assertEq(oracle.nonce(), 2);
        assertEq(oracle.cutoff(), uint256(interval) * 3 + 1);
        _assertFutureGridCutoff(interval, buffer);
    }

    function test_OneSecondIntervalAcceptsZeroBuffer() public {
        _setSchedule(1, 0);
        _deliver(_report(0));

        assertEq(oracle.cutoff(), block.timestamp + 1);
        _assertFutureGridCutoff(1, 0);
    }

    function _setSchedule(uint48 interval, uint48 buffer) internal {
        factory.whitelist(
            address(
                new CREOracle(
                    address(factory),
                    address(workflowRegistry),
                    address(forwarder),
                    100,
                    oracle.MAX_ORACLE_AGE(),
                    interval,
                    buffer
                )
            )
        );
        factory.migrate(address(oracle), 2, bytes(""));
        assertEq(oracle.REPORT_INTERVAL(), interval);
        assertEq(oracle.REPORT_BUFFER(), buffer);
        assertEq(oracle.cutoff(), 0);
        assertEq(oracle.nonce(), 0);
    }

    function _assertFutureGridCutoff(uint48 interval, uint48 buffer) internal view {
        uint256 nextCutoff = oracle.cutoff();
        assertGt(nextCutoff, block.timestamp);
        assertLe(nextCutoff, block.timestamp + interval);
        assertEq((nextCutoff + buffer) % interval, 0);
    }
}
