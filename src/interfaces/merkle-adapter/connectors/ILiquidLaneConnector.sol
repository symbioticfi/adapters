// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";

/**
 * @dev Precision for discount ratios; 1e8 represents 100%.
 */
uint256 constant DISCOUNT_PRECISION = 1e8;

/**
 * @dev EIP-712 typehash for reusable signed discount policies.
 */
bytes32 constant DISCOUNT_TYPEHASH = keccak256(
    "Discount(address tokenToRedeem,uint256 discount,address signer,address protocol,uint256 nonce,uint48 deadline)"
);

/**
 * @dev EIP-712 typehash for protocol-wrapped discount swaps.
 */
bytes32 constant DISCOUNT_SWAP_TYPEHASH = keccak256(
    "DiscountSwap(Discount discount,bytes signerSignature,uint48 protocolDeadline)"
    "Discount(address tokenToRedeem,uint256 discount,address signer,address protocol,uint256 nonce,uint48 deadline)"
);

/**
 * @title ILiquidLaneConnector
 * @notice Interface for Merkle-authorized Liquid Lane configuration and pricing.
 */
interface ILiquidLaneConnector is IMigratableEntity, IERC5267 {
    /* ERRORS */

    /**
     * @notice Raised when the token's discount nonce has been invalidated.
     */
    error AlreadyUsedNonce();

    /**
     * @notice Raised when either signed discount deadline has elapsed.
     */
    error ExpiredSwap();

    /**
     * @notice Raised when the configured account is not registered in the Merkle account factory.
     */
    error InvalidAccount();

    /**
     * @notice Raised when the caller is unauthorized.
     */
    error InvalidCaller();

    /**
     * @notice Raised when the configured minimum discount exceeds precision.
     */
    error InvalidDiscount();

    /**
     * @notice Raised when an RWA token's approved oracle is zero or differs from the reviewed oracle.
     */
    error InvalidOracle();

    /**
     * @notice Raised when a discount signature or protocol countersignature is invalid.
     */
    error InvalidSignature();

    /**
     * @notice Raised when the signer is neither the current owner nor the configured signer.
     */
    error InvalidSigner();

    /**
     * @notice Raised when the requested output asset amount exceeds the minimum-discount oracle payment ceiling.
     */
    error InvalidSwapRate();

    /**
     * @notice Raised when an RWA token is not valid for the requested operation.
     */
    error InvalidTokenToRedeem();

    /* STRUCTS */

    /**
     * @notice Direct RWA inventory swap payload.
     * @param recipient Recipient of the output asset.
     * @param tokenIn RWA token used to price the swap.
     * @param amountIn RWA amount used to price the swap.
     * @param amountOut Output asset amount transferred to the recipient.
     */
    struct Swap {
        address recipient;
        address tokenIn;
        uint256 amountIn;
        uint256 amountOut;
    }

    /**
     * @notice Reusable signed discount policy for one RWA token.
     * @param tokenToRedeem RWA token delivered to the account.
     * @param discount Discount from the oracle quote, scaled by DISCOUNT_PRECISION (1e8 = 100%).
     * @param signer Current owner or configured signer that authorizes the discount.
     * @param protocol EOA that countersigns the discount swap.
     * @param nonce Token-scoped nonce that remains reusable until invalidated.
     * @param deadline Discount expiry timestamp.
     */
    struct Discount {
        address tokenToRedeem;
        uint256 discount;
        address signer;
        address protocol;
        uint256 nonce;
        uint48 deadline;
    }

    /**
     * @notice Protocol-authorized wrapper for a reusable discount.
     * @param discount Reusable signed discount policy.
     * @param signerSignature EOA or ERC-1271 signature over the Discount.
     * @param protocolDeadline Protocol countersignature expiry timestamp.
     */
    struct DiscountSwap {
        Discount discount;
        bytes signerSignature;
        uint48 protocolDeadline;
    }

    /* EVENTS */

    /**
     * @notice Emitted when the account changes an RWA token's budget in output asset base units.
     */
    event SetMaxAssetsPerDuration(address indexed tokenToRedeem, uint256 maxAssets, uint48 duration);

    /**
     * @notice Emitted when output assets are exchanged against available RWA inventory.
     * @dev Named DoSwap to avoid colliding with the Swap payload struct.
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
     * @notice Emitted when the account replaces the additional discount signer.
     */
    event SetSigner(address indexed signer);

    /**
     * @notice Emitted when the account changes the minimum discount for an RWA.
     */
    event SetMinDiscount(address indexed tokenToRedeem, uint256 minDiscount);

    /**
     * @notice Emitted when the owner or signer invalidates an RWA discount nonce.
     */
    event InvalidateNonce(address indexed tokenToRedeem, uint256 nonce);

    /* FUNCTIONS */

    /**
     * @notice Returns an RWA token's budget and last recorded usage; expired usage is reset lazily.
     * @dev Use remainingAssets to obtain the current spendable budget.
     * @param tokenToRedeem RWA token whose budget is queried.
     * @return maxAssets Output asset base units allowed in each period.
     * @return duration Period length in seconds.
     * @return periodStart Start of the last recorded period.
     * @return spent Output asset base units consumed in that period.
     */
    function assetLimits(address tokenToRedeem)
        external
        view
        returns (uint256 maxAssets, uint48 duration, uint48 periodStart, uint256 spent);

    /**
     * @notice Returns the current spendable budget in output asset base units; zero if disabled or unconfigured.
     */
    function remainingAssets(address tokenToRedeem) external view returns (uint256 assets);

    /**
     * @notice Sets an RWA token's budget; only the bound account may call and duration must be nonzero.
     * @dev Reconfiguration preserves usage in an active period. Changing duration starts a new period
     * at the current timestamp and carries that usage forward until the new duration expires.
     * A shorter duration can refresh the budget before the old period ends. Zero maxAssets disables spending
     * without erasing usage. Unused capacity never carries into another period.
     * Authorizing Merkle leaves must pin the token, maximum and duration; reserve their roles for configuration actors.
     * @param tokenToRedeem RWA token whose budget is changed, whether or not its oracle is configured.
     * @param newMaxAssets Output asset base units allowed in each period; zero disables spending.
     * @param newDuration Period length in seconds.
     */
    function setMaxAssetsPerDuration(address tokenToRedeem, uint256 newMaxAssets, uint48 newDuration) external;

    /**
     * @notice Returns the additional authorized discount signer; zero disables this signer.
     */
    function signer() external view returns (address);

    /**
     * @notice Returns the account's minimum discount for an RWA, scaled by DISCOUNT_PRECISION (1e8 = 100%).
     */
    function minDiscount(address tokenToRedeem) external view returns (uint256);

    /**
     * @notice Returns whether an RWA discount nonce has been invalidated.
     * @dev A discount remains reusable until expiry or nonce invalidation.
     */
    function isUsedNonce(address tokenToRedeem, uint256 nonce) external view returns (bool);

    /**
     * @notice Replaces the additional discount signer; only the bound account may call this.
     * @param newSigner Additional signer or zero to disable it.
     */
    function setSigner(address newSigner) external;

    /**
     * @notice Sets an RWA's minimum discount for both swap paths; only the bound account may call this.
     * @dev Enforced as an oracle-derived payment ceiling, rounded down in output asset units.
     * @param tokenToRedeem RWA token.
     * @param newMinDiscount Minimum discount scaled by DISCOUNT_PRECISION, at most 1e8 (100%).
     */
    function setMinDiscount(address tokenToRedeem, uint256 newMinDiscount) external;

    /**
     * @notice Invalidates an RWA discount nonce; only the owner or current signer may call this.
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
     * @return asset Output asset address.
     */
    function outputAsset() external view returns (address asset);

    /**
     * @notice Returns the factory whose registered accounts may initialize this connector.
     * @return merkleAccountFactory Merkle account factory address.
     */
    function MERKLE_ACCOUNT_FACTORY() external view returns (address merkleAccountFactory);

    /**
     * @notice Returns the registry used to resolve approved oracles.
     * @return oracleRegistry Oracle registry address.
     */
    function ORACLE_REGISTRY() external view returns (address oracleRegistry);

    /**
     * @notice Returns the saved oracle, or zero when the RWA token is not configured.
     * @dev Discover configured tokens from AddTokenToRedeem and RemoveTokenToRedeem events.
     * @param tokenToRedeem RWA token address.
     * @return oracle Oracle address.
     */
    function oracles(address tokenToRedeem) external view returns (address oracle);

    /**
     * @notice Returns an RWA amount quoted in the output asset using its oracle.
     * @dev The reviewed oracle must return conservative realizable outputAsset units per whole RWA token,
     * scaled by 1e18, including denomination conversion, exit fees/haircuts and freshness checks.
     * The connector converts token decimals only; it does not enforce issuer liquidity or redemption eligibility.
     * @param tokenToRedeem RWA token address.
     * @param amountIn RWA token amount.
     * @return amountOut Output asset amount.
     */
    function getAmountOut(address tokenToRedeem, uint256 amountIn) external view returns (uint256 amountOut);

    /**
     * @notice Adds an RWA token and saves OracleRegistry.oracles(address(this), tokenToRedeem).
     * @dev Only the bound account may call this. A nonzero approval is required; duplicates revert.
     * Authorizing Merkle leaves must pin expectedOracle to the reviewed registry value.
     * @param tokenToRedeem RWA token address.
     * @param expectedOracle Reviewed oracle address; installation reverts if the registry value differs.
     */
    function addTokenToRedeem(address tokenToRedeem, address expectedOracle) external;

    /**
     * @notice Removes an RWA token and deletes its saved oracle.
     * @dev Only the bound account may call this. Budget configuration and usage remain intact.
     * @param tokenToRedeem Configured RWA token address.
     */
    function removeTokenToRedeem(address tokenToRedeem) external;

    /**
     * @notice Transfers output assets from the account to a recipient against available RWA inventory.
     * @dev The payout must not exceed the oracle quote after applying the account's minimum discount.
     * Inventory has no supplier ownership ledger. External supplier delivery must occur in an atomic
     * settlement that binds the supplier recipient and verifies its actual payment, reverting delivery on failure.
     * A price ceiling alone permits zero payment; separately delivered inventory is not supplier escrow.
     * @param newSwap Swap payload.
     */
    function swap(Swap calldata newSwap) external;

    /**
     * @notice Swaps RWA inventory using an owner or signer discount countersigned by its protocol.
     * @dev Only the bound account may call this. Both signatures use the connector proxy's
     * LiquidLaneConnector version 1 EIP-712 domain. The reusable discount signs neither the recipient
     * nor the fill amount; the connector bounds only the price it pays.
     * External supplier delivery must use atomic settlement binding the supplier recipient and checking
     * its actual payment, with delivery reverted on failure. Inventory is not supplier escrow.
     * @param discountSwap Discount, signer signature, and protocol deadline.
     * @param protocolSignature Protocol EOA's 65-byte signature over the complete DiscountSwap.
     * @param recipient Recipient of the account's output assets for this fill.
     * @param amountIn RWA inventory amount delivered to the account.
     * @return amountOut Discounted oracle value paid in the output asset.
     */
    function swap(
        DiscountSwap calldata discountSwap,
        bytes calldata protocolSignature,
        address recipient,
        uint256 amountIn
    ) external returns (uint256 amountOut);
}
