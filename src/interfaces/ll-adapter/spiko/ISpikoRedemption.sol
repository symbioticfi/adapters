// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ISpikoRedemption
 * @notice Interface for Spiko's ERC-1363 redemption manager.
 */
interface ISpikoRedemption {
    /* STRUCTS */

    /**
     * @notice Redemption request lifecycle state.
     */
    enum Status {
        NULL,
        PENDING,
        EXECUTED,
        CANCELED
    }

    /* FUNCTIONS */

    /**
     * @notice Returns the authorized settlement outputs for an input token.
     * @param input The Spiko share token.
     * @return outputs Authorized fiat/stablecoin output identifiers.
     */
    function outputsFor(address input) external view returns (address[] memory outputs);

    /**
     * @notice Returns the minimum redeemable input amount.
     * @param input The Spiko share token.
     * @return amount Minimum token amount.
     */
    function minimum(address input) external view returns (uint256 amount);

    /**
     * @notice Returns the state and cancellation deadline of a request.
     * @param id The redemption request id.
     * @return status Current request status.
     * @return deadline Timestamp after which a pending request can be canceled.
     */
    function details(bytes32 id) external view returns (Status status, uint48 deadline);

    /**
     * @notice Cancels an issuer-expired request and returns its input tokens.
     */
    function cancelRedemption(address user, address input, address output, uint256 inputValue, bytes32 salt) external;
}
