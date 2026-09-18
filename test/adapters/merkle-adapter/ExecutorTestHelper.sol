// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {LiquidLaneExecutor} from "src/contracts/periphery/LiquidLaneExecutor.sol";

import {IExecutor} from "src/interfaces/periphery/IExecutor.sol";
import {ILiquidLaneAdapter, DISCOUNT_TYPEHASH, DISCOUNT_SWAP_TYPEHASH} from "src/interfaces/ILiquidLaneAdapter.sol";
import {ILiquidLaneConnector} from "src/interfaces/merkle-adapter/ILiquidLaneConnector.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @dev Real signed-entrypoint fixture. Only explicitly registered typed-data digests are valid.
abstract contract ExecutorTestHelper is IERC1271 {
    mapping(bytes32 => bool) internal _acceptedExecutorDigests;
    uint256 internal _executorTestNonce;

    function isValidSignature(bytes32 hash, bytes memory) public view returns (bytes4) {
        return _acceptedExecutorDigests[hash] ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }

    function _execution(IMerkleAdapter.Action[] memory calls)
        internal
        pure
        returns (IExecutor.Execution memory execution)
    {
        execution.actions = new IMerkleAdapter.Action[](calls.length - 2);
        for (uint256 i; i < execution.actions.length; ++i) {
            execution.actions[i] = calls[i];
        }
        execution.approval = IExecutor.Permission(calls[calls.length - 2].dataMask, calls[calls.length - 2].proof);
        execution.operation = IExecutor.Permission(calls[calls.length - 1].dataMask, calls[calls.length - 1].proof);
    }

    function _discountSwap(address executor, address token, uint256 discount)
        internal
        returns (ILiquidLaneAdapter.DiscountSwap memory quote)
    {
        quote.discount = ILiquidLaneAdapter.Discount(
            token, discount, address(this), address(this), _executorTestNonce++, type(uint48).max
        );
        quote.signerSignature = "";
        quote.protocolDeadline = type(uint48).max;
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("LiquidLaneExecutor"),
                keccak256("1"),
                block.chainid,
                executor
            )
        );
        bytes32 discountHash = keccak256(abi.encode(DISCOUNT_TYPEHASH, quote.discount));
        _acceptedExecutorDigests[keccak256(abi.encodePacked(hex"1901", domain, discountHash))] = true;
        bytes32 protocolHash = keccak256(
            abi.encode(DISCOUNT_SWAP_TYPEHASH, discountHash, keccak256(quote.signerSignature), quote.protocolDeadline)
        );
        _acceptedExecutorDigests[keccak256(abi.encodePacked(hex"1901", domain, protocolHash))] = true;
    }

    function _runLiquidLane(
        address executor,
        IMerkleAdapter.Action[] memory calls,
        IMerkleAdapter.Action[] memory posts,
        uint256 discount
    ) internal returns (uint256) {
        ILiquidLaneConnector.Swap memory swap =
            abi.decode(_arguments(calls[calls.length - 1].data), (ILiquidLaneConnector.Swap));
        return LiquidLaneExecutor(executor)
            .swap(
                _discountSwap(executor, swap.tokenIn, discount),
                "",
                swap.recipient,
                swap.amountIn,
                _execution(calls),
                posts
            );
    }

    function _liquidLaneCall(
        address executor,
        IMerkleAdapter.Action[] memory calls,
        IMerkleAdapter.Action[] memory posts,
        uint256 discount
    ) internal returns (bytes memory) {
        ILiquidLaneConnector.Swap memory swap =
            abi.decode(_arguments(calls[calls.length - 1].data), (ILiquidLaneConnector.Swap));
        return abi.encodeCall(
            LiquidLaneExecutor.swap,
            (
                _discountSwap(executor, swap.tokenIn, discount),
                bytes(""),
                swap.recipient,
                swap.amountIn,
                _execution(calls),
                posts
            )
        );
    }

    function _arguments(bytes memory data) internal pure returns (bytes memory arguments) {
        arguments = new bytes(data.length - 4);
        for (uint256 i; i < arguments.length; ++i) {
            arguments[i] = data[i + 4];
        }
    }
}
