// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IExecutor} from "./IExecutor.sol";
import {ILiquidLaneAdapter} from "../ILiquidLaneAdapter.sol";
import {IMerkleAdapter} from "../IMerkleAdapter.sol";

/**
 * @title ILiquidLaneExecutor
 * @notice Interface for adapter-funded Liquid Lane discounts and RWA post-actions.
 */
interface ILiquidLaneExecutor is IExecutor {
    /* ERRORS */

    /**
     * @notice Raised when a discount nonce has been invalidated.
     */
    error AlreadyUsedNonce();

    /**
     * @notice Raised when the discount or protocol authorization has expired.
     */
    error ExpiredSwap();

    /**
     * @notice Raised when a discount signer is neither the owner nor the configured signer.
     */
    error InvalidAccount();

    /**
     * @notice Raised when the connector is bound to another adapter.
     */
    error InvalidAdapter();

    /**
     * @notice Raised when a discount is below its minimum or exceeds the ppm precision.
     */
    error InvalidDiscount();

    /**
     * @notice Raised when required post-actions are absent or disabled post-actions are supplied.
     */
    error InvalidPostActions();

    /**
     * @notice Raised when either discount signature is invalid.
     */
    error InvalidSignature();

    /**
     * @notice Raised when the connector's funding asset or discounted quote changes during preparation.
     */
    error OperationChanged();

    /**
     * @notice Raised when post-actions do not remove exactly the swapped RWA amount from the adapter.
     */
    error PostActionBalanceMismatch();

    /* EVENTS */

    /**
     * @notice Emitted when the owner replaces or disables the additional discount signer.
     */
    event SetSigner(address indexed signer);

    /**
     * @notice Emitted when the owner replaces the minimum discount for an RWA.
     */
    event SetMinDiscount(address indexed tokenToRedeem, uint256 discount);

    /**
     * @notice Emitted when an authorized account invalidates a reusable discount nonce.
     */
    event InvalidateNonce(address indexed tokenToRedeem, uint256 indexed nonce);

    /**
     * @notice Emitted when the owner replaces the permitted post-swap leaves for an RWA.
     */
    event SetPostActionLeaves(address indexed token, bytes32[] leaves);

    /**
     * @notice Emitted when the adapter funds a discounted swap and completes its post-actions.
     */
    event Swap(address indexed tokenIn, address indexed recipient, uint256 amountIn, uint256 amountOut);

    /* FUNCTIONS */

    /**
     * @notice Returns the permanently bound Liquid Lane connector.
     */
    function connector() external view returns (address);

    /**
     * @notice Returns the additional discount signer; zero disables this signer.
     */
    function signer() external view returns (address);

    /**
     * @notice Returns the minimum accepted discount in ppm for an RWA.
     */
    function minDiscount(address tokenToRedeem) external view returns (uint256);

    /**
     * @notice Returns whether a reusable discount nonce has been invalidated for an RWA.
     */
    function isUsedNonce(address tokenToRedeem, uint256 nonce) external view returns (bool);

    /**
     * @notice Sets or disables the additional signer alongside the owner.
     * @dev Owner-only; cannot change during execution.
     */
    function setSigner(address newSigner) external;

    /**
     * @notice Sets the minimum accepted discount for an RWA.
     * @dev Owner-only; cannot change during execution. The maximum is 1,000,000 ppm.
     */
    function setMinDiscount(address tokenToRedeem, uint256 newDiscount) external;

    /**
     * @notice Invalidates a reusable discount nonce for an RWA.
     * @dev Only the owner or configured signer may invalidate. Successful fills do not consume the nonce.
     */
    function invalidateNonce(address tokenToRedeem, uint256 nonce) external;

    /**
     * @notice Returns a permitted post-swap leaf for an RWA by index.
     */
    function postActionLeaves(address token, uint256 index) external view returns (bytes32);

    /**
     * @notice Returns the number of permitted post-swap leaves for an RWA.
     */
    function postActionLeavesLength(address token) external view returns (uint256);

    /**
     * @notice Replaces the permitted post-swap leaves for an RWA.
     * @dev Owner-only; cannot change during execution. A nonempty list requires post-actions;
     * an empty list prohibits them. Each action also needs a current Merkle proof and executor role.
     */
    function setPostActionLeaves(address token, bytes32[] calldata newLeaves) external;

    /**
     * @notice Funds a signed discounted swap and executes the RWA's permitted post-actions.
     * @dev Only the selected caller may execute. The discount signer must be the owner or configured signer,
     * and discount.protocol must countersign the wrapper. Both signatures use EIP-712 domain
     * LiquidLaneExecutor, version 1, with this executor as verifying contract; ERC-1271 is supported.
     * The connector's current oracle quote determines the discounted output. Approval and swap run
     * through the adapter, whose spend must equal the prepared amount. Post-actions may be a subset,
     * repetition, or reordering of allowed leaves, but their net RWA outflow must equal amountIn.
     * This protects earlier RWA holdings on a net basis; it does not validate redemption proceeds.
     * @param discountSwap Reusable discount and short-lived protocol authorization wrapper.
     * @param protocolSignature Protocol signature over discountSwap.
     * @param recipient Recipient of the funding-token output.
     * @param amountIn RWA amount already delivered to the connector.
     * @param execution Funding calls and current approval and swap proofs.
     * @param postActions Permitted RWA actions, executed after the swap.
     * @return amountOut Discounted funding-token amount paid to the recipient.
     */
    function swap(
        ILiquidLaneAdapter.DiscountSwap calldata discountSwap,
        bytes calldata protocolSignature,
        address recipient,
        uint256 amountIn,
        Execution calldata execution,
        IMerkleAdapter.Action[] calldata postActions
    ) external returns (uint256 amountOut);
}
