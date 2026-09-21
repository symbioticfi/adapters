// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {ICoWSwapSettlement} from "src/interfaces/common/ICoWSwapConverter.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CoWSettlementMock} from "test/mocks/CoWSettlementMock.sol";
import {Token} from "test/mocks/Token.sol";

contract CoWSwapLeavesTest is CapabilityTestBase {
    address internal settlement;
    address internal asset;

    function setUp() public {
        asset = address(new Token("asset"));
        settlement = address(new CoWSettlementMock());
        _deployAdapter(asset);
    }

    function testFuzz_PreSignAndCancelDirectlyWithoutCapability(bytes32 digest, uint32 validTo) public {
        bytes memory uid = abi.encodePacked(digest, account, validTo);
        _manage(settlement, abi.encodeCall(ICoWSwapSettlement.setPreSignature, (uid, true)));
        assertGt(CoWSettlementMock(settlement).preSignature(uid), 0);
        _manage(settlement, abi.encodeCall(ICoWSwapSettlement.setPreSignature, (uid, false)));
        assertEq(CoWSettlementMock(settlement).preSignature(uid), 0);
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 0);
    }

    function test_ApprovalRemainsAnIndependentTokenLeaf() public {
        address relayer = makeAddr("relayer");
        _manage(asset, abi.encodeCall(IERC20.approve, (relayer, 10)));
        bytes memory uid = abi.encodePacked(bytes32(0), account, uint32(1));
        _manage(settlement, abi.encodeCall(ICoWSwapSettlement.setPreSignature, (uid, true)));
        _manage(settlement, abi.encodeCall(ICoWSwapSettlement.setPreSignature, (uid, false)));
        assertEq(IERC20(asset).allowance(account, relayer), 10);
        _manage(asset, abi.encodeCall(IERC20.approve, (relayer, 0)));
        assertEq(IERC20(asset).allowance(account, relayer), 0);
    }

    function testFuzz_MaskedLeafAllowsAnyDigestAndExpiry(bytes32 digest, uint32 validTo) public {
        IMerkleAccount.Action[] memory actions = _authorizeSigning();
        bytes memory uid = abi.encodePacked(digest, account, validTo);
        actions[0].data = abi.encodeCall(ICoWSwapSettlement.setPreSignature, (uid, true));
        MerkleAccount(payable(account)).manage(actions);
        assertGt(CoWSettlementMock(settlement).preSignature(uid), 0);
    }

    function testFuzz_OnlyDigestAndExpiryAreMutable(uint16 index) public {
        IMerkleAccount.Action[] memory actions = _authorizeSigning();
        index = uint16(bound(index, 0, actions[0].data.length - 1));
        vm.assume(index < 100 || (index >= 132 && index < 152) || index >= 156);
        actions[0].data[index] ^= 0x01;
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        MerkleAccount(payable(account)).manage(actions);
    }

    function test_SigningLeafCannotBeUsedForCancellationOrAnotherTarget() public {
        IMerkleAccount.Action[] memory actions = _authorizeSigning();
        actions[0].data[67] = 0;
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        MerkleAccount(payable(account)).manage(actions);
        actions[0].data[67] = 0x01;
        actions[0].target = makeAddr("other settlement");
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        MerkleAccount(payable(account)).manage(actions);
    }

    function test_LeafRoleIsRequiredEvenWithValidProof() public {
        IMerkleAccount.Action[] memory actions = _authorizeSigning();
        bytes32 leaf = MerkleAccount(payable(account)).merkleRoot();
        address caller = makeAddr("not authorized");
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, leaf));
        vm.prank(caller);
        MerkleAccount(payable(account)).manage(actions);
    }

    function test_ExactUidLeafRejectsAnotherOrder() public {
        bytes memory uid = abi.encodePacked(bytes32(0), account, uint32(1));
        IMerkleAccount.Action[] memory actions =
            _publishCall(settlement, abi.encodeCall(ICoWSwapSettlement.setPreSignature, (uid, true)));
        actions[0].data[100] = 0x01;
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        MerkleAccount(payable(account)).manage(actions);
    }

    function test_NewOrderDoesNotImplicitlyCancelExistingOrders() public {
        IMerkleAccount.Action[] memory actions = _authorizeSigning();
        bytes memory first = abi.encodePacked(bytes32(0), account, uint32(1));
        bytes memory second = abi.encodePacked(bytes32(uint256(1)), account, uint32(2));
        actions[0].data = abi.encodeCall(ICoWSwapSettlement.setPreSignature, (first, true));
        MerkleAccount(payable(account)).manage(actions);
        actions[0].data = abi.encodeCall(ICoWSwapSettlement.setPreSignature, (second, true));
        MerkleAccount(payable(account)).manage(actions);
        assertGt(CoWSettlementMock(settlement).preSignature(first), 0);
        assertGt(CoWSettlementMock(settlement).preSignature(second), 0);
    }

    function _authorizeSigning() internal returns (IMerkleAccount.Action[] memory actions) {
        bytes memory data = abi.encodeCall(
            ICoWSwapSettlement.setPreSignature, (abi.encodePacked(bytes32(0), account, uint32(0)), true)
        );
        bytes memory mask = new bytes(data.length);
        for (uint256 i = 100; i < 132; ++i) {
            mask[i] = 0xff;
        }
        for (uint256 i = 152; i < 156; ++i) {
            mask[i] = 0xff;
        }
        bytes32 leaf = MerkleAdapterVerifier.leaf(settlement, 0, data, mask);
        roots.setRoot(account, leaf);
        MerkleAccount(payable(account)).acceptRoot(leaf);
        MerkleAccount(payable(account)).grantRole(leaf, address(this));
        actions = new IMerkleAccount.Action[](1);
        actions[0] =
            IMerkleAccount.Action({target: settlement, value: 0, data: data, dataMask: mask, proof: new bytes32[](0)});
    }
}
