// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {AssetRateLimits} from "../libraries/AssetRateLimits.sol";

import {
    DISCOUNT_PRECISION,
    DISCOUNT_SWAP_TYPEHASH,
    DISCOUNT_TYPEHASH,
    ILiquidLaneAdapter,
    SIGNED_SWAP_TYPEHASH
} from "../../../interfaces/ILiquidLaneAdapter.sol";
import {IAssetRateLimits} from "../../../interfaces/merkle-adapter/IAssetRateLimits.sol";
import {ILiquidLaneConnector} from "../../../interfaces/merkle-adapter/connectors/ILiquidLaneConnector.sol";
import {IOracleRegistry} from "../../../interfaces/merkle-adapter/oracle/IOracleRegistry.sol";
import {IOracle} from "../../../interfaces/ll-adapter/IOracle.sol";

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";

/// @title LiquidLaneConnector
/// @notice Contract for account-bound RWA inventory swaps with saved oracles and asset budgets.
contract LiquidLaneConnector is MigratableEntity, EIP712, ILiquidLaneConnector {
    using AssetRateLimits for AssetLimit;
    using SafeERC20 for IERC20;
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc ILiquidLaneConnector
    address public immutable ORACLE_REGISTRY;

    /* STATE VARIABLES */

    /// @inheritdoc ILiquidLaneConnector
    address public account;

    /// @inheritdoc ILiquidLaneConnector
    address[] public tokensToRedeem;

    /// @inheritdoc ILiquidLaneConnector
    mapping(address tokenToRedeem => address oracle) public oracles;

    /// @inheritdoc ILiquidLaneConnector
    address public inputAsset;

    /// @inheritdoc IAssetRateLimits
    mapping(address tokenToRedeem => AssetLimit) public assetLimits;

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

    /// @dev Initializes the immutable factory and oracle registry dependencies.
    constructor(address newFactory, address newOracleRegistry)
        MigratableEntity(newFactory)
        EIP712("LiquidLaneConnector", "1")
    {
        ORACLE_REGISTRY = newOracleRegistry;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ILiquidLaneConnector
    function setSigner(address newSigner) public nonReentrant onlyOwner {
        signer = newSigner;
        emit SetSigner(newSigner);
    }

    /// @inheritdoc ILiquidLaneConnector
    function setMinDiscount(address tokenToRedeem, uint256 newMinDiscount) public nonReentrant onlyOwner {
        if (newMinDiscount > DISCOUNT_PRECISION) revert InvalidDiscount();

        minDiscount[tokenToRedeem] = newMinDiscount;
        emit SetMinDiscount(tokenToRedeem, newMinDiscount);
    }

    /// @inheritdoc ILiquidLaneConnector
    function invalidateNonce(address tokenToRedeem, uint256 nonce) public nonReentrant {
        if (owner() != msg.sender && signer != msg.sender) revert InvalidCaller();

        isUsedNonce[tokenToRedeem][nonce] = true;
        emit InvalidateNonce(tokenToRedeem, nonce);
    }

    /// @inheritdoc ILiquidLaneConnector
    function addTokenToRedeem(address tokenToRedeem) public nonReentrant onlyAccount {
        _addTokenToRedeem(tokenToRedeem);
    }

    /// @inheritdoc ILiquidLaneConnector
    function removeTokenToRedeem(address tokenToRedeem) public nonReentrant onlyAccount {
        uint256 length = tokensToRedeem.length;
        for (uint256 i; i < length; ++i) {
            if (tokensToRedeem[i] == tokenToRedeem) {
                tokensToRedeem[i] = tokensToRedeem[length - 1];
                tokensToRedeem.pop();
                delete oracles[tokenToRedeem];

                emit RemoveTokenToRedeem(tokenToRedeem);
                return;
            }
        }
        revert InvalidTokenToRedeem();
    }

    /// @inheritdoc IAssetRateLimits
    function setMaxAssetsPerDuration(address tokenToRedeem, uint256 newMaxAssets, uint256 newDuration)
        public
        nonReentrant
        onlyAccount
    {
        if (oracles[tokenToRedeem] == address(0)) revert InvalidTokenToRedeem();

        assetLimits[tokenToRedeem].configure(newMaxAssets, newDuration);
        emit SetMaxAssetsPerDuration(tokenToRedeem, newMaxAssets, newDuration);
    }

    /// @inheritdoc IAssetRateLimits
    function remainingAssets(address tokenToRedeem) public view returns (uint256) {
        return assetLimits[tokenToRedeem].remaining();
    }

    /// @inheritdoc ILiquidLaneConnector
    function getTokensToRedeemLength() public view returns (uint256) {
        return tokensToRedeem.length;
    }

    /// @inheritdoc ILiquidLaneConnector
    function getAmountOut(address tokenToRedeem, uint256 amountIn) public view returns (uint256) {
        address oracle = oracles[tokenToRedeem];
        if (oracle == address(0)) revert InvalidTokenToRedeem();

        return amountIn.mulDiv(
            IOracle(oracle).getPrice() * 10 ** IERC20Metadata(inputAsset).decimals(),
            1e18 * 10 ** IERC20Metadata(tokenToRedeem).decimals()
        );
    }

    /// @inheritdoc ILiquidLaneConnector
    function swap(Swap calldata newSwap) public nonReentrant onlyAccount {
        if (newSwap.amountOut > getAmountOut(newSwap.tokenIn, newSwap.amountIn)) revert InvalidSwapRate();

        _swap(newSwap);
    }

    /// @inheritdoc ILiquidLaneConnector
    function swap(ILiquidLaneAdapter.SignedSwap calldata signedSwap, bytes calldata signature)
        public
        nonReentrant
        onlyAccount
    {
        if (signedSwap.signer != owner() && signedSwap.signer != signer) revert InvalidSigner();
        if (signedSwap.caller != msg.sender) revert InvalidCaller();
        if (signedSwap.deadline < block.timestamp) revert ExpiredSwap();
        if (isUsedNonce[signedSwap.tokenIn][signedSwap.nonce]) revert AlreadyUsedNonce();
        if (!SignatureChecker.isValidSignatureNowCalldata(
                signedSwap.signer, _hashTypedDataV4(keccak256(abi.encode(SIGNED_SWAP_TYPEHASH, signedSwap))), signature
            )) revert InvalidSignature();
        if (signedSwap.amountOut > getAmountOut(signedSwap.tokenIn, signedSwap.amountIn)) revert InvalidSwapRate();

        isUsedNonce[signedSwap.tokenIn][signedSwap.nonce] = true;
        _swap(
            Swap({
                recipient: signedSwap.recipient,
                tokenIn: signedSwap.tokenIn,
                amountIn: signedSwap.amountIn,
                amountOut: signedSwap.amountOut
            })
        );
    }

    /// @inheritdoc ILiquidLaneConnector
    function swap(
        ILiquidLaneAdapter.DiscountSwap calldata discountSwap,
        bytes calldata protocolSignature,
        address recipient,
        uint256 amountIn
    ) public nonReentrant onlyAccount returns (uint256 amountOut) {
        ILiquidLaneAdapter.Discount calldata discount = discountSwap.discount;
        if (discount.signer != owner() && discount.signer != signer) revert InvalidSigner();
        if (Math.min(discount.deadline, discountSwap.protocolDeadline) < block.timestamp) revert ExpiredSwap();
        if (isUsedNonce[discount.tokenToRedeem][discount.nonce]) revert AlreadyUsedNonce();
        if (discount.discount < minDiscount[discount.tokenToRedeem] || discount.discount > DISCOUNT_PRECISION) {
            revert InvalidDiscount();
        }

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

        amountOut = getAmountOut(discount.tokenToRedeem, amountIn)
            .mulDiv(DISCOUNT_PRECISION - discount.discount, DISCOUNT_PRECISION);
        _swap(Swap({recipient: recipient, tokenIn: discount.tokenToRedeem, amountIn: amountIn, amountOut: amountOut}));
    }

    /* INTERNAL FUNCTIONS */

    function _swap(Swap memory newSwap) internal {
        assetLimits[newSwap.tokenIn].consume(newSwap.amountOut);
        IERC20(newSwap.tokenIn).safeTransfer(account, newSwap.amountIn);
        IERC20(inputAsset).safeTransferFrom(account, newSwap.recipient, newSwap.amountOut);

        emit DoSwap(newSwap);
    }

    /// @dev Adds a token using the registry's current approval without resetting its budget.
    function _addTokenToRedeem(address tokenToRedeem) internal {
        if (tokenToRedeem == address(0) || tokenToRedeem == inputAsset || oracles[tokenToRedeem] != address(0)) {
            revert InvalidTokenToRedeem();
        }

        address oracle = IOracleRegistry(ORACLE_REGISTRY).oracles(address(this), tokenToRedeem);
        if (oracle == address(0)) revert InvalidOracle();

        oracles[tokenToRedeem] = oracle;
        tokensToRedeem.push(tokenToRedeem);

        emit AddTokenToRedeem(tokenToRedeem, oracle);
    }

    /// @dev Binds the connector proxy to its account and funding asset; the initial token list may be empty.
    function _initialize(uint64, address, bytes memory data) internal override {
        (address newAccount, address newInputAsset, address[] memory newTokensToRedeem) =
            abi.decode(data, (address, address, address[]));
        if (newAccount == address(0)) revert InvalidAccount();

        if (newInputAsset == address(0)) revert InvalidInputAsset();

        account = newAccount;
        inputAsset = newInputAsset;

        uint256 length = newTokensToRedeem.length;
        for (uint256 i; i < length; ++i) {
            _addTokenToRedeem(newTokensToRedeem[i]);
        }
    }

    /// @dev Allows state-preserving implementation upgrades without reconfiguration.
    function _migrate(uint64, uint64, bytes calldata data) internal pure override {
        if (data.length > 0) revert InvalidMigrationData();
    }
}
