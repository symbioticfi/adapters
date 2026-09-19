// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {ICapability} from "./ICapability.sol";
import {ILiquidLaneAdapter} from "../../ILiquidLaneAdapter.sol";

import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";

/**
 * @title ILiquidLaneCapability
 * @notice Interface for Merkle-authorized Liquid Lane swaps with reusable signed discounts.
 */
interface ILiquidLaneCapability is ICapability, IERC5267 {
    /* ERRORS */

    /**
     * @notice Raised when a reusable discount nonce has been invalidated.
     */
    error AlreadyUsedNonce();

    /**
     * @notice Raised when either the discount or protocol authorization has expired.
     */
    error ExpiredSwap();

    /**
     * @notice Raised when the discount signer is neither the adapter owner nor the configured signer.
     */
    error InvalidAccount();

    /**
     * @notice Raised when the connector is bound to another adapter.
     */
    error InvalidAdapter();

    /**
     * @notice Raised when the signed discount is below the leaf's floor or exceeds 1,000,000 ppm.
     */
    error InvalidDiscount();

    /**
     * @notice Raised when the curator/signer or protocol signature is invalid.
     */
    error InvalidSignature();

    /* EVENTS */

    /**
     * @notice Emitted when an authorized leaf replaces or disables the additional discount signer.
     */
    event SetLiquidLaneSigner(address indexed signer);

    /**
     * @notice Emitted when an authorized leaf invalidates a reusable discount nonce.
     */
    event InvalidateLiquidLaneNonce(address indexed tokenToRedeem, uint256 indexed nonce);

    /**
     * @notice Emitted when a signed discounted swap from the adapter to its bound connector completes.
     */
    event SwapSigned(
        address indexed connector,
        address indexed tokenToRedeem,
        address indexed recipient,
        uint256 amountIn,
        uint256 amountOut
    );

    /* FUNCTIONS */

    /**
     * @notice Returns the additional discount signer; zero disables this signer.
     */
    function signer() external view returns (address);

    /**
     * @notice Returns whether a reusable discount nonce has been invalidated for an RWA.
     */
    function isUsedNonce(address tokenToRedeem, uint256 nonce) external view returns (bool);

    /**
     * @notice Replaces or disables the additional signer alongside the current adapter owner.
     * @dev Requires a Merkle-authorized adapter self-call.
     */
    function setLiquidLaneSigner(address newSigner) external;

    /**
     * @notice Invalidates a reusable discount nonce for an RWA.
     * @dev Requires a Merkle-authorized adapter self-call. Successful swaps do not consume the nonce.
     */
    function invalidateLiquidLaneNonce(address tokenToRedeem, uint256 nonce) external;

    /**
     * @notice Executes a Merkle-authorized swap using a curator/signer discount and protocol countersignature.
     * @dev Both signatures use EIP-712 domain LiquidLaneCapability, version 1, with the adapter as
     * verifying contract. EOA and ERC-1271 signatures are supported. The signed policy does not bind
     * connector, recipient, amountIn or minDiscount; the approved leaf must pin the connector, RWA,
     * recipient and minimum discount, and the caller's recipe bounds amounts and checks outcomes.
     * The adapter must separately approve its connector. This capability does not prepare liquidity,
     * redeem received RWAs or clear allowances. The connector enforces its own oracle and asset budget.
     * @param connector Connector bound to this adapter.
     * @param discountSwap Reusable signed discount and expiring protocol authorization wrapper.
     * @param protocolSignature Protocol countersignature over discountSwap.
     * @param recipient Recipient of the funding-token payment.
     * @param amountIn RWA quantity received from connector inventory.
     * @param minDiscount Minimum discount in ppm committed in the approved leaf.
     * @return amountOut Funding-token payment calculated from the live quote and signed discount.
     */
    function swapSigned(
        address connector,
        ILiquidLaneAdapter.DiscountSwap calldata discountSwap,
        bytes calldata protocolSignature,
        address recipient,
        uint256 amountIn,
        uint256 minDiscount
    ) external returns (uint256 amountOut);
}
