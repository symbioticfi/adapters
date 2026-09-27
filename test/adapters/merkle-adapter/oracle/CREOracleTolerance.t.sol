// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {CREOracle} from "src/contracts/merkle-adapter/oracle/CREOracle.sol";
import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ORACLE_LIMITS_ROLE, ORACLE_LIMIT_PRECISION} from "src/interfaces/merkle-adapter/oracle/ICREOracleBase.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {CREOracleTestBase} from "test/adapters/merkle-adapter/oracle/CREOracle.t.sol";
import {defaultOracleInitParams} from "test/helpers/MerkleInitialization.sol";
import {stdError} from "forge-std/StdError.sol";

contract CREOracleToleranceTest is CREOracleTestBase {
    function testFuzz_ReportsMatchExactDirectionalRatios(
        uint128 baseline,
        uint128 change,
        uint32 growth,
        uint32 loss,
        uint128 tolerance,
        bool decrease
    ) public {
        growth = uint32(bound(growth, 0, ORACLE_LIMIT_PRECISION));
        loss = uint32(bound(loss, 0, ORACLE_LIMIT_PRECISION));
        _deliverWithReview(_report(baseline));
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(growth, loss, tolerance);
        _advanceReport();

        uint256 delta = decrease && change > baseline ? baseline : change;
        uint256 observed = decrease ? uint256(baseline) - delta : uint256(baseline) + delta;
        bool accepted =
            delta <= tolerance || delta * ORACLE_LIMIT_PRECISION <= uint256(baseline) * (decrease ? loss : growth);
        _deliver(_report(observed));
        assertEq(oracle.oracleFrozen(), !accepted);
        assertEq(oracle.totalAssets(), accepted ? observed : baseline);
    }

    function test_PercentageProductAcceptsLargestNonOverflowingBaseline() public {
        _deliverWithReview(_report(type(uint256).max / ORACLE_LIMIT_PRECISION));
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(ORACLE_LIMIT_PRECISION, ORACLE_LIMIT_PRECISION, 0);
        _advanceReport();
        _deliver(_report(0));
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 0);
    }

    function test_PercentageProductOverflowRevertsWithoutChangingOracleState() public {
        uint256 baseline = type(uint256).max / ORACLE_LIMIT_PRECISION + 1;
        _deliverWithReview(_report(baseline));
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(ORACLE_LIMIT_PRECISION, ORACLE_LIMIT_PRECISION, 0);
        _advanceReport();
        bytes memory metadata = _metadata();
        bytes memory report = abi.encode(_report(0));
        vm.prank(address(forwarder));
        vm.expectRevert(stdError.arithmeticError);
        oracle.onReport(metadata, report);
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), baseline);
        assertEq(oracle.snapshotBlock(), 499);
        assertEq(oracle.rejectedReportHash(), bytes32(0));

        // A zero change meets the tolerance before the overflowing percentage product is evaluated.
        _deliver(_report(baseline));
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.snapshotBlock(), 500);
    }

    function testFuzz_ZeroBaselineAcceptsDustUpToTolerance(uint64 tolerance) public {
        tolerance = uint64(bound(tolerance, 1, type(uint64).max));
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(0, 0, tolerance);
        _deliver(_report(tolerance));
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), tolerance);
        assertEq(oracle.snapshotBlock(), 499);

        _advanceReport();
        _deliver(_report(uint256(tolerance) * 2 + 1));
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), tolerance);
        assertEq(oracle.snapshotBlock(), 499);
    }

    function testFuzz_ToleranceAppliesToLossAsWellAsGrowth(uint64 tolerance, bool loss) public {
        tolerance = uint64(bound(tolerance, 1, type(uint64).max));
        uint256 baseline = uint256(tolerance) * 3 + 10;
        _deliverWithReview(_report(baseline));
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(0, 0, tolerance);
        _advanceReport();
        uint256 accepted = loss ? baseline - tolerance : baseline + tolerance;
        _deliver(_report(accepted));
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), accepted);

        _advanceReport();
        _deliver(_report(loss ? accepted - tolerance - 1 : accepted + tolerance + 1));
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), accepted);
        assertEq(oracle.snapshotBlock(), 500);
    }

    function test_PercentageAllowanceAndToleranceAreNotAdded() public {
        _deliverWithReview(_report(10_000));
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(1_000_000, 1_000_000, 50); // 1% = 100, larger than the tolerance.
        _advanceReport();
        _deliver(_report(10_101));
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 10_000);

        oracle.unfreezeOracle("");
        _deliver(_report(10_100));
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 10_100);
    }

    function test_TinyBaselineUsesExactRatioRatherThanRoundedPercentage() public {
        _deliverWithReview(_report(3));
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(33_333_333, 0, 0);
        _advanceReport();
        _deliver(_report(4)); // 1/3 is strictly greater than 0.33333333.
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 3);
        oracle.setOracleLimits(33_333_334, 0, 0);
        oracle.unfreezeOracle("");
        _deliver(_report(4));
        assertFalse(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 4);
    }

    function test_DustToleranceCannotClearManualFreeze() public {
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(0, 0, 100);
        oracle.freezeOracle();
        ICREOracle.Report memory update = _report(1);
        _deliver(update);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 0);
        assertEq(oracle.snapshotBlock(), 0);
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(update)));
    }

    function test_ToleranceDoesNotBypassNegativeReconciledAssets() public {
        _fundPortfolio(1000);
        _releasePortfolio(1000);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(0, 0, 1000);
        _advanceReport();
        ICREOracle.Report memory update = _report(100);
        assertEq(delegator.deallocate(address(adapter), 200), 200);
        _deliver(update);
        assertTrue(oracle.oracleFrozen());
        assertEq(oracle.totalAssets(), 800);
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.unfreezeOracle(abi.encode(update));
    }

    function testFuzz_InitializationAndSetterPreserveTolerance(uint128 tolerance) public {
        ICREOracle.InitParams memory params = defaultOracleInitParams(address(this), address(forwarder));
        params.oracleTolerance = tolerance;
        CREOracle receiver =
            CREOracle(factory.create(1, address(this), abi.encode(address(adapter), abi.encode(params))));
        assertEq(receiver.oracleTolerance(), tolerance);
        receiver.grantRole(ORACLE_LIMITS_ROLE, address(this));
        receiver.setOracleLimits(0, 0, uint256(tolerance) / 2);
        assertEq(receiver.oracleTolerance(), uint256(tolerance) / 2);
    }

    function testFuzz_RejectsToleranceOverflowAtomically(uint256 tolerance) public {
        tolerance = bound(tolerance, uint256(type(uint128).max) + 1, type(uint256).max);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(1, 2, 3);
        bytes memory expected = abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, tolerance);
        vm.expectRevert(expected);
        oracle.setOracleLimits(4, 5, tolerance);
        assertEq(oracle.maxOracleGrowth(), 1);
        assertEq(oracle.maxOracleLoss(), 2);
        assertEq(oracle.oracleTolerance(), 3);

        ICREOracle.InitParams memory params = defaultOracleInitParams(address(this), address(forwarder));
        params.oracleTolerance = tolerance;
        bytes memory data = abi.encode(address(adapter), abi.encode(params));
        vm.expectRevert(expected);
        factory.create(1, address(this), data);
    }
}
