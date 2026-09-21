// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Token} from "test/mocks/Token.sol";

contract MerkleAccountHashingTest is CapabilityTestBase {
    function setUp() public {
        _deployAdapter(address(new Token("asset")));
    }

    function testFuzz_GenericNestedHash(bytes32 domain, bytes32 token, uint256 amount, bytes32 recipient) public {
        bytes32 itemType = keccak256("Item(bytes32 token,uint256 amount,bytes32 recipient)");
        bytes32 requestType =
            keccak256("Batch(Item[] items,uint256 nonce)Item(bytes32 token,uint256 amount,bytes32 recipient)");
        bytes memory data = abi.encode(requestType, itemType, token, amount, recipient, uint256(7));
        IMerkleAccount.Hash[] memory hashes = new IMerkleAccount.Hash[](2);
        hashes[0] = IMerkleAccount.Hash({start: 32, end: 160});
        hashes[1] = IMerkleAccount.Hash({start: 32, end: 64});
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            domain,
            keccak256(
                abi.encode(
                    requestType,
                    keccak256(abi.encode(keccak256(abi.encode(itemType, token, amount, recipient)))),
                    uint256(7)
                )
            )
        );
        _manage(account, abi.encodeCall(IMerkleAccount.setSignature, (domain, data, hashes)));
        assertTrue(IMerkleAccount(account).signatures(digest));
    }

    function testFuzz_HashesDynamicFieldsIncludingEmptyValues(bytes memory first, bytes memory second) public {
        bytes32 typeHash = keccak256("Message(bytes first,bytes second)");
        bytes memory data = bytes.concat(typeHash, first, second);
        IMerkleAccount.Hash[] memory hashes = new IMerkleAccount.Hash[](2);
        hashes[0] = IMerkleAccount.Hash({start: 32, end: 32 + first.length});
        hashes[1] = IMerkleAccount.Hash({start: 64, end: 64 + second.length});
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            bytes32(0), keccak256(abi.encode(typeHash, keccak256(first), keccak256(second)))
        );
        _manage(account, abi.encodeCall(IMerkleAccount.setSignature, (bytes32(0), data, hashes)));
        assertTrue(IMerkleAccount(account).signatures(digest));
    }

    function test_EmptyPreimageAndEmptyArrayHash() public {
        IMerkleAccount.Hash[] memory hashes = new IMerkleAccount.Hash[](1);
        hashes[0] = IMerkleAccount.Hash({start: 0, end: 0});
        _manage(account, abi.encodeCall(IMerkleAccount.setSignature, (bytes32(0), bytes(""), hashes)));
        assertTrue(
            IMerkleAccount(account)
                .signatures(MessageHashUtils.toTypedDataHash(bytes32(0), keccak256(abi.encode(keccak256("")))))
        );
        _manage(
            account, abi.encodeCall(IMerkleAccount.setSignature, (bytes32(0), bytes(""), new IMerkleAccount.Hash[](0)))
        );
        assertTrue(IMerkleAccount(account).signatures(MessageHashUtils.toTypedDataHash(bytes32(0), keccak256(""))));
    }

    function testFuzz_RejectsInvalidRanges(uint256 start, uint256 end) public {
        vm.assume(start > end || end > 64);
        IMerkleAccount.Hash[] memory hashes = new IMerkleAccount.Hash[](1);
        hashes[0] = IMerkleAccount.Hash({start: start, end: end});
        IMerkleAccount.Action[] memory actions =
            _publishCall(account, abi.encodeCall(IMerkleAccount.setSignature, (bytes32(0), new bytes(64), hashes)));
        vm.expectRevert(IMerkleAccount.InvalidSignature.selector);
        MerkleAccount(payable(account)).manage(actions);
    }

    function test_RangesReferToTheShortenedPreimage() public {
        IMerkleAccount.Hash[] memory hashes = new IMerkleAccount.Hash[](2);
        hashes[0] = IMerkleAccount.Hash({start: 0, end: 64});
        hashes[1] = IMerkleAccount.Hash({start: 0, end: 64});
        IMerkleAccount.Action[] memory actions =
            _publishCall(account, abi.encodeCall(IMerkleAccount.setSignature, (bytes32(0), new bytes(64), hashes)));
        vm.expectRevert(IMerkleAccount.InvalidSignature.selector);
        MerkleAccount(payable(account)).manage(actions);
    }

    /// forge-config: default.isolate = true
    function test_GasNestedHashAndEvent() public {
        bytes memory data = abi.encode(uint256(1), uint256(2));
        IMerkleAccount.Hash[] memory hashes = new IMerkleAccount.Hash[](2);
        hashes[0] = IMerkleAccount.Hash({start: 0, end: 64});
        hashes[1] = IMerkleAccount.Hash({start: 0, end: 32});
        IMerkleAccount.Action[] memory actions =
            _publishCall(account, abi.encodeCall(IMerkleAccount.setSignature, (bytes32(0), data, hashes)));
        bytes32 digest =
            MessageHashUtils.toTypedDataHash(bytes32(0), keccak256(abi.encode(keccak256(abi.encode(keccak256(data))))));
        vm.expectEmit(true, false, false, true, account);
        emit IMerkleAccount.SetSignature(digest, data, hashes);
        MerkleAccount(payable(account)).manage(actions);
        vm.snapshotGasLastCall("MerkleAccountHashing", "approveNested");
        assertTrue(IMerkleAccount(account).signatures(digest));
    }
}
