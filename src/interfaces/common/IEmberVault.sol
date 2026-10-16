// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IEmberVault
 * @notice Native queued-exit interface for the reviewed Ethereum PPLUS vault v2.4.0.
 * @dev Standard ERC4626 withdraw/redeem revert. Requests escrow shares and the operator later pays the receiver.
 */
interface IEmberVault {
    /**
     * @notice An active native withdrawal request. Sequence numbers are identifiers, not queue indices.
     * @param owner Share owner and fee subject.
     * @param receiver Recipient of the eventual asset payment.
     * @param shares Shares escrowed in the vault.
     * @param estimatedWithdrawAmount Estimate when requested; not a fixed entitlement.
     * @param timestamp Request time in milliseconds.
     * @param sequenceNumber Globally assigned request identifier.
     */
    struct WithdrawalRequest {
        address owner;
        address receiver;
        uint256 shares;
        uint256 estimatedWithdrawAmount;
        uint256 timestamp;
        uint256 sequenceNumber;
    }

    /**
     * @notice Deposit assets and mint shares to the receiver, subject to native eligibility checks.
     * @param assets Asset atoms to transfer from the caller.
     * @param receiver Share recipient.
     * @return shares Shares minted.
     */
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /**
     * @notice Escrow the caller's shares for an asynchronous withdrawal.
     * @dev Requires share allowance to the vault itself. There is no user claim transaction.
     * @param shares Share atoms to escrow.
     * @param receiver Recipient of the eventual asset payment.
     * @return request Newly created request.
     */
    function redeemShares(uint256 shares, address receiver) external returns (WithdrawalRequest memory request);

    /**
     * @notice Convert a full share amount at the current native inverse rate.
     * @param shares Share atoms.
     * @return assets Gross asset atoms, rounded down.
     */
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /**
     * @notice Return the current minimum share request in share atoms.
     * @return shares Minimum request.
     */
    function minWithdrawableShares() external view returns (uint256 shares);

    /**
     * @notice Read the owner's aggregate escrow and active/cancelled request identifiers.
     * @param owner Share owner.
     * @return shares Aggregate pending shares.
     * @return pending Pending identifiers, not queue indices.
     * @return cancelled Identifiers marked for cancellation but not yet returned.
     */
    function getAccountState(address owner)
        external
        view
        returns (uint256 shares, uint256[] memory pending, uint256[] memory cancelled);
}
