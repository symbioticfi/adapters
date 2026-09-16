// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";

/**
 * @title ICoWSwapAction
 * @notice Interface for adapter-funded CoW Protocol sell orders with adapter-only authorization and recovery.
 */
interface ICoWSwapAction is IMigratableEntity {
    /* ERRORS */

    /**
     * @notice Raised when an order is already expired.
     */
    error ExpiredOrder();

    /**
     * @notice Raised when a migration changes the settlement or relayer used by existing orders.
     */
    error IncompatibleSettlement();

    /**
     * @notice Raised when the adapter address is zero or the action itself.
     */
    error InvalidAdapter();

    /**
     * @notice Raised when an order requests zero buy tokens.
     */
    error InvalidBuyAmount();

    /**
     * @notice Raised when the caller is not the bound adapter.
     */
    error InvalidCaller();

    /**
     * @notice Raised when migration data is unsupported.
     */
    error InvalidMigrationData();

    /**
     * @notice Raised when the sell amount is zero, unavailable, or not transferred exactly.
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
     * @notice Emitted when the action funds and pre-signs a sell order.
     * @param orderUid Canonical CoW order UID owned by the action.
     * @param tokenIn Sell token.
     * @param amountIn Maximum sell-token amount authorized for the order.
     * @param tokenOut Buy token, paid directly to the bound adapter.
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

    /**
     * @notice Emitted when unused tokens are returned to the bound adapter.
     * @param token Recovered ERC20 token.
     * @param amount Amount sent to the bound adapter.
     */
    event Recover(address indexed token, uint256 amount);

    /* FUNCTIONS */

    /**
     * @notice Returns the adapter permitted to authorize, cancel and recover orders.
     * @return newAdapter Bound adapter address.
     */
    function adapter() external view returns (address newAdapter);

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
     * @dev A filled or expired order remains tracked until replaced, canceled or recovered.
     * @param tokenIn Sell token.
     * @return orderUid Tracked CoW order UID.
     */
    function activeOrderUid(address tokenIn) external view returns (bytes memory orderUid);

    /**
     * @notice Pulls exact funding from the adapter and pre-signs a partially fillable, zero-fee sell order.
     * @dev Adapter-only. Replacing an order first revokes it and returns all unused sell tokens.
     * The adapter must approve this action for `amountIn`. Buy proceeds go directly to the adapter.
     * @param tokenIn ERC20 sell token.
     * @param amountIn Exact sell-token funding and order amount.
     * @param tokenOut ERC20 buy token.
     * @param params Minimum buy amount, expiry within 30 minutes, and app-data hash.
     * @return orderUid Canonical CoW order UID.
     */
    function convert(address tokenIn, uint256 amountIn, address tokenOut, OrderParams calldata params)
        external
        returns (bytes memory orderUid);

    /**
     * @notice Revokes the tracked order, retaining its allowance and unused tokens until recovery or replacement.
     * @dev Adapter-only; calls only the settlement so paused token operations cannot block cancellation.
     * Remaining allowance alone cannot execute the revoked order. Also succeeds when no order is tracked.
     * @param tokenIn Sell token whose tracked order is canceled.
     */
    function invalidateConvert(address tokenIn) external;

    /**
     * @notice Revokes any tracked order and approval for a token, then returns its entire balance to the adapter.
     * @dev Adapter-only; supports unfilled, partially filled, expired and accidentally received tokens.
     * If token operations are blocked, cancel separately with `invalidateConvert` before retrying recovery.
     * @param token ERC20 token to recover.
     * @return amount Token amount returned to the adapter.
     */
    function recover(address token) external returns (uint256 amount);
}
