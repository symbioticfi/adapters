// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";

import {EIP712SignatureValidator} from "src/contracts/merkle-adapter/signature-validators/EIP712SignatureValidator.sol";

import {GPv2Order} from "src/libraries/GPv2Order.sol";

import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Token} from "test/mocks/Token.sol";

contract EIP712SignatureValidatorTest is CapabilityTestBase {
    address internal validator;
    bytes32 internal domain = keccak256("test settlement domain");

    function setUp() public {
        _deployAdapter(address(new Token("asset")));
        validator = address(new EIP712SignatureValidator());
    }

    function testFuzz_ValidPreimage(bytes32 domainSeparator, bytes memory encodedStruct) public view {
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator, keccak256(encodedStruct)));
        assertEq(
            IERC1271(validator).isValidSignature(digest, abi.encode(domainSeparator, encodedStruct)),
            IERC1271.isValidSignature.selector
        );
        assertEq(
            IERC1271(validator)
                .isValidSignature(bytes32(uint256(digest) ^ 1), abi.encode(domainSeparator, encodedStruct)),
            bytes4(0xffffffff)
        );
    }

    function testFuzz_AuthorizationMustBeStoredForTheExactPayload(bytes memory encodedStruct) public {
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domain, keccak256(encodedStruct)));
        bytes memory signature = abi.encode(validator, abi.encode(domain, encodedStruct));
        assertEq(adapter.isValidSignature(digest, signature), bytes4(0xffffffff));
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (digest, signature)));
        assertEq(adapter.isValidSignature(digest, signature), IERC1271.isValidSignature.selector);
        assertEq(adapter.isValidSignature(digest, bytes.concat(signature, hex"00")), bytes4(0xffffffff));
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (digest, bytes(""))));
        assertEq(adapter.isValidSignature(digest, signature), bytes4(0xffffffff));
    }

    function test_MalformedPayloadIsInvalidThroughAdapter() public {
        bytes memory signature = abi.encode(validator, hex"1234");
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (domain, signature)));
        assertEq(adapter.isValidSignature(domain, signature), bytes4(0xffffffff));
        vm.expectRevert();
        IERC1271(validator).isValidSignature(domain, hex"1234");
    }

    function testFuzz_CoWHashMatchesUpstream(uint256 sellAmount, uint256 buyAmount, uint32 validTo, bytes32 appData)
        public
        view
    {
        GPv2Order.Data memory order = _order(sellAmount, buyAmount, validTo, appData);
        assertEq(
            IERC1271(validator)
                .isValidSignature(
                    GPv2Order.hash(order, domain), abi.encode(domain, abi.encode(GPv2Order.TYPE_HASH, order))
                ),
            IERC1271.isValidSignature.selector
        );
    }

    function testFuzz_CoWLeafAllowsOnlySelectedOrderWords(uint256 sellAmount, uint256 buyAmount, uint32 validTo)
        public
    {
        bytes memory data = _authorization(_order(0, 0, 0, bytes32(0)));
        bytes memory mask = new bytes(data.length);
        uint256[5] memory free = [uint256(0), 13, 14, 15, 16];
        for (uint256 i; i < free.length; ++i) {
            for (uint256 j; j < 32; ++j) {
                mask[4 + free[i] * 32 + j] = 0xff;
            }
        }
        // uint32 validTo keeps its high 28 bytes fixed.
        for (uint256 i; i < 28; ++i) {
            mask[4 + 15 * 32 + i] = 0;
        }
        bytes32 leaf = _leaf(data, mask);
        roots.setRoot(address(adapter), leaf);
        adapter.acceptRoot(leaf);
        adapter.grantRole(leaf, address(this));
        GPv2Order.Data memory order = _order(sellAmount, buyAmount, validTo, keccak256("app data"));
        bytes memory approved = _authorization(order);
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](1);
        actions[0] = IMerkleAdapter.Action(address(adapter), 0, approved, mask, new bytes32[](0));
        adapter.manage(actions);
        bytes32 digest = GPv2Order.hash(order, domain);
        assertEq(adapter.isValidSignature(digest, adapter.signatures(digest)), IERC1271.isValidSignature.selector);

        // Every fixed byte, including pointers, lengths, type/domain, pair, receiver, kind,
        // fee and balances, remains part of the exact permission.
        for (uint256 i; i < approved.length; ++i) {
            if (mask[i] == 0xff) continue;
            approved[i] ^= 0x01;
            assertTrue(_leaf(approved, mask) != leaf);
            approved[i] ^= 0x01;
        }

        order.buyToken = IERC20(address(0xbad));
        actions[0].data = _authorization(order);
        vm.expectRevert();
        adapter.manage(actions);
        // Supplying a different mask cannot free the fixed output token.
        actions[0].dataMask = new bytes(actions[0].data.length);
        for (uint256 i; i < actions[0].dataMask.length; ++i) {
            actions[0].dataMask[i] = 0xff;
        }
        vm.expectRevert();
        adapter.manage(actions);
    }

    /// forge-config: default.isolate = true
    function test_GasValidSignature() public {
        bytes memory signature = abi.encode(domain, abi.encode(bytes32(uint256(1))));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domain, keccak256(abi.encode(bytes32(uint256(1))))));
        IERC1271(validator).isValidSignature(digest, signature);
        vm.snapshotGasLastCall("EIP712SignatureValidator", "validSignature");
    }

    /// forge-config: default.isolate = true
    function test_GasInvalidSignature() public {
        IERC1271(validator).isValidSignature(bytes32(0), abi.encode(domain, bytes("")));
        vm.snapshotGasLastCall("EIP712SignatureValidator", "invalidSignature");
    }

    function _order(uint256 sellAmount, uint256 buyAmount, uint32 validTo, bytes32 appData)
        internal
        view
        returns (GPv2Order.Data memory)
    {
        return GPv2Order.Data({
            sellToken: IERC20(address(0x1234)),
            buyToken: IERC20(address(0x5678)),
            receiver: address(adapter),
            sellAmount: sellAmount,
            buyAmount: buyAmount,
            validTo: validTo,
            appData: appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    function _authorization(GPv2Order.Data memory order) internal view returns (bytes memory) {
        return abi.encodeCall(
            IMerkleAdapter.setSignature,
            (
                GPv2Order.hash(order, domain),
                abi.encode(validator, abi.encode(domain, abi.encode(GPv2Order.TYPE_HASH, order)))
            )
        );
    }

    function _leaf(bytes memory data, bytes memory mask) internal view returns (bytes32) {
        bytes memory masked = new bytes(data.length);
        for (uint256 i; i < data.length; ++i) {
            masked[i] = data[i] & ~mask[i];
        }
        return
            keccak256(
                bytes.concat(keccak256(abi.encode(address(adapter), bytes1(0), keccak256(mask), keccak256(masked))))
            );
    }
}
