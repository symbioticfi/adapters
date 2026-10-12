// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {AssetRateLimits} from "../libraries/AssetRateLimits.sol";

import {
    DISCOUNT_PRECISION,
    DISCOUNT_SWAP_TYPEHASH,
    DISCOUNT_TYPEHASH,
    ILiquidLaneConnector
} from "../../../interfaces/merkle-adapter/connectors/ILiquidLaneConnector.sol";
import {IOracleRegistry} from "../../../interfaces/merkle-adapter/connectors/IOracleRegistry.sol";
import {IOracle} from "../../../interfaces/ll-adapter/IOracle.sol";

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {IRegistry} from "@symbioticfi/core/src/interfaces/common/IRegistry.sol";
import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";

/// @title LiquidLaneConnector
/// @notice Contract for account-bound RWA inventory swaps with saved oracles and asset budgets.
contract LiquidLaneConnector is MigratableEntity, EIP712, ILiquidLaneConnector {
    using AssetRateLimits for AssetRateLimits.AssetLimit;
    using Math for uint256;
    using SafeERC20 for IERC20;

    /* IMMUTABLES */

    /// @inheritdoc ILiquidLaneConnector
    address public immutable MERKLE_ACCOUNT_FACTORY;

    /// @inheritdoc ILiquidLaneConnector
    address public immutable ORACLE_REGISTRY;

    /* STATE VARIABLES */

    /// @inheritdoc ILiquidLaneConnector
    address public account;

    /// @inheritdoc ILiquidLaneConnector
    mapping(address tokenToRedeem => address oracle) public oracles;

    /// @inheritdoc ILiquidLaneConnector
    address public outputAsset;

    /// @inheritdoc ILiquidLaneConnector
    mapping(address tokenToRedeem => AssetRateLimits.AssetLimit) public assetLimits;

    /// @inheritdoc ILiquidLaneConnector
    address public signer;

    /// @inheritdoc ILiquidLaneConnector
    mapping(address tokenToRedeem => uint256 discount) public minDiscount;

    /// @inheritdoc ILiquidLaneConnector
    mapping(address tokenToRedeem => mapping(uint256 nonce => bool invalidated)) public isUsedNonce;

    /* MODIFIERS */

    /// @dev Restricts a function to the bound account.
    modifier onlyAccount() {
        if (account != msg.sender) revert InvalidCaller();

        _;
    }

    /* CONSTRUCTOR */

    /// @dev Initializes the connector factory, Merkle account factory and oracle registry dependencies.
    constructor(address newFactory, address newMerkleAccountFactory, address newOracleRegistry)
        MigratableEntity(newFactory)
        EIP712("LiquidLaneConnector", "1")
    {
        MERKLE_ACCOUNT_FACTORY = newMerkleAccountFactory;
        ORACLE_REGISTRY = newOracleRegistry;
    }

    /* VIEW FUNCTIONS */

    /// @inheritdoc ILiquidLaneConnector
    function remainingAssets(address tokenToRedeem) public view returns (uint256) {
        return assetLimits[tokenToRedeem].remaining();
    }

    /// @inheritdoc ILiquidLaneConnector
    function getAmountOut(address tokenToRedeem, uint256 amountIn) public view returns (uint256) {
        address oracle = oracles[tokenToRedeem];
        if (oracle == address(0)) revert InvalidTokenToRedeem();

        return amountIn.mulDiv(
            IOracle(oracle).getPrice() * 10 ** IERC20Metadata(outputAsset).decimals(),
            1e18 * 10 ** IERC20Metadata(tokenToRedeem).decimals()
        );
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ILiquidLaneConnector
    function setSigner(address newSigner) public onlyOwner {
        signer = newSigner;
        emit SetSigner(newSigner);
    }

    /// @inheritdoc ILiquidLaneConnector
    function setMinDiscount(address tokenToRedeem, uint256 newMinDiscount) public onlyOwner {
        if (newMinDiscount > DISCOUNT_PRECISION) revert InvalidDiscount();

        minDiscount[tokenToRedeem] = newMinDiscount;
        emit SetMinDiscount(tokenToRedeem, newMinDiscount);
    }

    /// @inheritdoc ILiquidLaneConnector
    function invalidateNonce(address tokenToRedeem, uint256 nonce) public {
        if (owner() != msg.sender && signer != msg.sender) revert InvalidCaller();

        isUsedNonce[tokenToRedeem][nonce] = true;
        emit InvalidateNonce(tokenToRedeem, nonce);
    }

    /// @inheritdoc ILiquidLaneConnector
    function addTokenToRedeem(address tokenToRedeem) public onlyAccount {
        if (tokenToRedeem == address(0) || tokenToRedeem == outputAsset || oracles[tokenToRedeem] != address(0)) {
            revert InvalidTokenToRedeem();
        }

        address oracle = IOracleRegistry(ORACLE_REGISTRY).oracles(address(this), tokenToRedeem);
        if (oracle == address(0)) revert InvalidOracle();

        oracles[tokenToRedeem] = oracle;
        emit AddTokenToRedeem(tokenToRedeem, oracle);
    }

    /// @inheritdoc ILiquidLaneConnector
    function removeTokenToRedeem(address tokenToRedeem) public onlyAccount {
        if (oracles[tokenToRedeem] == address(0)) revert InvalidTokenToRedeem();

        delete oracles[tokenToRedeem];
        emit RemoveTokenToRedeem(tokenToRedeem);
    }

    /// @inheritdoc ILiquidLaneConnector
    function setMaxAssetsPerDuration(address tokenToRedeem, uint256 newMaxAssets, uint48 newDuration)
        public
        onlyAccount
    {
        assetLimits[tokenToRedeem].configure(newMaxAssets, newDuration);
        emit SetMaxAssetsPerDuration(tokenToRedeem, newMaxAssets, newDuration);
    }

    /// @inheritdoc ILiquidLaneConnector
    function swap(Swap calldata newSwap) public onlyAccount {
        _swap(newSwap);
    }

    /// @inheritdoc ILiquidLaneConnector
    function swap(
        DiscountSwap calldata discountSwap,
        bytes calldata protocolSignature,
        address recipient,
        uint256 amountIn
    ) public onlyAccount returns (uint256 amountOut) {
        Discount calldata discount = discountSwap.discount;
        if (discount.signer != owner() && discount.signer != signer) revert InvalidSigner();
        if (discount.deadline < block.timestamp || discountSwap.protocolDeadline < block.timestamp) {
            revert ExpiredSwap();
        }
        if (isUsedNonce[discount.tokenToRedeem][discount.nonce]) revert AlreadyUsedNonce();

        bytes32 discountHash = keccak256(abi.encode(DISCOUNT_TYPEHASH, discount));
        if (!SignatureChecker.isValidSignatureNowCalldata(
                discount.signer, _hashTypedDataV4(discountHash), discountSwap.signerSignature
            )) revert InvalidSignature();
        if (!SignatureChecker.isValidSignatureNowCalldata(
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

        amountOut = getAmountOut(discount.tokenToRedeem, amountIn) * (DISCOUNT_PRECISION - discount.discount)
            / DISCOUNT_PRECISION;
        _swap(Swap({recipient: recipient, tokenIn: discount.tokenToRedeem, amountIn: amountIn, amountOut: amountOut}));
    }

    /* INTERNAL FUNCTIONS */

    function _swap(Swap memory newSwap) internal {
        if (
            newSwap.amountOut
                > getAmountOut(newSwap.tokenIn, newSwap.amountIn) * (DISCOUNT_PRECISION - minDiscount[newSwap.tokenIn])
                    / DISCOUNT_PRECISION
        ) revert InvalidSwapRate();

        assetLimits[newSwap.tokenIn].consume(newSwap.amountOut);
        IERC20(newSwap.tokenIn).safeTransfer(msg.sender, newSwap.amountIn);
        IERC20(outputAsset).safeTransferFrom(msg.sender, newSwap.recipient, newSwap.amountOut);

        emit DoSwap(newSwap);
    }

    /* INITIALIZATION */

    /// @dev Binds the connector proxy to a registered Merkle account and funding asset.
    function _initialize(uint64, address, bytes memory data) internal override {
        (account, outputAsset) = abi.decode(data, (address, address));
        if (!IRegistry(MERKLE_ACCOUNT_FACTORY).isEntity(account)) revert InvalidAccount();
    }

    /* MIGRATION */

    /// @dev Migration is intentionally unsupported for this implementation.
    function _migrate(uint64, uint64, bytes calldata) internal pure override {
        revert();
    }
}
