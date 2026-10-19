// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";

import {GPv2Order} from "src/libraries/GPv2Order.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Token} from "test/mocks/Token.sol";
import {flatPlan} from "test/helpers/HashPlan.sol";

contract MerkleSignatureApprovalTest is CapabilityTestBase {
    function setUp() public {
        _deployAdapter(address(new Token("asset")));
    }

    function testFuzz_ComputesCoWDigestWhenApproving(bytes32 domain, uint256 sellAmount, uint256 buyAmount) public {
        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(address(0x1234)),
            buyToken: IERC20(address(0x5678)),
            receiver: account,
            sellAmount: sellAmount,
            buyAmount: buyAmount,
            validTo: type(uint32).max,
            appData: bytes32(0),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
        bytes32 digest = GPv2Order.hash(order, domain);
        assertEq(IMerkleAccount(account).isValidSignature(digest, ""), bytes4(0xffffffff));
        _manage(
            account,
            abi.encodeCall(
                IMerkleAccount.sign,
                (domain, abi.encode(GPv2Order.TYPE_HASH, order), flatPlan(abi.encode(GPv2Order.TYPE_HASH, order)))
            )
        );
        assertEq(IMerkleAccount(account).isValidSignature(digest, ""), IERC1271.isValidSignature.selector);
        assertEq(IMerkleAccount(account).isValidSignature(bytes32(uint256(digest) ^ 1), ""), bytes4(0xffffffff));
    }

    function test_ComputesLiquidLaneSingleOutputDigestWhenApproving() public {
        bytes32 requestType = keccak256(
            "Request(address tokenIn,uint256 amountIn,Output[] outputs,uint256 deadline,uint256 nonce,address protocol)Output(address token,uint256 amount,address recipient)"
        );
        bytes32 outputType = keccak256("Output(address token,uint256 amount,address recipient)");
        bytes32 domain = keccak256("Reactor domain");
        bytes32 outputHash = keccak256(abi.encode(outputType, address(0x5678), uint256(95), account));
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                domain,
                keccak256(
                    abi.encode(
                        requestType,
                        address(0x1234),
                        uint256(100),
                        keccak256(abi.encode(outputHash)),
                        uint256(1000),
                        uint256(7),
                        address(0xbeef)
                    )
                )
            )
        );
        bytes memory signature = abi.encode(
            requestType,
            address(0x1234),
            uint256(100),
            keccak256(abi.encode(outputHash)),
            uint256(1000),
            uint256(7),
            address(0xbeef)
        );
        _manage(account, abi.encodeCall(IMerkleAccount.sign, (domain, signature, flatPlan(signature))));
        assertEq(IMerkleAccount(account).isValidSignature(digest, ""), IERC1271.isValidSignature.selector);
    }
}
