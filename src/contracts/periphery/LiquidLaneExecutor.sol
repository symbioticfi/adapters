// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Executor} from "./Executor.sol";

import {MerkleAdapterVerifier} from "../merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {
    DISCOUNT_PRECISION,
    DISCOUNT_SWAP_TYPEHASH,
    DISCOUNT_TYPEHASH,
    ILiquidLaneAdapter
} from "../../interfaces/ILiquidLaneAdapter.sol";
import {ILiquidLaneConnector} from "../../interfaces/merkle-adapter/ILiquidLaneConnector.sol";
import {ILiquidLaneExecutor} from "../../interfaces/periphery/ILiquidLaneExecutor.sol";
import {IMerkleAdapter} from "../../interfaces/IMerkleAdapter.sol";

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title LiquidLaneExecutor
/// @notice Contract for adapter-funded Liquid Lane discounts and RWA post-actions.
contract LiquidLaneExecutor is Executor, EIP712, ILiquidLaneExecutor {
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc ILiquidLaneExecutor
    address public immutable connector;

    /* STATE VARIABLES */

    /// @inheritdoc ILiquidLaneExecutor
    address public signer;

    /// @inheritdoc ILiquidLaneExecutor
    mapping(address tokenToRedeem => uint256 discount) public minDiscount;

    /// @inheritdoc ILiquidLaneExecutor
    mapping(address tokenToRedeem => mapping(uint256 nonce => bool used)) public isUsedNonce;

    /// @inheritdoc ILiquidLaneExecutor
    mapping(address token => bytes32[] leaves) public postActionLeaves;

    /* CONSTRUCTOR */

    constructor(address newOwner, address newAdapter, address newConnector)
        Executor(newOwner, newAdapter)
        EIP712("LiquidLaneExecutor", "1")
    {
        connector = newConnector;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ILiquidLaneExecutor
    function setSigner(address newSigner) public nonReentrant onlyOwner {
        signer = newSigner;
        emit SetSigner(newSigner);
    }

    /// @inheritdoc ILiquidLaneExecutor
    function setMinDiscount(address tokenToRedeem, uint256 newDiscount) public nonReentrant onlyOwner {
        if (newDiscount > DISCOUNT_PRECISION) revert InvalidDiscount();

        minDiscount[tokenToRedeem] = newDiscount;
        emit SetMinDiscount(tokenToRedeem, newDiscount);
    }

    /// @inheritdoc ILiquidLaneExecutor
    function invalidateNonce(address tokenToRedeem, uint256 nonce) public nonReentrant {
        if (owner() != msg.sender && signer != msg.sender) revert InvalidCaller();

        isUsedNonce[tokenToRedeem][nonce] = true;
        emit InvalidateNonce(tokenToRedeem, nonce);
    }

    /// @inheritdoc ILiquidLaneExecutor
    function setPostActionLeaves(address token, bytes32[] calldata newLeaves) public nonReentrant onlyOwner {
        postActionLeaves[token] = newLeaves;
        emit SetPostActionLeaves(token, newLeaves);
    }

    /// @inheritdoc ILiquidLaneExecutor
    function postActionLeavesLength(address token) public view returns (uint256) {
        return postActionLeaves[token].length;
    }

    /// @inheritdoc ILiquidLaneExecutor
    function swap(
        ILiquidLaneAdapter.DiscountSwap calldata discountSwap,
        bytes calldata protocolSignature,
        address recipient,
        uint256 amountIn,
        Execution calldata execution,
        IMerkleAdapter.Action[] calldata postActions
    ) public nonReentrant onlyCaller returns (uint256 amountOut) {
        ILiquidLaneAdapter.Discount calldata discount = discountSwap.discount;
        _validateDiscount(discountSwap, protocolSignature);

        if (ILiquidLaneConnector(connector).adapter() != adapter) revert InvalidAdapter();
        address asset = ILiquidLaneConnector(connector).inputAsset();
        amountOut = ILiquidLaneConnector(connector)
            .getAmountOut(discount.tokenToRedeem, amountIn)
            .mulDiv(DISCOUNT_PRECISION - discount.discount, DISCOUNT_PRECISION);
        _prepareLiquidity(asset, amountOut, connector, execution);
        if (
            ILiquidLaneConnector(connector).inputAsset() != asset
                || ILiquidLaneConnector(connector)
                        .getAmountOut(discount.tokenToRedeem, amountIn)
                        .mulDiv(DISCOUNT_PRECISION - discount.discount, DISCOUNT_PRECISION) != amountOut
        ) revert OperationChanged();

        uint256 balance = IERC20(asset).balanceOf(adapter);
        _call(
            connector,
            abi.encodeCall(
                ILiquidLaneConnector.swap,
                (ILiquidLaneConnector.Swap(recipient, discount.tokenToRedeem, amountIn, amountOut))
            ),
            execution.operation,
            operationLeaf
        );
        if (IERC20(asset).balanceOf(adapter) != balance - amountOut) revert OperationBalanceMismatch();

        bytes32[] storage leaves = postActionLeaves[discount.tokenToRedeem];
        uint256 length = leaves.length;
        if ((length > 0) != (postActions.length > 0)) revert InvalidPostActions();
        if (length > 0) {
            for (uint256 i; i < postActions.length; ++i) {
                IMerkleAdapter.Action calldata action = postActions[i];
                bytes32 leaf = MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask);
                uint256 j;
                for (; j < length; ++j) {
                    if (leaves[j] == leaf) break;
                }
                if (j == length) revert InvalidAction();
            }
            balance = IERC20(discount.tokenToRedeem).balanceOf(adapter);
            IMerkleAdapter(adapter).manage(postActions);
            uint256 afterBalance = IERC20(discount.tokenToRedeem).balanceOf(adapter);
            if (afterBalance > balance || balance - afterBalance != amountIn) revert PostActionBalanceMismatch();
        }

        emit Swap(discount.tokenToRedeem, recipient, amountIn, amountOut);
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Splits signature validation to keep the typed swap entrypoint within the non-IR stack limit.
    function _validateDiscount(ILiquidLaneAdapter.DiscountSwap calldata discountSwap, bytes calldata protocolSignature)
        internal
        view
    {
        ILiquidLaneAdapter.Discount calldata discount = discountSwap.discount;
        if (discount.signer != owner() && discount.signer != signer) revert InvalidAccount();
        if (discount.deadline < block.timestamp) revert ExpiredSwap();
        if (discountSwap.protocolDeadline < block.timestamp) revert ExpiredSwap();
        if (isUsedNonce[discount.tokenToRedeem][discount.nonce]) revert AlreadyUsedNonce();
        if (discount.discount < minDiscount[discount.tokenToRedeem]) revert InvalidDiscount();
        if (discount.discount > DISCOUNT_PRECISION) revert InvalidDiscount();

        bytes32 discountHash = keccak256(abi.encode(DISCOUNT_TYPEHASH, discount));
        if (!SignatureChecker.isValidSignatureNow(
                discount.signer, _hashTypedDataV4(discountHash), discountSwap.signerSignature
            )) revert InvalidSignature();
        if (!SignatureChecker.isValidSignatureNow(
                discount.protocol,
                _hashTypedDataV4(
                    keccak256(
                        abi.encode(
                            DISCOUNT_SWAP_TYPEHASH,
                            discountHash,
                            keccak256(discountSwap.signerSignature),
                            discountSwap.protocolDeadline
                        )
                    )
                ),
                protocolSignature
            )) revert InvalidSignature();
    }
}
