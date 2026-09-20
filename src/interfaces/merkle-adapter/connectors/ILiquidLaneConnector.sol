// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IAssetRateLimits} from "../IAssetRateLimits.sol";
import {ILiquidLaneAdapter} from "../../ILiquidLaneAdapter.sol";

import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";

/**
 * @title ILiquidLaneConnector
 * @notice Interface for Merkle-authorized Liquid Lane configuration and pricing.
 */
interface ILiquidLaneConnector is IMigratableEntity, IAssetRateLimits, IERC5267 {
    /* ERRORS */

    /**
     * @notice Raised when the token's nonce has been consumed or invalidated.
     */
    error AlreadyUsedNonce();

    /**
     * @notice Raised when a signed swap or either signed discount deadline has elapsed.
     */
    error ExpiredSwap();

    /**
     * @notice Raised when the configured account is zero.
     */
    error InvalidAccount();

    /**
     * @notice Raised when the caller is unauthorized or differs from the signed caller.
     */
    error InvalidCaller();

    /**
     * @notice Raised when the discount exceeds precision or falls below the owner's minimum.
     */
    error InvalidDiscount();

    /**
     * @notice Raised when the configured input asset is zero.
     */
    error InvalidInputAsset();

    /**
     * @notice Raised when migration data is not supported by this implementation.
     */
    error InvalidMigrationData();

    /**
     * @notice Raised when an RWA token has no oracle approved for this connector.
     */
    error InvalidOracle();

    /**
     * @notice Raised when a swap, discount, or protocol countersignature is invalid.
     */
    error InvalidSignature();

    /**
     * @notice Raised when the signer is neither the current owner nor the configured signer.
     */
    error InvalidSigner();

    /**
     * @notice Raised when the requested input-asset amount exceeds the oracle quote.
     */
    error InvalidSwapRate();

    /**
     * @notice Raised when an RWA token is not valid for the requested operation.
     */
    error InvalidTokenToRedeem();

    /* STRUCTS */

    /**
     * @notice Direct RWA inventory swap payload.
     * @param recipient Recipient of the input-asset output.
     * @param tokenIn RWA token used to price the swap.
     * @param amountIn RWA amount used to price the swap.
     * @param amountOut Input-asset amount transferred to the recipient.
     */
    struct Swap {
        address recipient;
        address tokenIn;
        uint256 amountIn;
        uint256 amountOut;
    }

    /* EVENTS */

    /**
     * @notice Emitted when input assets are exchanged against available RWA inventory.
     * @param newSwap Executed swap payload.
     */
    event DoSwap(Swap newSwap);

    /**
     * @notice Emitted when an RWA token is added with the currently approved oracle.
     */
    event AddTokenToRedeem(address indexed tokenToRedeem, address indexed oracle);

    /**
     * @notice Emitted when an RWA token and its saved oracle are removed.
     */
    event RemoveTokenToRedeem(address indexed tokenToRedeem);

    /**
     * @notice Emitted when the owner replaces the additional swap and discount signer.
     */
    event SetSigner(address indexed signer);

    /**
     * @notice Emitted when the owner changes the minimum discount for an RWA.
     */
    event SetMinDiscount(address indexed tokenToRedeem, uint256 minDiscount);

    /**
     * @notice Emitted when the owner or signer invalidates an RWA swap or discount nonce.
     */
    event InvalidateNonce(address indexed tokenToRedeem, uint256 nonce);

    /* FUNCTIONS */

    /**
     * @notice Returns the additional authorized swap and discount signer; zero disables this signer.
     */
    function signer() external view returns (address);

    /**
     * @notice Returns the owner's minimum signed discount for an RWA, in millionths.
     */
    function minDiscount(address tokenToRedeem) external view returns (uint256);

    /**
     * @notice Returns whether an RWA nonce has been consumed or invalidated.
     * @dev SignedSwap consumes its nonce; DiscountSwap remains reusable until invalidated.
     */
    function isUsedNonce(address tokenToRedeem, uint256 nonce) external view returns (bool);

    /**
     * @notice Replaces the additional swap and discount signer; only the owner may call this.
     * @param newSigner Additional signer or zero to disable it.
     */
    function setSigner(address newSigner) external;

    /**
     * @notice Sets an RWA's minimum signed discount; only the owner may call this.
     * @param tokenToRedeem RWA token.
     * @param newMinDiscount Minimum discount in millionths, at most 1,000,000.
     */
    function setMinDiscount(address tokenToRedeem, uint256 newMinDiscount) external;

    /**
     * @notice Invalidates an RWA swap or discount nonce; only the owner or current signer may call this.
     * @param tokenToRedeem RWA token.
     * @param nonce Nonce to permanently invalidate, including after signer changes.
     */
    function invalidateNonce(address tokenToRedeem, uint256 nonce) external;

    /**
     * @notice Returns the only account authorized to use this connector.
     * @return newAccount Account address.
     */
    function account() external view returns (address newAccount);

    /**
     * @notice Returns the token paid by the account during swaps.
     * @return asset Input asset address.
     */
    function inputAsset() external view returns (address asset);

    /**
     * @notice Returns the registry used to resolve approved oracles.
     * @return oracleRegistry Oracle registry address.
     */
    function ORACLE_REGISTRY() external view returns (address oracleRegistry);

    /**
     * @notice Returns a configured RWA token by index. Removal may change token order.
     * @param index Token index.
     * @return tokenToRedeem RWA token address.
     */
    function tokensToRedeem(uint256 index) external view returns (address tokenToRedeem);

    /**
     * @notice Returns the oracle saved when an RWA token was added.
     * @param tokenToRedeem RWA token address.
     * @return oracle Oracle address.
     */
    function oracles(address tokenToRedeem) external view returns (address oracle);

    /**
     * @notice Returns the number of configured RWA tokens.
     * @return count Number of configured RWA tokens.
     */
    function getTokensToRedeemLength() external view returns (uint256 count);

    /**
     * @notice Returns an RWA amount quoted in the input asset using its oracle.
     * @param tokenToRedeem RWA token address.
     * @param amountIn RWA token amount.
     * @return amountOut Input-asset amount.
     */
    function getAmountOut(address tokenToRedeem, uint256 amountIn) external view returns (uint256 amountOut);

    /**
     * @notice Adds an RWA token and saves OracleRegistry.oracles(address(this), tokenToRedeem).
     * @dev Only the bound account may call this. A nonzero approval is required; duplicates revert.
     * @param tokenToRedeem RWA token address.
     */
    function addTokenToRedeem(address tokenToRedeem) external;

    /**
     * @notice Removes an RWA token and deletes its saved oracle.
     * @dev Only the bound account may call this. Budget configuration and usage remain intact.
     * @param tokenToRedeem Configured RWA token address.
     */
    function removeTokenToRedeem(address tokenToRedeem) external;

    /**
     * @notice Transfers input assets from the account to a recipient against available RWA inventory.
     * @param newSwap Swap payload.
     */
    function swap(Swap calldata newSwap) external;

    /**
     * @notice Executes an exact swap signed by the current owner or configured signer.
     * @dev Only the bound account may call this and must match signedSwap.caller. Uses the
     * LiquidLaneAccount SignedSwap type with the LiquidLaneConnector EIP-712 domain.
     * Enforces the oracle quote and token budget, and consumes the token-scoped nonce.
     * @param signedSwap Exact recipient, token, amounts, caller, signer, nonce, and deadline.
     * @param signature EOA or ERC-1271 signature over signedSwap.
     */
    function swap(ILiquidLaneAdapter.SignedSwap calldata signedSwap, bytes calldata signature) external;

    /**
     * @notice Swaps RWA inventory using an owner or signer discount countersigned by its protocol.
     * @dev Only the bound account may call this. Both signatures use the connector proxy's
     * LiquidLaneConnector version 1 EIP-712 domain. Merkle permissions must bind the recipient and
     * token; the reusable discount signs neither the recipient nor the fill amount.
     * @param discountSwap Discount, signer signature, and protocol deadline.
     * @param protocolSignature Protocol's signature over the complete DiscountSwap.
     * @param recipient Recipient of the account's input assets, constrained by its approved leaf.
     * @param amountIn RWA inventory amount delivered to the account.
     * @return amountOut Discounted oracle value paid in the input asset.
     */
    function swap(
        ILiquidLaneAdapter.DiscountSwap calldata discountSwap,
        bytes calldata protocolSignature,
        address recipient,
        uint256 amountIn
    ) external returns (uint256 amountOut);
}
