// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {CREOracleBase} from "src/contracts/merkle-adapter/oracle/CREOracleBase.sol";

import {
    ICREOracleBase,
    ORACLE_LIMITS_ROLE,
    ORACLE_LIMIT_PRECISION
} from "src/interfaces/merkle-adapter/oracle/ICREOracleBase.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Test} from "forge-std/Test.sol";

import {IReceiver} from "test/mocks/chainlink-cre/interfaces/IReceiver.sol";
import {KeystoneForwarder} from "test/mocks/chainlink-cre/KeystoneForwarder.sol";

/// @dev Custom CRE receiver without an onchain workflow registry: its owner picks the workflow directly.
contract CREOracleReceiverMock is OwnableUpgradeable, CREOracleBase {
    bytes public lastReport;
    uint256 public reports;

    constructor(address newOwner, ReceiverParams memory params) initializer {
        __Ownable_init(newOwner);
        forwarder = params.forwarder;
        if (params.defaultAdminRoleHolder != address(0)) _grantRole(DEFAULT_ADMIN_ROLE, params.defaultAdminRoleHolder);
        if (params.oracleLimitsRoleHolder != address(0)) _grantRole(ORACLE_LIMITS_ROLE, params.oracleLimitsRoleHolder);
        _setOracleLimits(params.maxOracleGrowth, params.maxOracleLoss, params.oracleTolerance);
    }

    function setWorkflowId(bytes32 newWorkflowId) external onlyOwner {
        workflowId = newWorkflowId;
        emit SetWorkflowId(newWorkflowId);
    }

    function _onReport(bytes calldata, bytes calldata report) internal override {
        lastReport = report;
        ++reports;
    }
}

contract CREOracleBaseTest is Test {
    bytes32 constant WORKFLOW = keccak256("approved custom workflow");
    bytes32 constant NEXT_WORKFLOW = keccak256("next approved custom workflow");
    bytes constant PAYLOAD = hex"c0ffee";
    address constant WORKFLOW_OWNER = address(0xCA11);
    address constant ADMIN = address(0xAD01);
    address constant LIMITS_MANAGER = address(0xAD02);

    KeystoneForwarder internal forwarder;
    CREOracleReceiverMock internal receiver;

    function setUp() public {
        vm.warp(10_000);
        forwarder = new KeystoneForwarder();
        address[] memory signers = new address[](4);
        for (uint256 i; i < 4; ++i) {
            signers[i] = vm.addr(i + 1);
        }
        forwarder.setConfig(1, 1, 1, signers);
        receiver = new CREOracleReceiverMock(
            address(this),
            ICREOracleBase.ReceiverParams({
                forwarder: address(forwarder),
                defaultAdminRoleHolder: ADMIN,
                oracleLimitsRoleHolder: LIMITS_MANAGER,
                maxOracleGrowth: 1_000_000,
                maxOracleLoss: 2_000_000,
                oracleTolerance: 3
            })
        );
    }

    function test_ExposesPinnedForwarderWithoutAnAcceptedWorkflow() public view {
        assertEq(receiver.forwarder(), address(forwarder));
        assertEq(receiver.workflowId(), bytes32(0));
        assertEq(receiver.reports(), 0);
    }

    function test_SupportsReceiverERC165AndEnumerableAccessControlInterfaces() public view {
        assertTrue(receiver.supportsInterface(type(IReceiver).interfaceId));
        assertTrue(receiver.supportsInterface(type(IERC165).interfaceId));
        assertTrue(receiver.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(receiver.supportsInterface(type(IAccessControlEnumerable).interfaceId));
        assertFalse(receiver.supportsInterface(0xffffffff));
    }

    function test_InitializesLimitsAndIndependentRoleHolders() public view {
        assertEq(ORACLE_LIMIT_PRECISION, 1e8);
        assertEq(receiver.maxOracleGrowth(), 1_000_000);
        assertEq(receiver.maxOracleLoss(), 2_000_000);
        assertEq(receiver.oracleTolerance(), 3);
        assertEq(receiver.getRoleMemberCount(receiver.DEFAULT_ADMIN_ROLE()), 1);
        assertEq(receiver.getRoleMember(receiver.DEFAULT_ADMIN_ROLE(), 0), ADMIN);
        assertEq(receiver.getRoleMemberCount(ORACLE_LIMITS_ROLE), 1);
        assertEq(receiver.getRoleMember(ORACLE_LIMITS_ROLE, 0), LIMITS_MANAGER);
        assertFalse(receiver.hasRole(ORACLE_LIMITS_ROLE, address(this)));
        assertFalse(receiver.hasRole(ORACLE_LIMITS_ROLE, ADMIN));
    }

    function test_InitializesZeroLimitsWithoutGrantingRolesToZero() public {
        ICREOracleBase.ReceiverParams memory params;
        params.forwarder = address(forwarder);
        CREOracleReceiverMock ungoverned = new CREOracleReceiverMock(address(this), params);
        assertEq(ungoverned.getRoleMemberCount(ungoverned.DEFAULT_ADMIN_ROLE()), 0);
        assertEq(ungoverned.getRoleMemberCount(ORACLE_LIMITS_ROLE), 0);
        assertFalse(ungoverned.hasRole(ungoverned.DEFAULT_ADMIN_ROLE(), address(0)));
        assertFalse(ungoverned.hasRole(ORACLE_LIMITS_ROLE, address(0)));
        assertEq(ungoverned.maxOracleGrowth(), 0);
        assertEq(ungoverned.maxOracleLoss(), 0);
        assertEq(ungoverned.oracleTolerance(), 0);
    }

    function test_OnlyLimitsRoleCanSetLimitsAndAdminCanGrantIt() public {
        bytes32 role = ORACLE_LIMITS_ROLE;
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), role)
        );
        receiver.setOracleLimits(4_000_000, 5_000_000, 6);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ADMIN, role));
        receiver.setOracleLimits(4_000_000, 5_000_000, 6);

        vm.prank(LIMITS_MANAGER);
        vm.expectEmit(address(receiver));
        emit ICREOracleBase.SetOracleLimits(4_000_000, 5_000_000, 6);
        receiver.setOracleLimits(4_000_000, 5_000_000, 6);
        assertEq(receiver.maxOracleGrowth(), 4_000_000);
        assertEq(receiver.maxOracleLoss(), 5_000_000);
        assertEq(receiver.oracleTolerance(), 6);

        vm.prank(ADMIN);
        receiver.grantRole(role, address(this));
        receiver.setOracleLimits(0, 1e8, type(uint128).max);
        assertEq(receiver.maxOracleGrowth(), 0);
        assertEq(receiver.maxOracleLoss(), 1e8);
        assertEq(receiver.oracleTolerance(), type(uint128).max);
    }

    function test_InvalidLimitUpdatesLeaveAllLimitsUnchanged() public {
        vm.startPrank(LIMITS_MANAGER);
        vm.expectRevert(ICREOracleBase.InvalidOracleLimit.selector);
        receiver.setOracleLimits(1e8 + 1, 0, 0);
        vm.expectRevert(ICREOracleBase.InvalidOracleLimit.selector);
        receiver.setOracleLimits(0, 1e8 + 1, 0);
        uint256 overflowTolerance = uint256(type(uint128).max) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(128), overflowTolerance)
        );
        receiver.setOracleLimits(0, 0, overflowTolerance);
        vm.stopPrank();
        assertEq(receiver.maxOracleGrowth(), 1_000_000);
        assertEq(receiver.maxOracleLoss(), 2_000_000);
        assertEq(receiver.oracleTolerance(), 3);
    }

    function test_ImplementationChoosesWorkflowGovernanceWithoutARegistry() public {
        vm.prank(address(forwarder));
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(forwarder))
        );
        receiver.setWorkflowId(WORKFLOW);
        vm.expectEmit(address(receiver));
        emit ICREOracleBase.SetWorkflowId(WORKFLOW);
        receiver.setWorkflowId(WORKFLOW);
        assertEq(receiver.workflowId(), WORKFLOW);
    }

    function test_RejectsDeliveryBeforeWorkflowAcceptance() public {
        vm.prank(address(forwarder));
        vm.expectRevert(ICREOracleBase.InvalidWorkflow.selector);
        receiver.onReport(_metadata(WORKFLOW), PAYLOAD);
        assertEq(receiver.reports(), 0);
    }

    function test_RejectsCallersOtherThanTheForwarder() public {
        receiver.setWorkflowId(WORKFLOW);
        bytes memory metadata = _metadata(WORKFLOW);
        vm.expectRevert(ICREOracleBase.InvalidSender.selector);
        receiver.onReport(metadata, PAYLOAD);
        vm.prank(WORKFLOW_OWNER);
        vm.expectRevert(ICREOracleBase.InvalidSender.selector);
        receiver.onReport(metadata, PAYLOAD);
        assertEq(receiver.reports(), 0);
    }

    function test_RejectsMismatchedWorkflowIdAndMalformedMetadata() public {
        receiver.setWorkflowId(WORKFLOW);
        vm.prank(address(forwarder));
        vm.expectRevert(ICREOracleBase.InvalidWorkflow.selector);
        receiver.onReport(_metadata(NEXT_WORKFLOW), PAYLOAD);
        vm.prank(address(forwarder));
        vm.expectRevert(ICREOracleBase.InvalidWorkflow.selector);
        receiver.onReport(abi.encodePacked(WORKFLOW, bytes10("custom"), WORKFLOW_OWNER), PAYLOAD);
        vm.prank(address(forwarder));
        vm.expectRevert(ICREOracleBase.InvalidWorkflow.selector);
        receiver.onReport(bytes.concat(_metadata(WORKFLOW), hex"00"), PAYLOAD);
        assertEq(receiver.reports(), 0);
    }

    function test_ForwarderDeliveryForTheAcceptedWorkflowReachesTheCustomHandler() public {
        receiver.setWorkflowId(WORKFLOW);
        vm.prank(address(forwarder));
        receiver.onReport(_metadata(WORKFLOW), PAYLOAD);
        assertEq(receiver.reports(), 1);
        assertEq(receiver.lastReport(), PAYLOAD);

        vm.prank(address(forwarder));
        receiver.onReport(_metadata(WORKFLOW), "");
        assertEq(receiver.reports(), 2);
        assertEq(receiver.lastReport(), "");
    }

    function test_KeystoneForwarderDeliversSignedReportsToTheCustomHandler() public {
        receiver.setWorkflowId(WORKFLOW);
        (bytes memory raw, bytes[] memory signatures) = _signedReport(WORKFLOW, PAYLOAD);
        forwarder.report(address(receiver), raw, bytes(""), signatures);
        assertEq(receiver.reports(), 1);
        assertEq(receiver.lastReport(), PAYLOAD);
    }

    function test_WorkflowReplacementSwitchesAcceptedDeliveries() public {
        receiver.setWorkflowId(WORKFLOW);
        receiver.setWorkflowId(NEXT_WORKFLOW);
        vm.prank(address(forwarder));
        vm.expectRevert(ICREOracleBase.InvalidWorkflow.selector);
        receiver.onReport(_metadata(WORKFLOW), PAYLOAD);
        vm.prank(address(forwarder));
        receiver.onReport(_metadata(NEXT_WORKFLOW), PAYLOAD);
        assertEq(receiver.reports(), 1);
    }

    function _metadata(bytes32 workflow) internal pure returns (bytes memory) {
        return abi.encodePacked(workflow, bytes10("custom"), WORKFLOW_OWNER, bytes2(0));
    }

    function _signedReport(bytes32 workflow, bytes memory payload)
        internal
        returns (bytes memory raw, bytes[] memory signatures)
    {
        raw = abi.encodePacked(
            uint8(1),
            keccak256(payload),
            uint32(block.timestamp),
            uint32(1),
            uint32(1),
            workflow,
            bytes10("custom"),
            WORKFLOW_OWNER,
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
