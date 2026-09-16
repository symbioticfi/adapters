// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAccount} from "../IAccount.sol";

/**
 * @title ISpikoAccount
 * @notice Interface for Spiko ERC-1363 redemption accounts.
 */
interface ISpikoAccount is IAccount {
    /* ERRORS */

    /**
     * @notice Raised when the redemption manager does not create the expected pending request.
     */
    error InvalidRedemptionRequest();

    /**
     * @notice Raised when the locally tracked request has no valid manager state.
     */
    error InvalidRedemptionStatus();

    /**
     * @notice Raised when a canceled request does not refund its exact token amount.
     */
    error InvalidRefund();

    /**
     * @notice Raised when an ERC-1363 request returns false.
     */
    error RedemptionFailed();

    /* EVENTS */

    /**
     * @notice Emitted when SPKCC is submitted to Spiko.
     */
    event RequestRedeem(
        bytes32 indexed id,
        uint256 tokenAmount,
        uint256 assets,
        bytes32 salt,
        uint48 issuerDeadline,
        uint48 settlementExpiry
    );

    /**
     * @notice Emitted when newly arrived settlement reduces a receivable.
     */
    event ReconcileSettlement(bytes32 indexed id, uint256 assets, uint256 pendingAssets);

    /**
     * @notice Emitted when an issuer-expired request is canceled.
     */
    event CancelRedeem(bytes32 indexed id, uint256 tokenAmount);

    /**
     * @notice Emitted when a fully paid executed request is cleared.
     */
    event CompleteRedeem(bytes32 indexed id);

    /**
     * @notice Emitted when an executed request's unpaid residual expires.
     */
    event WriteOff(bytes32 indexed id, uint256 assets);

    /* FUNCTIONS */

    /**
     * @notice Returns Spiko's redemption manager.
     */
    function REDEMPTION() external view returns (address redemption);

    /**
     * @notice Returns the configured redemption settlement token.
     */
    function SETTLEMENT_TOKEN() external view returns (address settlementToken);

    /**
     * @notice Returns the protocol write-off duration.
     */
    function SETTLEMENT_DURATION() external view returns (uint48 settlementDuration);

    /**
     * @notice Returns the active request id, or zero when idle.
     */
    function pendingId() external view returns (bytes32 id);

    /**
     * @notice Returns the active request salt.
     */
    function pendingSalt() external view returns (bytes32 salt);

    /**
     * @notice Returns the SPKCC amount in the active request.
     */
    function pendingTokenAmount() external view returns (uint256 tokenAmount);

    /**
     * @notice Returns the unpaid frozen request value in vault assets.
     */
    function pendingAssets() external view returns (uint256 assets);

    /**
     * @notice Returns the protocol expiry of the active receivable.
     */
    function pendingExpiry() external view returns (uint48 expiry);

    /**
     * @notice Returns the last allocated request nonce.
     */
    function requestNonce() external view returns (uint256 nonce);

    /**
     * @notice Returns whether cancellation/write-off has halted permissionless retries.
     */
    function redemptionPaused() external view returns (bool paused);
}

/**
 * @title ISpikoAccountConstants
 * @notice Base contract defining constants for SpikoAccount.
 */
abstract contract ISpikoAccountConstants {
    /* CONSTANTS */

    /**
     * @dev Spiko's published maximum delay before a pending request becomes cancelable.
     */
    uint48 internal constant MAX_ISSUER_DELAY = 14 days;
}
