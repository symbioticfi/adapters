// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";

import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Token} from "test/mocks/Token.sol";

contract SignatureValidatorMock is IERC1271 {
    function isValidSignature(bytes32 digest, bytes calldata data) public view returns (bytes4) {
        (address expectedAdapter, bytes memory payload) = abi.decode(data, (address, bytes));
        return expectedAdapter == msg.sender && digest == keccak256(payload)
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }
}

contract WritingSignatureValidatorMock {
    uint256 public calls;

    function isValidSignature(bytes32, bytes calldata) public returns (bytes4) {
        ++calls;
        return IERC1271.isValidSignature.selector;
    }
}

contract MerkleAdapterSignaturesTest is CapabilityTestBase {
    address internal validator;

    function setUp() public {
        _deployAdapter(address(new Token("asset")));
        validator = address(new SignatureValidatorMock());
    }

    function testFuzz_ApprovesExactEnvelopeAndUsesAdapterContext(bytes memory payload) public {
        bytes32 digest = keccak256(payload);
        bytes memory signature = abi.encode(validator, abi.encode(address(adapter), payload));
        IMerkleAdapter.Action[] memory actions =
            _publishCall(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (digest, signature)));
        vm.expectEmit(true, false, false, true, address(adapter));
        emit IMerkleAdapter.SetSignature(digest, signature);
        adapter.manage(actions);

        assertEq(adapter.signatures(digest), signature);
        vm.prank(makeAddr("protocol"));
        assertEq(adapter.isValidSignature(digest, signature), IERC1271.isValidSignature.selector);
        assertEq(adapter.getCapabilities().length, 0);
    }

    function test_OwnerCannotApproveOutsideManage() public {
        vm.expectRevert(IMerkleAdapter.InvalidCaller.selector);
        adapter.setSignature(bytes32(0), hex"1234");
    }

    function test_RoleHolderCannotApproveOutsideManage() public {
        bytes memory data = abi.encodeCall(IMerkleAdapter.setSignature, (bytes32(0), hex"1234"));
        _publishCall(address(adapter), data);
        vm.expectRevert(IMerkleAdapter.InvalidCaller.selector);
        adapter.setSignature(bytes32(0), hex"1234");
    }

    function test_ProofWithoutRoleCannotApprove() public {
        IMerkleAdapter.Action[] memory actions =
            _publishCall(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (bytes32(0), hex"1234")));
        address caller = makeAddr("unapproved");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, adapter.merkleRoot()
            )
        );
        vm.prank(caller);
        adapter.manage(actions);
        assertEq(adapter.signatures(bytes32(0)), bytes(""));
    }

    function test_ChangedValidatorCannotUseSetterProof() public {
        bytes memory signature = abi.encode(validator, abi.encode(address(adapter), hex"1234"));
        IMerkleAdapter.Action[] memory actions = _publishCall(
            address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (keccak256(hex"1234"), signature))
        );
        actions[0].data = abi.encodeCall(
            IMerkleAdapter.setSignature,
            (
                keccak256(hex"1234"),
                abi.encode(address(new SignatureValidatorMock()), abi.encode(address(adapter), hex"1234"))
            )
        );
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        adapter.manage(actions);
    }

    function test_UnknownDigestAndEmptySignatureAreInvalid() public view {
        assertEq(adapter.isValidSignature(bytes32(0), bytes("")), bytes4(0xffffffff));
        assertEq(adapter.isValidSignature(bytes32(0), hex"1234"), bytes4(0xffffffff));
    }

    function testFuzz_ChangedEnvelopeIsInvalid(bytes memory payload, bytes memory changed) public {
        bytes32 digest = keccak256(payload);
        bytes memory signature = abi.encode(validator, abi.encode(address(adapter), payload));
        vm.assume(keccak256(changed) != keccak256(signature));
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (digest, signature)));
        assertEq(adapter.isValidSignature(digest, changed), bytes4(0xffffffff));
    }

    function test_SavedEnvelopeDoesNotBypassDigestValidation() public {
        bytes memory signature = abi.encode(validator, abi.encode(address(adapter), hex"1234"));
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (bytes32(0), signature)));
        assertEq(adapter.isValidSignature(bytes32(0), signature), bytes4(0xffffffff));
    }

    function test_ReplaceAndRevokeSignature() public {
        bytes32 digest = keccak256(hex"1234");
        bytes memory first = abi.encode(validator, abi.encode(address(adapter), hex"1234"));
        bytes memory second = abi.encode(address(new SignatureValidatorMock()), abi.encode(address(adapter), hex"1234"));
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (digest, first)));
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (digest, second)));
        assertEq(adapter.isValidSignature(digest, first), bytes4(0xffffffff));
        assertEq(adapter.isValidSignature(digest, second), IERC1271.isValidSignature.selector);
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (digest, bytes(""))));
        assertEq(adapter.signatures(digest), bytes(""));
        assertEq(adapter.isValidSignature(digest, second), bytes4(0xffffffff));
    }

    function test_MultipleValidatorsCoexist() public {
        bytes32 firstDigest = keccak256(hex"1234");
        bytes32 secondDigest = keccak256(hex"5678");
        bytes memory first = abi.encode(validator, abi.encode(address(adapter), hex"1234"));
        bytes memory second = abi.encode(address(new SignatureValidatorMock()), abi.encode(address(adapter), hex"5678"));
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (firstDigest, first)));
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (secondDigest, second)));
        assertEq(adapter.isValidSignature(firstDigest, first), IERC1271.isValidSignature.selector);
        assertEq(adapter.isValidSignature(secondDigest, second), IERC1271.isValidSignature.selector);
    }

    function test_InstalledCapabilityCannotOverrideNativeValidation() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IERC1271.isValidSignature.selector;
        _installCapability(adapter, validator, selectors);
        bytes memory data = abi.encode(address(this), hex"1234");
        assertEq(IERC1271(validator).isValidSignature(keccak256(hex"1234"), data), IERC1271.isValidSignature.selector);
        assertEq(adapter.isValidSignature(keccak256(hex"1234"), data), bytes4(0xffffffff));
    }

    function test_ValidatorCannotModifyState() public {
        address writer = address(new WritingSignatureValidatorMock());
        bytes memory signature = abi.encode(writer, bytes(""));
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (bytes32(0), signature)));
        assertEq(adapter.isValidSignature(bytes32(0), signature), bytes4(0xffffffff));
        assertEq(WritingSignatureValidatorMock(writer).calls(), 0);
    }

    function test_RevertingValidatorIsInvalid() public {
        bytes memory signature = abi.encode(validator, hex"1234");
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (bytes32(0), signature)));
        assertEq(adapter.isValidSignature(bytes32(0), signature), bytes4(0xffffffff));
    }

    function test_ValidatorReturningShortDataIsInvalid() public {
        bytes memory signature = abi.encode(validator, hex"1234");
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (bytes32(0), signature)));
        vm.mockCall(validator, abi.encodeWithSelector(IERC1271.isValidSignature.selector), hex"1626ba7e");
        assertEq(adapter.isValidSignature(bytes32(0), signature), bytes4(0xffffffff));
    }

    function test_ValidatorReturningDirtyPaddingIsInvalid() public {
        bytes memory signature = abi.encode(validator, hex"1234");
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (bytes32(0), signature)));
        vm.mockCall(
            validator,
            abi.encodeWithSelector(IERC1271.isValidSignature.selector),
            abi.encode(bytes32(IERC1271.isValidSignature.selector) | bytes32(uint256(1)))
        );
        assertEq(adapter.isValidSignature(bytes32(0), signature), bytes4(0xffffffff));
    }

    function test_EoaValidatorIsInvalid() public {
        bytes memory signature = abi.encode(makeAddr("eoa"), bytes(""));
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (bytes32(0), signature)));
        assertEq(adapter.isValidSignature(bytes32(0), signature), bytes4(0xffffffff));
    }

    function test_SelfValidatorCannotRecurse() public {
        bytes memory signature = abi.encode(address(adapter), hex"1234");
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (bytes32(0), signature)));
        assertEq(adapter.isValidSignature(bytes32(0), signature), bytes4(0xffffffff));
    }

    function test_MalformedApprovedEnvelopeCanBeRevoked() public {
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (bytes32(0), hex"1234")));
        vm.expectRevert();
        adapter.isValidSignature(bytes32(0), hex"1234");
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (bytes32(0), bytes(""))));
        assertEq(adapter.isValidSignature(bytes32(0), hex"1234"), bytes4(0xffffffff));
    }

    function test_RootAndRoleChangesDoNotImplicitlyRevokeSavedApproval() public {
        bytes32 digest = keccak256(hex"1234");
        bytes memory signature = abi.encode(validator, abi.encode(address(adapter), hex"1234"));
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (digest, signature)));
        adapter.revokeRole(adapter.merkleRoot(), address(this));
        roots.setRoot(address(adapter), bytes32(0));
        adapter.acceptRoot(bytes32(0));
        assertEq(adapter.isValidSignature(digest, signature), IERC1271.isValidSignature.selector);
    }

    /// forge-config: default.isolate = true
    function test_GasApproveValidateAndRevoke() public {
        bytes32 digest = keccak256(hex"1234");
        bytes memory signature = abi.encode(validator, abi.encode(address(adapter), hex"1234"));
        IMerkleAdapter.Action[] memory actions =
            _publishCall(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (digest, signature)));
        adapter.manage(actions);
        vm.snapshotGasLastCall("MerkleAdapterSignatures", "approve");
        assertEq(adapter.isValidSignature(digest, signature), IERC1271.isValidSignature.selector);
        vm.snapshotGasLastCall("MerkleAdapterSignatures", "validate");
        actions = _publishCall(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (digest, bytes(""))));
        adapter.manage(actions);
        vm.snapshotGasLastCall("MerkleAdapterSignatures", "revoke");
    }
}
