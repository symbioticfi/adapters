// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Capability} from "./Capability.sol";

import {
    DISCOUNT_PRECISION,
    DISCOUNT_SWAP_TYPEHASH,
    DISCOUNT_TYPEHASH,
    ILiquidLaneAdapter
} from "../../../interfaces/ILiquidLaneAdapter.sol";
import {ILiquidLaneCapability} from "../../../interfaces/merkle-adapter/capabilities/ILiquidLaneCapability.sol";
import {ILiquidLaneConnector} from "../../../interfaces/merkle-adapter/ILiquidLaneConnector.sol";

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title LiquidLaneCapability
/// @notice Contract for adapter-context Liquid Lane swaps with curator and protocol signed discounts.
contract LiquidLaneCapability layout at erc7201("symbiotic.storage.LiquidLaneCapability")
    is
    Capability,
    EIP712,
    ILiquidLaneCapability
{
    using Math for uint256;

    /* STATE VARIABLES */

    /// @inheritdoc ILiquidLaneCapability
    address public signer;

    /// @inheritdoc ILiquidLaneCapability
    mapping(address tokenToRedeem => mapping(uint256 nonce => bool invalidated)) public isUsedNonce;

    /* CONSTRUCTOR */

    /// @dev EIP712 rebuilds the domain with the adapter address when this code runs by delegatecall.
    constructor() EIP712("LiquidLaneCapability", "1") {}

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ILiquidLaneCapability
    function setLiquidLaneSigner(address newSigner) public onlyMyself {
        signer = newSigner;
        emit SetLiquidLaneSigner(newSigner);
    }

    /// @inheritdoc ILiquidLaneCapability
    function invalidateLiquidLaneNonce(address tokenToRedeem, uint256 nonce) public onlyMyself {
        isUsedNonce[tokenToRedeem][nonce] = true;
        emit InvalidateLiquidLaneNonce(tokenToRedeem, nonce);
    }

    /// @inheritdoc ILiquidLaneCapability
    function swapSigned(
        address connector,
        ILiquidLaneAdapter.DiscountSwap calldata discountSwap,
        bytes calldata protocolSignature,
        address recipient,
        uint256 amountIn,
        uint256 minDiscount
    ) public onlyMyself returns (uint256 amountOut) {
        {
            ILiquidLaneAdapter.Discount calldata discount = discountSwap.discount;
            if (discount.signer != OwnableUpgradeable(address(this)).owner() && discount.signer != signer) {
                revert InvalidAccount();
            }
            if (discount.deadline < block.timestamp || discountSwap.protocolDeadline < block.timestamp) {
                revert ExpiredSwap();
            }
            if (isUsedNonce[discount.tokenToRedeem][discount.nonce]) revert AlreadyUsedNonce();
            if (discount.discount < minDiscount || discount.discount > DISCOUNT_PRECISION) revert InvalidDiscount();

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
        if (ILiquidLaneConnector(connector).adapter() != address(this)) revert InvalidAdapter();

        amountOut = ILiquidLaneConnector(connector)
            .getAmountOut(discountSwap.discount.tokenToRedeem, amountIn)
            .mulDiv(DISCOUNT_PRECISION - discountSwap.discount.discount, DISCOUNT_PRECISION);
        ILiquidLaneConnector(connector)
            .swap(ILiquidLaneConnector.Swap(recipient, discountSwap.discount.tokenToRedeem, amountIn, amountOut));
        emit SwapSigned(connector, discountSwap.discount.tokenToRedeem, recipient, amountIn, amountOut);
    }
}
