// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICapability} from "./ICapability.sol";

/**
 * @title ICoWSwapCapability
 * @notice Interface for adapter-owned CoW Protocol sell orders authorized through adapter self-calls.
 */
interface ICoWSwapCapability is ICapability {
    /* ERRORS */

    /**
     * @notice Raised when an order is already expired.
     */
    error ExpiredOrder();

    /**
     * @notice Raised when an order requests zero buy tokens.
     */
    error InvalidBuyAmount();

    /**
     * @notice Raised when the sell amount is zero or exceeds the adapter's balance.
     */
    error InvalidSellAmount();

    /**
     * @notice Raised when a token is zero, has no code, or both order tokens are the same.
     */
    error InvalidToken();

    /**
     * @notice Raised when an order expires more than 30 minutes after authorization.
     */
    error TooFarValidTo();

    /* STRUCTS */

    /**
     * @notice The price floor, expiration and metadata hash of a partially fillable sell order.
     * @param buyAmount Minimum buy-token amount for the entire sell amount.
     * @param validTo Last timestamp at which CoW Protocol can execute the order.
     * @param appData CoW Protocol app-data hash.
     */
    struct OrderParams {
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
    }

    /* EVENTS */

    /**
     * @notice Emitted when the adapter pre-signs a sell order.
     * @param orderUid Canonical CoW order UID owned by the adapter.
     * @param tokenIn Sell token.
     * @param amountIn Maximum sell-token amount authorized for the order.
     * @param tokenOut Buy token, paid directly to the adapter.
     * @param params Order price floor, expiry and app-data hash.
     */
    event Convert(
        bytes orderUid, address indexed tokenIn, uint256 amountIn, address indexed tokenOut, OrderParams params
    );

    /**
     * @notice Emitted when a tracked pre-signature is revoked.
     * @param tokenIn Sell token for the revoked order.
     * @param orderUid Revoked CoW order UID.
     */
    event InvalidateConvert(address indexed tokenIn, bytes orderUid);

    /* FUNCTIONS */

    /**
     * @notice Returns the CoW Protocol settlement used to pre-sign orders.
     * @return settlement Settlement address.
     */
    function COW_SWAP_SETTLEMENT() external view returns (address settlement);

    /**
     * @notice Returns the settlement's relayer permitted to pull sell tokens.
     * @return relayer Vault relayer address.
     */
    function COW_SWAP_VAULT_RELAYER() external view returns (address relayer);

    /**
     * @notice Returns the latest tracked order UID for a sell token, or empty bytes when cleared.
     * @dev A filled or expired order remains tracked until replaced or canceled.
     * @param tokenIn Sell token.
     * @return orderUid Tracked CoW order UID.
     */
    function activeOrderUid(address tokenIn) external view returns (bytes memory orderUid);

    /**
     * @notice Pre-signs a partially fillable, zero-fee sell order owned by the adapter.
     * @dev Requires an adapter self-call. Funds stay on the adapter until settlement, and buy proceeds
     * return directly to it. Replacing an order first revokes its original pre-signature.
     * The curator manages relayer approvals through separate token calls. Authorization and cancellation
     * do not change balances or allowances. Asynchronous settlement is outside manage's balance checks.
     * @param tokenIn ERC20 sell token.
     * @param amountIn Maximum sell-token amount authorized for the order.
     * @param tokenOut ERC20 buy token.
     * @param params Minimum buy amount, expiry within 30 minutes, and app-data hash.
     * @return orderUid Canonical CoW order UID.
     */
    function convert(address tokenIn, uint256 amountIn, address tokenOut, OrderParams calldata params)
        external
        returns (bytes memory orderUid);

    /**
     * @notice Revokes the tracked order at its original settlement without changing balances or allowances.
     * @dev Requires an adapter self-call. Cancellation works while tokens are paused and after capability
     * replacement. Relayer allowance changes require a separate curator-authorized token approval.
     * @param tokenIn Sell token whose tracked order is canceled.
     */
    function invalidateConvert(address tokenIn) external;
}
