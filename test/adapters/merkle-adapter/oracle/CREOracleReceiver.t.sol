// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {CREOracle} from "src/contracts/merkle-adapter/oracle/CREOracle.sol";

import {
    ICREOracle,
    ORACLE_LIMITS_ROLE,
    ORACLE_LIMIT_PRECISION
} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {ICREWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

import {IReceiver} from "test/mocks/chainlink-cre/interfaces/IReceiver.sol";
import {KeystoneForwarder} from "test/mocks/chainlink-cre/KeystoneForwarder.sol";

/// @title CREOracleReceiverTest
/// @notice Tests CREOracle receiver authentication, limits and initialization.
contract CREOracleReceiverTest is Test {
    bytes32 constant WORKFLOW = keccak256("approved receiver workflow");
    bytes32 constant NEXT_WORKFLOW = keccak256("next approved receiver workflow");
    bytes constant PAYLOAD = hex"c0ffee";
    address constant WORKFLOW_REGISTRY = address(0xCA11);
    address constant ADMIN = address(0xAD01);
    address constant LIMITS_MANAGER = address(0xAD02);
    address constant ADAPTER = address(0xADA7);

    address internal _forwarder;
    address internal _receiver;
    address internal _factory;

    function setUp() public {
        vm.warp(10_000);
        vm.roll(500);
        _forwarder = address(new KeystoneForwarder());
        address[] memory signers = new address[](4);
        for (uint256 i; i < 4; ++i) {
            signers[i] = vm.addr(i + 1);
        }
        KeystoneForwarder(_forwarder).setConfig(1, 1, 1, signers);
        _factory = address(new MigratablesFactory(address(this)));
        MigratablesFactory(_factory).whitelist(address(new CREOracle(_factory, WORKFLOW_REGISTRY, _forwarder)));
        _receiver = MigratablesFactory(_factory)
            .create(
                1,
                address(this),
                abi.encode(
                    ADAPTER,
                    abi.encode(
                        ICREOracle.InitParams({
                            defaultAdminRoleHolder: ADMIN,
                            oracleGuardRoleHolder: address(0),
                            oracleLimitsRoleHolder: LIMITS_MANAGER,
                            maxOracleGrowth: 1_000_000,
                            maxOracleLoss: 2_000_000,
                            oracleTolerance: 3
                        })
                    )
                )
            );
        vm.etch(WORKFLOW_REGISTRY, hex"00");
        _mockWorkflow(bytes32(0));
        vm.etch(ADAPTER, hex"00");
        vm.mockCall(ADAPTER, abi.encodeCall(IMerkleAdapter.netFlow, ()), abi.encode(int256(0)));
        vm.mockCall(ADAPTER, abi.encodeWithSelector(IMerkleAdapter.netFlowAt.selector), abi.encode(int256(0)));
    }

    function test_ExposesPinnedForwarderWithoutAnAcceptedWorkflow() public view {
        assertEq(CREOracle(_receiver).forwarder(), _forwarder);
        assertEq(ICREWorkflowRegistry(WORKFLOW_REGISTRY).workflowId(_receiver), bytes32(0));
        assertEq(CREOracle(_receiver).snapshotBlock(), 0);
    }

    function test_SupportsReceiverERC165AndEnumerableAccessControlInterfaces() public view {
        assertTrue(CREOracle(_receiver).supportsInterface(type(IReceiver).interfaceId));
        assertTrue(CREOracle(_receiver).supportsInterface(type(IERC165).interfaceId));
        assertTrue(CREOracle(_receiver).supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(CREOracle(_receiver).supportsInterface(type(IAccessControlEnumerable).interfaceId));
        assertFalse(CREOracle(_receiver).supportsInterface(0xffffffff));
    }

    function test_InitializesLimitsAndIndependentRoleHolders() public view {
        assertEq(ORACLE_LIMIT_PRECISION, 1e8);
        assertEq(CREOracle(_receiver).maxOracleGrowth(), 1_000_000);
        assertEq(CREOracle(_receiver).maxOracleLoss(), 2_000_000);
        assertEq(CREOracle(_receiver).oracleTolerance(), 3);
        assertEq(CREOracle(_receiver).getRoleMemberCount(CREOracle(_receiver).DEFAULT_ADMIN_ROLE()), 1);
        assertEq(CREOracle(_receiver).getRoleMember(CREOracle(_receiver).DEFAULT_ADMIN_ROLE(), 0), ADMIN);
        assertEq(CREOracle(_receiver).getRoleMemberCount(ORACLE_LIMITS_ROLE), 1);
        assertEq(CREOracle(_receiver).getRoleMember(ORACLE_LIMITS_ROLE, 0), LIMITS_MANAGER);
        assertFalse(CREOracle(_receiver).hasRole(ORACLE_LIMITS_ROLE, address(this)));
        assertFalse(CREOracle(_receiver).hasRole(ORACLE_LIMITS_ROLE, ADMIN));
    }

    function test_InitializesZeroLimitsWithoutGrantingRolesToZero() public {
        ICREOracle.InitParams memory params;
        address ungoverned =
            MigratablesFactory(_factory).create(1, address(this), abi.encode(ADAPTER, abi.encode(params)));
        assertEq(CREOracle(ungoverned).getRoleMemberCount(CREOracle(ungoverned).DEFAULT_ADMIN_ROLE()), 0);
        assertEq(CREOracle(ungoverned).getRoleMemberCount(ORACLE_LIMITS_ROLE), 0);
        assertFalse(CREOracle(ungoverned).hasRole(CREOracle(ungoverned).DEFAULT_ADMIN_ROLE(), address(0)));
        assertFalse(CREOracle(ungoverned).hasRole(ORACLE_LIMITS_ROLE, address(0)));
        assertEq(CREOracle(ungoverned).maxOracleGrowth(), 0);
        assertEq(CREOracle(ungoverned).maxOracleLoss(), 0);
        assertEq(CREOracle(ungoverned).oracleTolerance(), 0);
    }

    function test_OnlyLimitsRoleCanSetLimitsAndAdminCanGrantIt() public {
        bytes32 role = ORACLE_LIMITS_ROLE;
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), role)
        );
        CREOracle(_receiver).setOracleLimits(4_000_000, 5_000_000, 6);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ADMIN, role));
        CREOracle(_receiver).setOracleLimits(4_000_000, 5_000_000, 6);

        vm.prank(LIMITS_MANAGER);
        vm.expectEmit(_receiver);
        emit ICREOracle.SetOracleLimits(4_000_000, 5_000_000, 6);
        CREOracle(_receiver).setOracleLimits(4_000_000, 5_000_000, 6);
        assertEq(CREOracle(_receiver).maxOracleGrowth(), 4_000_000);
        assertEq(CREOracle(_receiver).maxOracleLoss(), 5_000_000);
        assertEq(CREOracle(_receiver).oracleTolerance(), 6);

        vm.prank(ADMIN);
        CREOracle(_receiver).grantRole(role, address(this));
        CREOracle(_receiver).setOracleLimits(0, 1e8, type(uint128).max);
        assertEq(CREOracle(_receiver).maxOracleGrowth(), 0);
        assertEq(CREOracle(_receiver).maxOracleLoss(), 1e8);
        assertEq(CREOracle(_receiver).oracleTolerance(), type(uint128).max);
    }

    function test_InvalidLimitUpdatesLeaveAllLimitsUnchanged() public {
        vm.startPrank(LIMITS_MANAGER);
        vm.expectRevert(ICREOracle.InvalidOracleLimit.selector);
        CREOracle(_receiver).setOracleLimits(1e8 + 1, 0, 0);
        vm.expectRevert(ICREOracle.InvalidOracleLimit.selector);
        CREOracle(_receiver).setOracleLimits(0, 1e8 + 1, 0);
        uint256 overflowTolerance = uint256(type(uint128).max) + 1;
        (bool success, bytes memory result) =
            _receiver.call(abi.encodeWithSelector(ICREOracle.setOracleLimits.selector, 0, 0, overflowTolerance));
        assertFalse(success);
        assertEq(result, bytes(""));
        vm.stopPrank();
        assertEq(CREOracle(_receiver).maxOracleGrowth(), 1_000_000);
        assertEq(CREOracle(_receiver).maxOracleLoss(), 2_000_000);
        assertEq(CREOracle(_receiver).oracleTolerance(), 3);
    }

    function test_ReadsTheAcceptedWorkflowForThisOracle() public {
        _mockWorkflow(WORKFLOW);
        vm.expectCall(WORKFLOW_REGISTRY, abi.encodeCall(ICREWorkflowRegistry.workflowId, (_receiver)), uint64(1));
        vm.prank(_forwarder);
        CREOracle(_receiver).onReport(_metadata(WORKFLOW), _reportPayload(3));
        _assertReportedAssets(3);
    }

    function test_RejectsDeliveryBeforeWorkflowAcceptance() public {
        vm.prank(_forwarder);
        vm.expectRevert(ICREOracle.InvalidWorkflow.selector);
        CREOracle(_receiver).onReport(_metadata(WORKFLOW), PAYLOAD);
        assertEq(CREOracle(_receiver).snapshotBlock(), 0);
    }

    function test_RejectsCallersOtherThanTheForwarder() public {
        _mockWorkflow(WORKFLOW);
        bytes memory metadata = _metadata(WORKFLOW);
        vm.expectRevert(ICREOracle.InvalidSender.selector);
        CREOracle(_receiver).onReport(metadata, PAYLOAD);
        vm.prank(WORKFLOW_REGISTRY);
        vm.expectRevert(ICREOracle.InvalidSender.selector);
        CREOracle(_receiver).onReport(metadata, PAYLOAD);
        assertEq(CREOracle(_receiver).snapshotBlock(), 0);
    }

    function test_RejectsMismatchedWorkflowId() public {
        _mockWorkflow(WORKFLOW);
        vm.prank(_forwarder);
        vm.expectRevert(ICREOracle.InvalidWorkflow.selector);
        CREOracle(_receiver).onReport(_metadata(NEXT_WORKFLOW), PAYLOAD);
        assertEq(CREOracle(_receiver).snapshotBlock(), 0);
    }

    function test_RejectsInvalidMetadataBeforeReadingRegistry() public {
        bytes memory failure = abi.encode("registry unavailable");
        vm.mockCallRevert(WORKFLOW_REGISTRY, abi.encodeCall(ICREWorkflowRegistry.workflowId, (_receiver)), failure);
        bytes[] memory metadata = new bytes[](4);
        metadata[0] = abi.encodePacked(WORKFLOW, bytes10("custom"), WORKFLOW_REGISTRY);
        metadata[1] = bytes.concat(_metadata(WORKFLOW), hex"00");
        metadata[2] = abi.encodePacked(WORKFLOW, bytes10("custom"), address(0xbeef), bytes2(0));
        metadata[3] = _metadata(bytes32(0));
        for (uint256 i; i < metadata.length; ++i) {
            vm.prank(_forwarder);
            vm.expectRevert(ICREOracle.InvalidWorkflow.selector);
            CREOracle(_receiver).onReport(metadata[i], PAYLOAD);
        }
        vm.prank(_forwarder);
        vm.expectRevert(failure);
        CREOracle(_receiver).onReport(_metadata(WORKFLOW), PAYLOAD);
        assertEq(CREOracle(_receiver).snapshotBlock(), 0);
    }

    function test_ForwarderDeliveryForTheAcceptedWorkflowAppliesNAV() public {
        _mockWorkflow(WORKFLOW);
        bytes memory payload = _reportPayload(3);
        vm.prank(_forwarder);
        CREOracle(_receiver).onReport(_metadata(WORKFLOW), payload);
        assertEq(CREOracle(_receiver).snapshotBlock(), 499);
        assertEq(CREOracle(_receiver).snapshotTimestamp(), 9999);
        _assertReportedAssets(3);

        vm.prank(_forwarder);
        vm.expectRevert(ICREOracle.InvalidReport.selector);
        CREOracle(_receiver).onReport(_metadata(WORKFLOW), "");
        assertEq(CREOracle(_receiver).snapshotBlock(), 499);
        _assertReportedAssets(3);
    }

    function test_KeystoneForwarderDeliversSignedNAVReports() public {
        _mockWorkflow(WORKFLOW);
        (bytes memory raw, bytes[] memory signatures) = _signedReport(WORKFLOW, _reportPayload(3));
        KeystoneForwarder(_forwarder).report(_receiver, raw, bytes(""), signatures);
        assertEq(CREOracle(_receiver).snapshotBlock(), 499);
        _assertReportedAssets(3);
    }

    function test_WorkflowReplacementSwitchesAcceptedDeliveries() public {
        _mockWorkflow(WORKFLOW);
        _mockWorkflow(NEXT_WORKFLOW);
        vm.prank(_forwarder);
        vm.expectRevert(ICREOracle.InvalidWorkflow.selector);
        CREOracle(_receiver).onReport(_metadata(WORKFLOW), PAYLOAD);
        bytes memory payload = _reportPayload(3);
        vm.prank(_forwarder);
        CREOracle(_receiver).onReport(_metadata(NEXT_WORKFLOW), payload);
        assertEq(CREOracle(_receiver).snapshotBlock(), 499);
        _assertReportedAssets(3);
    }

    function _assertReportedAssets(uint256 expectedAssets) internal view {
        (uint48 reportBlock, uint256 reportedAssets) = CREOracle(_receiver).latestSnapshot();
        assertEq(reportBlock, CREOracle(_receiver).snapshotBlock());
        assertEq(reportedAssets, expectedAssets);
    }

    function _mockWorkflow(bytes32 workflow) internal {
        vm.mockCall(
            WORKFLOW_REGISTRY, abi.encodeCall(ICREWorkflowRegistry.workflowId, (_receiver)), abi.encode(workflow)
        );
    }

    function _reportPayload(uint256 assets) internal view returns (bytes memory) {
        return abi.encode(
            ICREOracle.Report({
                chainId: block.chainid,
                adapter: ADAPTER,
                totalAssets: assets,
                snapshotBlock: SafeCast.toUint48(vm.getBlockNumber() - 1),
                snapshotTimestamp: SafeCast.toUint48(vm.getBlockTimestamp() - 1)
            })
        );
    }

    function _metadata(bytes32 workflow) internal pure returns (bytes memory) {
        return abi.encodePacked(workflow, bytes10("custom"), WORKFLOW_REGISTRY, bytes2(0));
    }

    function _signedReport(bytes32 workflow, bytes memory payload)
        internal
        returns (bytes memory raw, bytes[] memory signatures)
    {
        raw = abi.encodePacked(
            uint8(1),
            keccak256(payload),
            uint32(vm.getBlockTimestamp()),
            uint32(1),
            uint32(1),
            workflow,
            bytes10("custom"),
            WORKFLOW_REGISTRY,
            bytes2(0),
            payload
        );
        bytes32 digest = keccak256(abi.encodePacked(keccak256(raw)));
        signatures = new bytes[](2);
        for (uint256 i; i < 2; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(i + 1, digest);
            signatures[i] = abi.encodePacked(r, s, uint8(v - 27));
        }
    }
}
