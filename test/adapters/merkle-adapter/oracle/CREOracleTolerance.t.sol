// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {CREOracle} from "src/contracts/merkle-adapter/oracle/CREOracle.sol";
import {
    ICREOracle,
    ORACLE_LIMITS_ROLE,
    ORACLE_LIMIT_PRECISION
} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";

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
        ICREOracle.Report memory update = _report(observed);
        _deliver(update);
        assertEq(oracle.rejectedReportHash(), accepted ? bytes32(0) : keccak256(abi.encode(update)));
        assertEq(adapter.totalAssets(), accepted ? observed : baseline);
    }

    function test_PercentageProductAcceptsLargestNonOverflowingBaseline() public {
        _deliverWithReview(_report(type(uint256).max / ORACLE_LIMIT_PRECISION));
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(uint32(ORACLE_LIMIT_PRECISION), uint32(ORACLE_LIMIT_PRECISION), 0);
        _advanceReport();
        _deliver(_report(0));
        assertEq(adapter.totalAssets(), 0);
    }

    function test_PercentageProductOverflowRevertsWithoutChangingOracleState() public {
        uint256 baseline = type(uint256).max / ORACLE_LIMIT_PRECISION + 1;
        _deliverWithReview(_report(baseline));
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(uint32(ORACLE_LIMIT_PRECISION), uint32(ORACLE_LIMIT_PRECISION), 0);
        _advanceReport();
        bytes memory metadata = _metadata();
        bytes memory report = abi.encode(_report(0));
        vm.prank(address(forwarder));
        vm.expectRevert(stdError.arithmeticError);
        oracle.onReport(metadata, report);
        assertEq(adapter.totalAssets(), baseline);
        assertEq(oracle.snapshotBlock(), 499);
        assertEq(oracle.rejectedReportHash(), bytes32(0));

        // A zero change meets the tolerance before the overflowing percentage product is evaluated.
        _deliver(_report(baseline));
        assertEq(oracle.snapshotBlock(), 500);
    }

    function testFuzz_ZeroBaselineAcceptsDustUpToTolerance(uint128 tolerance) public {
        tolerance = uint128(bound(tolerance, 1, type(uint128).max));
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(0, 0, tolerance);
        _deliver(_report(tolerance));
        assertEq(adapter.totalAssets(), tolerance);
        assertEq(oracle.snapshotBlock(), 499);

        _advanceReport();
        ICREOracle.Report memory update = _report(uint256(tolerance) * 2 + 1);
        _deliver(update);
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(update)));
        assertEq(adapter.totalAssets(), tolerance);
        assertEq(oracle.snapshotBlock(), 499);
    }

    function testFuzz_ToleranceAppliesToLossAsWellAsGrowth(uint128 tolerance, bool loss) public {
        tolerance = uint128(bound(tolerance, 1, type(uint128).max));
        uint256 baseline = uint256(tolerance) * 3 + 10;
        _deliverWithReview(_report(baseline));
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(0, 0, tolerance);
        _advanceReport();
        uint256 accepted = loss ? baseline - tolerance : baseline + tolerance;
        _deliver(_report(accepted));
        assertEq(adapter.totalAssets(), accepted);

        _advanceReport();
        ICREOracle.Report memory update = _report(loss ? accepted - tolerance - 1 : accepted + tolerance + 1);
        _deliver(update);
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(update)));
        assertEq(adapter.totalAssets(), accepted);
        assertEq(oracle.snapshotBlock(), 500);
    }

    function test_PercentageAllowanceAndToleranceAreNotAdded() public {
        _deliverWithReview(_report(10_000));
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(1_000_000, 1_000_000, 50); // 1% = 100, larger than the tolerance.
        _advanceReport();
        ICREOracle.Report memory rejected = _report(10_101);
        _deliver(rejected);
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(rejected)));
        assertEq(adapter.totalAssets(), 10_000);

        _deliver(_report(10_100));
        assertEq(adapter.totalAssets(), 10_100);
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(rejected)));
    }

    function test_TinyBaselineUsesExactRatioRatherThanRoundedPercentage() public {
        _deliverWithReview(_report(3));
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(33_333_333, 0, 0);
        _advanceReport();
        ICREOracle.Report memory update = _report(4);
        _deliver(update); // 1/3 is strictly greater than 0.33333333.
        assertEq(oracle.rejectedReportHash(), keccak256(abi.encode(update)));
        assertEq(adapter.totalAssets(), 3);
        oracle.setOracleLimits(33_333_334, 0, 0);
        _deliverWithReview(update);
        assertEq(adapter.totalAssets(), 4);
        assertEq(oracle.snapshotBlock(), update.snapshotBlock);
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
        vm.expectRevert(ICREOracle.InvalidAssets.selector);
        _deliver(update);
        assertEq(oracle.rejectedReportHash(), bytes32(0));
        assertEq(adapter.totalAssets(), 800);
        _assertReportedAssets(1000);
        assertEq(adapter.releasedLiquidity(), 800);
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        oracle.acceptReport(abi.encode(update));
    }

    function testFuzz_InitializationAndSetterPreserveTolerance(uint128 tolerance) public {
        ICREOracle.InitParams memory params = defaultOracleInitParams(address(this));
        params.oracleTolerance = tolerance;
        CREOracle receiver =
            CREOracle(factory.create(1, address(this), abi.encode(address(adapter), abi.encode(params))));
        assertEq(receiver.oracleTolerance(), tolerance);
        receiver.grantRole(ORACLE_LIMITS_ROLE, address(this));
        receiver.setOracleLimits(0, 0, tolerance / 2);
        assertEq(receiver.oracleTolerance(), uint256(tolerance) / 2);
    }

    function testFuzz_RejectsNonCanonicalToleranceEncodingAtomically(uint256 tolerance) public {
        tolerance = bound(tolerance, uint256(type(uint128).max) + 1, type(uint256).max);
        oracle.grantRole(ORACLE_LIMITS_ROLE, address(this));
        oracle.setOracleLimits(1, 2, 3);
        (bool success, bytes memory result) =
            address(oracle).call(abi.encodeWithSelector(ICREOracle.setOracleLimits.selector, 4, 5, tolerance));
        assertFalse(success);
        assertEq(result, bytes(""));
        assertEq(oracle.maxOracleGrowth(), 1);
        assertEq(oracle.maxOracleLoss(), 2);
        assertEq(oracle.oracleTolerance(), 3);

        ICREOracle.InitParams memory params = defaultOracleInitParams(address(this));
        bytes memory data = abi.encode(
            address(adapter),
            abi.encode(
                params.defaultAdminRoleHolder,
                params.oracleGuardRoleHolder,
                params.oracleLimitsRoleHolder,
                params.maxOracleGrowth,
                params.maxOracleLoss,
                tolerance
            )
        );
        uint256 count = factory.totalEntities();
        vm.expectRevert(bytes(""));
        factory.create(1, address(this), data);
        assertEq(factory.totalEntities(), count);
    }
}
