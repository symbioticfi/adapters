// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {
    IRecipes,
    OP_CALL,
    OP_LESS_OR_EQUAL,
    OP_READ,
    SRC_INPUT,
    SRC_RESULT
} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {Token} from "test/mocks/Token.sol";
import {flatPlan} from "test/helpers/HashPlan.sol";

contract MerkleAdapterSignaturesTest is CapabilityTestBase {
    bytes32 internal domain = keccak256("test domain");

    function setUp() public {
        _deployAdapter(address(new Token("asset")));
    }

    function testFuzz_ApprovesComputedDigest(bytes32 value) public {
        bytes memory data = abi.encode(keccak256("Data(bytes32 value)"), value);
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, keccak256(data));
        IMerkleAccount.Action[] memory actions =
            _publishCall(account, abi.encodeCall(IMerkleAccount.sign, (domain, data, flatPlan(data))));
        vm.expectEmit(true, true, false, true, account);
        emit IMerkleAccount.Sign(digest, domain, data, flatPlan(data));
        MerkleAccount(payable(account)).manage(actions);
        assertTrue(IMerkleAccount(account).signatures(digest));
        assertFalse(IMerkleAccount(account).signatures(domain));
        assertEq(IMerkleAccount(account).isValidSignature(digest, ""), IERC1271.isValidSignature.selector);
        assertEq(IMerkleAccount(account).isValidSignature(digest, hex"1234"), IERC1271.isValidSignature.selector);
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 0);
    }

    function test_OwnerCannotApproveOutsideManage() public {
        vm.expectRevert(IMerkleAccount.InvalidCaller.selector);
        IMerkleAccount(account).sign(domain, abi.encode(bytes32(uint256(1))), flatPlan(abi.encode(bytes32(uint256(1)))));
    }

    function test_ProofWithoutRoleCannotApprove() public {
        IMerkleAccount.Action[] memory actions = _publishCall(
            account,
            abi.encodeCall(
                IMerkleAccount.sign,
                (domain, abi.encode(bytes32(uint256(1))), flatPlan(abi.encode(bytes32(uint256(1)))))
            )
        );
        address caller = makeAddr("unapproved");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, MerkleAccount(payable(account)).root()
            )
        );
        vm.prank(caller);
        MerkleAccount(payable(account)).manage(actions);
    }

    function test_DomainIsBoundByLeafAndDigest() public {
        bytes memory data = abi.encode(bytes32(uint256(1)));
        IMerkleAccount.Action[] memory actions =
            _publishCall(account, abi.encodeCall(IMerkleAccount.sign, (domain, data, flatPlan(data))));
        MerkleAccount(payable(account)).manage(actions);
        bytes32 other = keccak256("another domain");
        assertEq(
            IMerkleAccount(account).isValidSignature(MessageHashUtils.toTypedDataHash(other, keccak256(data)), ""),
            bytes4(0xffffffff)
        );
        actions[0].data = abi.encodeCall(IMerkleAccount.sign, (other, data, flatPlan(data)));
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        MerkleAccount(payable(account)).manage(actions);
    }

    function testFuzz_DataCannotBeAssociatedWithAnUnrelatedDigest(bytes32 value) public {
        bytes memory data = abi.encode(keccak256("Data(bytes32 value)"), value);
        _manage(account, abi.encodeCall(IMerkleAccount.sign, (domain, data, flatPlan(data))));
        bytes32 actual = MessageHashUtils.toTypedDataHash(domain, keccak256(data));
        assertEq(IMerkleAccount(account).isValidSignature(bytes32(uint256(actual) ^ 1), data), bytes4(0xffffffff));
    }

    /// forge-config: default.isolate = true
    function test_UnknownDigestIsInvalidRegardlessOfSignatureBytes() public {
        bytes4 magic = IMerkleAccount(account).isValidSignature(bytes32(0), "");
        vm.snapshotGasLastCall("MerkleAccount", "isValidSignatureUnapproved");
        assertEq(magic, bytes4(0xffffffff));
        assertEq(IMerkleAccount(account).isValidSignature(bytes32(0), hex"1234"), bytes4(0xffffffff));
    }

    function test_OwnerRevokesAfterRootAndRolesCleared() public {
        bytes memory data = abi.encode(bytes32(uint256(1)));
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, keccak256(data));
        _manage(account, abi.encodeCall(IMerkleAccount.sign, (domain, data, flatPlan(data))));
        MerkleAccount(payable(account)).revokeRole(MerkleAccount(payable(account)).root(), address(this));
        MerkleAccount(payable(account)).renounceRole(bytes32(0), address(this));
        roots.setRoot(account, bytes32(0));
        IMerkleAccount(account).acceptRoot(bytes32(0));
        assertEq(IMerkleAccount(account).isValidSignature(digest, ""), IERC1271.isValidSignature.selector);

        vm.expectEmit(true, false, false, true, account);
        emit IMerkleAccount.RevokeSignature(digest);
        IMerkleAccount(account).revokeSignature(digest);
        assertFalse(IMerkleAccount(account).signatures(digest));
        assertEq(IMerkleAccount(account).isValidSignature(digest, ""), bytes4(0xffffffff));
    }

    function testFuzz_RevocationRejectsNonOwnerDespiteRoles(address caller) public {
        vm.assume(caller != address(this));
        bytes memory data = abi.encode(bytes32(uint256(1)));
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, keccak256(data));
        _manage(account, abi.encodeCall(IMerkleAccount.sign, (domain, data, flatPlan(data))));
        IMerkleAccount(account).grantRole(bytes32(0), caller);
        IMerkleAccount(account).grantRole(IMerkleAccount(account).root(), caller);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        IMerkleAccount(account).revokeSignature(digest);
        assertTrue(IMerkleAccount(account).signatures(digest));
    }

    function test_ManageCannotRevokeEvenWithLeafAndRole() public {
        bytes memory data = abi.encode(bytes32(uint256(1)));
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, keccak256(data));
        _manage(account, abi.encodeCall(IMerkleAccount.sign, (domain, data, flatPlan(data))));
        IMerkleAccount.Action[] memory actions =
            _publishCall(account, abi.encodeCall(IMerkleAccount.revokeSignature, (digest)));

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, account));
        IMerkleAccount(account).manage(actions);
        assertTrue(IMerkleAccount(account).signatures(digest));
    }

    function test_RevocationAuthorityFollowsOwnershipTransfer() public {
        bytes memory data = abi.encode(bytes32(uint256(1)));
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, keccak256(data));
        _manage(account, abi.encodeCall(IMerkleAccount.sign, (domain, data, flatPlan(data))));
        address nextOwner = makeAddr("next owner");
        MerkleAccount(payable(account)).transferOwnership(nextOwner);
        assertTrue(IMerkleAccount(account).hasRole(bytes32(0), address(this)));
        assertFalse(IMerkleAccount(account).hasRole(bytes32(0), nextOwner));

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        IMerkleAccount(account).revokeSignature(digest);
        vm.prank(nextOwner);
        IMerkleAccount(account).revokeSignature(digest);
        assertFalse(IMerkleAccount(account).signatures(digest));
    }

    function test_AbsentRevocationEmitsNoEventAndDigestCanBeApprovedAgain() public {
        bytes memory data = abi.encode(keccak256("Data(bytes32 value)"), bytes32(uint256(1)));
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, keccak256(data));
        vm.recordLogs();
        IMerkleAccount(account).revokeSignature(digest);
        assertEq(vm.getRecordedLogs().length, 0);
        IMerkleAccount.Action[] memory actions =
            _publishCall(account, abi.encodeCall(IMerkleAccount.sign, (domain, data, flatPlan(data))));
        MerkleAccount(payable(account)).manage(actions);
        IMerkleAccount(account).revokeSignature(digest);
        vm.recordLogs();
        IMerkleAccount(account).revokeSignature(digest);
        assertEq(vm.getRecordedLogs().length, 0);
        MerkleAccount(payable(account)).manage(actions);
        assertTrue(IMerkleAccount(account).signatures(digest));
    }

    function test_ApprovalsAreIndependent() public {
        bytes memory first = abi.encode(bytes32(uint256(1)));
        bytes memory second = abi.encode(bytes32(uint256(2)));
        bytes32 firstDigest = MessageHashUtils.toTypedDataHash(domain, keccak256(first));
        bytes32 secondDigest = MessageHashUtils.toTypedDataHash(domain, keccak256(second));
        _manage(account, abi.encodeCall(IMerkleAccount.sign, (domain, first, flatPlan(first))));
        _manage(account, abi.encodeCall(IMerkleAccount.sign, (domain, second, flatPlan(second))));
        IMerkleAccount(account).revokeSignature(firstDigest);
        assertEq(IMerkleAccount(account).isValidSignature(firstDigest, ""), bytes4(0xffffffff));
        assertEq(IMerkleAccount(account).isValidSignature(secondDigest, ""), IERC1271.isValidSignature.selector);
    }

    function test_RootAndRoleChangesDoNotImplicitlyRevokeApproval() public {
        bytes memory data = abi.encode(bytes32(uint256(1)));
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, keccak256(data));
        _manage(account, abi.encodeCall(IMerkleAccount.sign, (domain, data, flatPlan(data))));
        MerkleAccount(payable(account)).revokeRole(MerkleAccount(payable(account)).root(), address(this));
        roots.setRoot(account, bytes32(0));
        MerkleAccount(payable(account)).acceptRoot(bytes32(0));
        assertEq(IMerkleAccount(account).isValidSignature(digest, ""), IERC1271.isValidSignature.selector);
    }

    function test_GuardChecksActualSignedAmountAndRollsBackApproval() public {
        _installCapability(adapter, address(new RecipeCapability()), _recipeSelectors());
        Token token = new Token("guarded asset");
        deal(address(token), account, 100);
        bytes memory signData = abi.encodeCall(
            IMerkleAccount.sign,
            (
                domain,
                abi.encode(keccak256("Order(uint256 amount)"), uint256(0)),
                flatPlan(abi.encode(keccak256("Order(uint256 amount)"), uint256(0)))
            )
        );
        uint256[] memory bindings = new uint256[](1);
        bindings[0] = (uint256(4 + 5 * 32) << 224) | uint256(SRC_INPUT) << 216;
        bytes[] memory steps = new bytes[](3);
        steps[0] = abi.encodePacked(OP_CALL, abi.encode(account, signData, bindings));
        steps[1] = abi.encodePacked(OP_READ, abi.encode(uint256(0)));
        steps[2] =
            abi.encodePacked(OP_LESS_OR_EQUAL, abi.encode(uint256(SRC_INPUT) << 216, (uint256(SRC_RESULT) << 216) | 1));
        bytes[] memory queries = new bytes[](1);
        queries[0] =
            abi.encode(address(token), abi.encodeCall(IERC20.balanceOf, (account)), new uint256[](0), uint256(0));
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = 101;
        IMerkleAccount.Action[] memory actions =
            _publishCall(account, abi.encodeCall(IRecipeCapability.execute, (queries, steps, inputs)));
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            domain, keccak256(abi.encode(keccak256("Order(uint256 amount)"), uint256(101)))
        );
        vm.expectRevert(IRecipes.CheckFailed.selector);
        MerkleAccount(payable(account)).manage(actions);
        assertFalse(IMerkleAccount(account).signatures(digest));
        deal(address(token), account, 101);
        MerkleAccount(payable(account)).manage(actions);
        assertTrue(IMerkleAccount(account).signatures(digest));
    }

    /// forge-config: default.isolate = true
    function test_GasApproveValidateAndRevoke() public {
        bytes memory data = abi.encode(bytes32(uint256(1)));
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, keccak256(data));
        IMerkleAccount.Action[] memory actions =
            _publishCall(account, abi.encodeCall(IMerkleAccount.sign, (domain, data, flatPlan(data))));
        MerkleAccount(payable(account)).manage(actions);
        vm.snapshotGasLastCall("MerkleAdapterSignatures", "approve");
        bytes4 magic = IMerkleAccount(account).isValidSignature(digest, "");
        vm.snapshotGasLastCall("MerkleAdapterSignatures", "validate");
        assertEq(magic, IERC1271.isValidSignature.selector);
        IMerkleAccount(account).revokeSignature(digest);
        vm.snapshotGasLastCall("MerkleAdapterSignatures", "revoke");
    }
}
