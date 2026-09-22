// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {CREOracle} from "src/contracts/merkle-adapter/oracle/CREOracle.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {ICREOracle, ORACLE_GUARD_ROLE, ORACLE_LIMITS_ROLE} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ICREWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {CREOracleTestBase} from "test/adapters/merkle-adapter/oracle/CREOracle.t.sol";

import {defaultOracleInitParams} from "test/helpers/MerkleInitialization.sol";

contract CREOracleAccessControlTest is CREOracleTestBase {
    function test_InitialRolesAndLimitsAreIndependentOfOwner() public {
        address curator = makeAddr("oracle owner");
        address admin = makeAddr("oracle admin");
        address guard = makeAddr("oracle guard");
        address limits = makeAddr("oracle limits");
        ICREOracle.InitParams memory params = defaultOracleInitParams(admin);
        params.oracleGuardRoleHolder = guard;
        params.oracleLimitsRoleHolder = limits;
        params.maxOracleGrowthBps = 123;
        params.maxOracleLossBps = 456;
        CREOracle receiver = _createOracle(curator, params);
        assertEq(receiver.owner(), curator);
        assertEq(receiver.adapter(), address(adapter));
        bytes32[3] memory roles = [bytes32(0), ORACLE_GUARD_ROLE, ORACLE_LIMITS_ROLE];
        address[3] memory holders = [admin, guard, limits];
        for (uint256 i; i < roles.length; ++i) {
            assertTrue(receiver.hasRole(roles[i], holders[i]));
            assertEq(receiver.getRoleMemberCount(roles[i]), 1);
            assertEq(receiver.getRoleMember(roles[i], 0), holders[i]);
            assertFalse(receiver.hasRole(roles[i], curator));
            assertFalse(receiver.hasRole(roles[i], address(factory)));
        }
        assertEq(receiver.maxOracleGrowthBps(), 123);
        assertEq(receiver.maxOracleLossBps(), 456);
        vm.prank(curator);
        vm.expectRevert(_unauthorized(curator, bytes32(0)));
        receiver.grantRole(ORACLE_GUARD_ROLE, curator);
        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, ORACLE_GUARD_ROLE));
        receiver.freezeOracle();
        vm.prank(guard);
        receiver.freezeOracle();
        assertTrue(receiver.oracleFrozen());
        vm.prank(limits);
        receiver.setOracleLimits(0, 10_000);
        assertEq(receiver.maxOracleGrowthBps(), 0);
        assertEq(receiver.maxOracleLossBps(), 10_000);
        bytes32 id = keccak256("independent receiver");
        _proposeWorkflow(address(receiver), id);
        vm.prank(curator);
        _acceptWorkflow(address(receiver), id);
        assertEq(receiver.workflowId(), id);
    }

    function test_ZeroRoleHoldersStayUnsetWithNonzeroOwner() public {
        CREOracle receiver = _createOracle(address(this), defaultOracleInitParams(address(0)));
        assertEq(receiver.owner(), address(this));
        bytes32[3] memory roles = [bytes32(0), ORACLE_GUARD_ROLE, ORACLE_LIMITS_ROLE];
        for (uint256 i; i < roles.length; ++i) {
            assertEq(receiver.getRoleMemberCount(roles[i]), 0);
            assertFalse(receiver.hasRole(roles[i], address(0)));
        }
        vm.expectRevert(_unauthorized(address(this), bytes32(0)));
        receiver.grantRole(ORACLE_GUARD_ROLE, address(this));
    }

    function test_ZeroOwnerCanHaveIndependentRoleHolders() public {
        CREOracle receiver = _createOracle(address(0), defaultOracleInitParams(address(this)));
        assertEq(receiver.owner(), address(0));
        receiver.grantRole(ORACLE_GUARD_ROLE, address(this));
        receiver.freezeOracle();
        assertTrue(receiver.oracleFrozen());
        _proposeWorkflow(address(receiver), keccak256("zero owner"));
        vm.expectRevert(ICREWorkflowRegistry.InvalidCaller.selector);
        _acceptWorkflow(address(receiver), keccak256("zero owner"));
        assertEq(receiver.workflowId(), bytes32(0));
    }

    function testFuzz_InitializationRejectsInvalidMovementLimits(uint256 invalid, bool growth) public {
        invalid = bound(invalid, 10_001, type(uint256).max);
        ICREOracle.InitParams memory params = defaultOracleInitParams(address(this));
        if (growth) params.maxOracleGrowthBps = invalid;
        else params.maxOracleLossBps = invalid;
        uint256 count = factory.totalEntities();
        bytes memory data = abi.encode(address(adapter), abi.encode(params));
        vm.expectRevert(ICREOracle.InvalidOracleLimit.selector);
        factory.create(1, address(this), data);
        assertEq(factory.totalEntities(), count);
    }

    function testFuzz_AccountRolesDoNotAuthorizeOracle(address operator) public {
        vm.assume(operator != address(this) && operator != address(0));
        IMerkleAccount(account).grantRole(bytes32(0), operator);
        IMerkleAccount(account).grantRole(ORACLE_GUARD_ROLE, operator);
        IMerkleAccount(account).grantRole(ORACLE_LIMITS_ROLE, operator);

        vm.startPrank(operator);
        vm.expectRevert(_unauthorized(operator, bytes32(0)));
        oracle.grantRole(ORACLE_GUARD_ROLE, operator);
        vm.expectRevert(ICREWorkflowRegistry.InvalidCaller.selector);
        _acceptWorkflow(address(oracle), WORKFLOW);
        vm.expectRevert(_unauthorized(operator, ORACLE_GUARD_ROLE));
        oracle.freezeOracle();
        vm.expectRevert(_unauthorized(operator, ORACLE_GUARD_ROLE));
        oracle.unfreezeOracle("");
        vm.expectRevert(_unauthorized(operator, ORACLE_LIMITS_ROLE));
        oracle.setOracleLimits(100, 200);
        vm.stopPrank();

        oracle.grantRole(ORACLE_GUARD_ROLE, operator);
        IMerkleAccount(account).revokeRole(ORACLE_GUARD_ROLE, operator);
        vm.prank(operator);
        oracle.freezeOracle();
        assertTrue(oracle.oracleFrozen());
        IMerkleAccount(account).grantRole(ORACLE_GUARD_ROLE, operator);
        oracle.revokeRole(ORACLE_GUARD_ROLE, operator);
        vm.prank(operator);
        vm.expectRevert(_unauthorized(operator, ORACLE_GUARD_ROLE));
        oracle.unfreezeOracle("");
        assertTrue(oracle.oracleFrozen());
    }

    function test_RolesAreIsolatedBetweenOracles() public {
        CREOracle receiver = _createOracle(address(this), defaultOracleInitParams(address(this)));
        vm.expectRevert(_unauthorized(address(this), ORACLE_GUARD_ROLE));
        receiver.freezeOracle();
        oracle.freezeOracle();
        assertTrue(oracle.oracleFrozen());
        assertFalse(receiver.oracleFrozen());
        receiver.grantRole(ORACLE_GUARD_ROLE, address(this));
        oracle.revokeRole(ORACLE_GUARD_ROLE, address(this));
        receiver.freezeOracle();
        assertTrue(receiver.oracleFrozen());
    }

    function test_OwnershipTransferDoesNotTransferOracleRoles() public {
        address nextOwner = makeAddr("next owner");
        oracle.transferOwnership(nextOwner);
        assertTrue(oracle.hasRole(bytes32(0), address(this)));
        assertTrue(oracle.hasRole(ORACLE_GUARD_ROLE, address(this)));
        assertFalse(oracle.hasRole(bytes32(0), nextOwner));
        vm.prank(nextOwner);
        vm.expectRevert(_unauthorized(nextOwner, bytes32(0)));
        oracle.grantRole(ORACLE_GUARD_ROLE, nextOwner);
        oracle.grantRole(bytes32(0), nextOwner);
        vm.prank(nextOwner);
        oracle.revokeRole(bytes32(0), address(this));
        assertEq(oracle.getRoleMemberCount(bytes32(0)), 1);
        assertEq(oracle.getRoleMember(bytes32(0), 0), nextOwner);
        assertTrue(IMerkleAccount(account).hasRole(bytes32(0), address(this)));
    }

    function _createOracle(address newOwner, ICREOracle.InitParams memory params) internal returns (CREOracle) {
        return CREOracle(factory.create(1, newOwner, abi.encode(address(adapter), abi.encode(params))));
    }

    function _unauthorized(address caller, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, role);
    }
}
