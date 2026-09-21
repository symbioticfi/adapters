// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";

import {GPv2Order} from "src/libraries/GPv2Order.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Token} from "test/mocks/Token.sol";

contract MerkleAdapterCoWSignaturesTest is CapabilityTestBase {
    bytes32 internal domain = keccak256("test settlement domain");

    function setUp() public {
        _deployAdapter(address(new Token("asset")));
    }

    function testFuzz_CoWLeafAllowsOnlySelectedOrderWords(uint256 sellAmount, uint256 buyAmount, uint32 validTo)
        public
    {
        bytes memory data = _authorization(_order(0, 0, 0, bytes32(0)));
        bytes memory mask = new bytes(data.length);
        uint256[4] memory free = [uint256(8), 9, 10, 11];
        for (uint256 i; i < free.length; ++i) {
            for (uint256 j; j < 32; ++j) {
                mask[4 + free[i] * 32 + j] = 0xff;
            }
        }
        // uint32 validTo keeps its high 28 bytes fixed.
        for (uint256 i; i < 28; ++i) {
            mask[4 + 10 * 32 + i] = 0;
        }
        bytes32 leaf = _leaf(data, mask);
        roots.setRoot(account, leaf);
        MerkleAccount(payable(account)).acceptRoot(leaf);
        MerkleAccount(payable(account)).grantRole(leaf, address(this));
        GPv2Order.Data memory order = _order(sellAmount, buyAmount, validTo, keccak256("app data"));
        bytes memory approved = _authorization(order);
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] =
            IMerkleAccount.Action({target: account, value: 0, data: approved, dataMask: mask, proof: new bytes32[](0)});
        MerkleAccount(payable(account)).manage(actions);
        bytes32 digest = GPv2Order.hash(order, domain);
        assertEq(IMerkleAccount(account).isValidSignature(digest, bytes("")), IERC1271.isValidSignature.selector);

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
        MerkleAccount(payable(account)).manage(actions);
        // Supplying a different mask cannot free the fixed output token.
        actions[0].dataMask = new bytes(actions[0].data.length);
        for (uint256 i; i < actions[0].dataMask.length; ++i) {
            actions[0].dataMask[i] = 0xff;
        }
        vm.expectRevert();
        MerkleAccount(payable(account)).manage(actions);
    }

    function _order(uint256 sellAmount, uint256 buyAmount, uint32 validTo, bytes32 appData)
        internal
        view
        returns (GPv2Order.Data memory)
    {
        return GPv2Order.Data({
            sellToken: IERC20(address(0x1234)),
            buyToken: IERC20(address(0x5678)),
            receiver: account,
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
            IMerkleAccount.setSignature, (domain, abi.encode(GPv2Order.TYPE_HASH, order), new IMerkleAccount.Hash[](0))
        );
    }

    function _leaf(bytes memory data, bytes memory mask) internal view returns (bytes32) {
        bytes memory masked = new bytes(data.length);
        for (uint256 i; i < data.length; ++i) {
            masked[i] = data[i] & ~mask[i];
        }
        return keccak256(bytes.concat(keccak256(abi.encode(account, bytes1(0), keccak256(mask), keccak256(masked)))));
    }
}
