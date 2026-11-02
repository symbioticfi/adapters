// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {Token} from "test/mocks/Token.sol";
import {flatPlan} from "test/helpers/HashPlan.sol";

/// @dev The buffer never changes length, so a nested field keeps a reserved word in the struct and
/// its expansion lives in a scratch area after the struct. Offsets therefore stay fixed for the plan.
contract MerkleAccountHashingTest is CapabilityTestBase {
    function setUp() public {
        _deployAdapter(address(new Token("asset")));
    }

    function testFuzz_GenericNestedHash(bytes32 domain, bytes32 token, uint256 amount, bytes32 recipient) public {
        bytes32 itemType = keccak256("Item(bytes32 token,uint256 amount,bytes32 recipient)");
        bytes32 requestType =
            keccak256("Batch(Item[] items,uint256 nonce)Item(bytes32 token,uint256 amount,bytes32 recipient)");
        // Words 0-2 are the struct; words 3-6 are the scratch encoding of the single item.
        bytes memory buffer = abi.encode(requestType, bytes32(0), uint256(7), itemType, token, amount, recipient);

        IMerkleAccount.Hash[] memory plan = new IMerkleAccount.Hash[](3);
        plan[0] = IMerkleAccount.Hash({offset: 96, length: 128, destination: 96});
        plan[1] = IMerkleAccount.Hash({offset: 96, length: 32, destination: 32});
        plan[2] = IMerkleAccount.Hash({offset: 0, length: 96, destination: 0});

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
        _manage(account, abi.encodeCall(IMerkleAccount.sign, (domain, buffer, plan)));
        assertTrue(IMerkleAccount(account).signatures(digest));
    }

    function testFuzz_HashesDynamicFieldsIncludingEmptyValues(bytes memory first, bytes memory second) public {
        bytes32 typeHash = keccak256("Message(bytes first,bytes second)");
        bytes memory buffer = bytes.concat(typeHash, bytes32(0), bytes32(0), first, second);

        IMerkleAccount.Hash[] memory plan = new IMerkleAccount.Hash[](3);
        plan[0] = IMerkleAccount.Hash({offset: 96, length: first.length, destination: 32});
        plan[1] = IMerkleAccount.Hash({offset: 96 + first.length, length: second.length, destination: 64});
        plan[2] = IMerkleAccount.Hash({offset: 0, length: 96, destination: 0});

        bytes32 digest = MessageHashUtils.toTypedDataHash(
            bytes32(0), keccak256(abi.encode(typeHash, keccak256(first), keccak256(second)))
        );
        _manage(account, abi.encodeCall(IMerkleAccount.sign, (bytes32(0), buffer, plan)));
        assertTrue(IMerkleAccount(account).signatures(digest));
    }

    function test_ZeroLengthStepHashesAnEmptyValue() public {
        bytes memory buffer = abi.encode(bytes32(0), bytes32(0));
        IMerkleAccount.Hash[] memory plan = new IMerkleAccount.Hash[](2);
        plan[0] = IMerkleAccount.Hash({offset: 64, length: 0, destination: 32});
        plan[1] = IMerkleAccount.Hash({offset: 0, length: 64, destination: 0});

        bytes32 digest = MessageHashUtils.toTypedDataHash(bytes32(0), keccak256(abi.encode(bytes32(0), keccak256(""))));
        _manage(account, abi.encodeCall(IMerkleAccount.sign, (bytes32(0), buffer, plan)));
        assertTrue(IMerkleAccount(account).signatures(digest));
    }

    function test_RejectsEmptyPlanAndUndersizedBuffer() public {
        _expectPlanRejected(new bytes(64), new IMerkleAccount.Hash[](0));
        _expectPlanRejected(bytes(""), flatPlan(bytes("")));
        _expectPlanRejected(new bytes(31), flatPlan(new bytes(31)));
    }

    function testFuzz_RejectsOutOfBoundsSteps(uint256 offset, uint256 length, uint256 destination) public {
        uint256 size = 64;
        vm.assume(offset > size || length > size - (offset > size ? size : offset) || destination > size - 32);
        IMerkleAccount.Hash[] memory plan = new IMerkleAccount.Hash[](1);
        plan[0] = IMerkleAccount.Hash({offset: offset, length: length, destination: destination});
        _expectPlanRejected(new bytes(size), plan);
    }

    /// @dev The value a later step reads is the earlier step's result, not the original word.
    function test_LaterStepReadsEarlierResult() public {
        bytes memory buffer = abi.encode(uint256(1), uint256(2));
        IMerkleAccount.Hash[] memory plan = new IMerkleAccount.Hash[](2);
        plan[0] = IMerkleAccount.Hash({offset: 32, length: 32, destination: 32});
        plan[1] = IMerkleAccount.Hash({offset: 0, length: 64, destination: 0});

        bytes32 inner = keccak256(abi.encode(uint256(2)));
        bytes32 digest = MessageHashUtils.toTypedDataHash(bytes32(0), keccak256(abi.encode(uint256(1), inner)));
        _manage(account, abi.encodeCall(IMerkleAccount.sign, (bytes32(0), buffer, plan)));
        assertTrue(IMerkleAccount(account).signatures(digest));
    }

    /// forge-config: default.isolate = true
    function test_GasNestedHashAndEvent() public {
        bytes memory buffer = abi.encode(uint256(1), uint256(2));
        IMerkleAccount.Hash[] memory plan = new IMerkleAccount.Hash[](2);
        plan[0] = IMerkleAccount.Hash({offset: 32, length: 32, destination: 32});
        plan[1] = IMerkleAccount.Hash({offset: 0, length: 64, destination: 0});

        bytes32 inner = keccak256(abi.encode(uint256(2)));
        bytes32 structHash = keccak256(abi.encode(uint256(1), inner));
        bytes32 digest = MessageHashUtils.toTypedDataHash(bytes32(0), structHash);

        IMerkleAccount.Action[] memory actions =
            _publishCall(account, abi.encodeCall(IMerkleAccount.sign, (bytes32(0), buffer, plan)));
        // The log carries the buffer as supplied, so the digest can be recomputed from the event alone.
        vm.expectEmit(true, true, false, true, account);
        emit IMerkleAccount.Sign(digest, bytes32(0), buffer, plan);
        MerkleAccount(payable(account)).manage(actions);
        vm.snapshotGasLastCall("MerkleAccountHashing", "approveNested");
        assertTrue(IMerkleAccount(account).signatures(digest));
    }

    function _expectPlanRejected(bytes memory buffer, IMerkleAccount.Hash[] memory plan) internal {
        IMerkleAccount.Action[] memory actions =
            _publishCall(account, abi.encodeCall(IMerkleAccount.sign, (bytes32(0), buffer, plan)));
        vm.expectRevert(IMerkleAccount.InvalidHashPlan.selector);
        MerkleAccount(payable(account)).manage(actions);
    }
}
