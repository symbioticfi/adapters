// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {LLExecutingTest} from "./LLExecuting.t.sol";
import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {
    ILiquidLaneConnector,
    DISCOUNT_TYPEHASH,
    DISCOUNT_SWAP_TYPEHASH
} from "src/interfaces/merkle-adapter/connectors/ILiquidLaneConnector.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LiquidLaneSignatureWallet {
    bytes32 internal digest;
    bytes32 internal signatureHash;
    bool public revoked;

    function approve(bytes32 hash, bytes memory signature) external {
        digest = hash;
        signatureHash = keccak256(signature);
    }

    function revoke() external {
        revoked = true;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        return
            !revoked && hash == digest && keccak256(signature) == signatureHash
                ? bytes4(0x1626ba7e)
                : bytes4(0xffffffff);
    }
}

contract LiquidLaneContractSignaturesTest is LLExecutingTest {
    uint256 internal constant CAPACITY = 4095;
    uint256 internal constant FIRST_LENGTH = 388;
    uint256 internal constant SECOND_LENGTH = 4516;

    function test_BoundedEOASignaturesExecuteThroughMerkleAccount() public {
        (ILiquidLaneConnector.DiscountSwap memory quote, bytes memory protocol) =
            _quote(10_000_000, type(uint48).max, type(uint48).max, false);
        (IMerkleAccount.Action[] memory actions,) = _boundedAction(quote, protocol);
        MerkleAccount(payable(account)).manage(actions);
        assertEq(IERC20(_rwa).balanceOf(account), 100);
        assertEq(IERC20(_asset).balanceOf(_recipient), 90);
    }

    function test_BoundedContractSignaturesExecuteExactBytesIncludingEmptyAndMaximum() public {
        _contractSignatures(0, 4095, false);
    }

    function test_BoundedContractSignaturesRejectRevocation() public {
        _contractSignatures(130, 1, true);
    }

    function _contractSignatures(uint256 firstLength, uint256 secondLength, bool revoke) internal {
        LiquidLaneSignatureWallet signer = new LiquidLaneSignatureWallet();
        LiquidLaneSignatureWallet protocol = new LiquidLaneSignatureWallet();
        _manage(_lane, abi.encodeCall(ILiquidLaneConnector.setSigner, (address(signer))));
        (ILiquidLaneConnector.DiscountSwap memory quote,) =
            _quote(10_000_000, type(uint48).max, type(uint48).max, false);
        quote.discount.signer = address(signer);
        quote.discount.protocol = address(protocol);
        quote.signerSignature = new bytes(firstLength);
        bytes memory protocolSignature = new bytes(secondLength);
        if (firstLength != 0) quote.signerSignature[firstLength - 1] = 0xab;
        if (secondLength != 0) protocolSignature[secondLength - 1] = 0xcd;
        bytes32 discountHash = keccak256(abi.encode(DISCOUNT_TYPEHASH, quote.discount));
        signer.approve(keccak256(abi.encodePacked(hex"1901", _domain(), discountHash)), quote.signerSignature);
        protocol.approve(
            keccak256(
                abi.encodePacked(
                    hex"1901",
                    _domain(),
                    keccak256(
                        abi.encode(
                            DISCOUNT_SWAP_TYPEHASH,
                            discountHash,
                            keccak256(quote.signerSignature),
                            quote.protocolDeadline
                        )
                    )
                )
            ),
            protocolSignature
        );
        (IMerkleAccount.Action[] memory actions,) = _boundedAction(quote, protocolSignature);
        if (revoke) {
            signer.revoke();
            vm.expectRevert(ILiquidLaneConnector.InvalidSignature.selector);
        }
        MerkleAccount(payable(account)).manage(actions);
        assertEq(IERC20(_rwa).balanceOf(account), revoke ? 0 : 100);
    }

    function test_BoundedLeafRejectsLengthHighBitsOffsetsAndRecipientChanges() public {
        (ILiquidLaneConnector.DiscountSwap memory quote, bytes memory protocol) =
            _quote(10_000_000, type(uint48).max, type(uint48).max, false);
        (IMerkleAccount.Action[] memory actions, bytes32 leaf) = _boundedAction(quote, protocol);
        uint256[5] memory offsets = [uint256(4), 36, 68, FIRST_LENGTH + 30, SECOND_LENGTH + 30];
        for (uint256 i; i < offsets.length; ++i) {
            actions[0].data[offsets[i]] ^= 0x10;
            assertNotEq(ActionMasker.mask(_lane, 0, actions[0].data, actions[0].dataMask), leaf);
            vm.expectRevert();
            MerkleAccount(payable(account)).manage(actions);
            actions[0].data[offsets[i]] ^= 0x10;
        }
        MerkleAccount(payable(account)).manage(actions);
    }

    function _boundedAction(ILiquidLaneConnector.DiscountSwap memory quote, bytes memory protocol)
        internal
        returns (IMerkleAccount.Action[] memory actions, bytes32 leaf)
    {
        bytes memory signer = quote.signerSignature;
        quote.signerSignature = new bytes(CAPACITY);
        bytes memory data = _encodeSwap(quote, new bytes(CAPACITY));
        _writeBytes(data, FIRST_LENGTH, signer);
        _writeBytes(data, SECOND_LENGTH, protocol);
        bytes memory mask = new bytes(data.length);
        _mask(mask, 100, 132);
        _mask(mask, 164, 196);
        _mask(mask, 260, 324);
        _mask(mask, 356, 388);
        for (uint256 i; i < 2; ++i) {
            uint256 start = i == 0 ? FIRST_LENGTH : SECOND_LENGTH;
            mask[start + 30] = 0x0f;
            mask[start + 31] = 0xff;
            _mask(mask, start + 32, start + 32 + CAPACITY);
        }
        deal(_asset, account, 1000);
        _manage(_asset, abi.encodeCall(IERC20.approve, (_lane, type(uint256).max)));
        leaf = ActionMasker.mask(_lane, 0, data, mask);
        roots.setRoot(account, leaf);
        MerkleAccount(payable(account)).acceptRoot(leaf);
        MerkleAccount(payable(account)).grantRole(leaf, address(this));
        actions = new IMerkleAccount.Action[](1);
        actions[0] = IMerkleAccount.Action(_lane, 0, data, mask, new bytes32[](0));
    }

    function _writeBytes(bytes memory data, uint256 start, bytes memory signature) internal pure {
        uint256 length = signature.length;
        require(length <= CAPACITY);
        assembly ("memory-safe") { mstore(add(add(data, 32), start), length) }
        for (uint256 i; i < length; ++i) {
            data[start + 32 + i] = signature[i];
        }
    }
}
