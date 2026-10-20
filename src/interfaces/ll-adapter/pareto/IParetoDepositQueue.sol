// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IParetoDepositQueue
 * @notice Owner-ledger and settlement getters for Pareto prefunded deposit queues.
 */
interface IParetoDepositQueue {
    /* FUNCTIONS */

    /**
     * @notice Returns an owner's queued deposit amount in underlying units.
     */
    function userDepositsEpochs(address account, uint256 epoch) external view returns (uint256 amount);

    /**
     * @notice Returns the fixed underlying price per 1e18 tranche units for a deposit epoch.
     */
    function epochPrice(uint256 epoch) external view returns (uint256 price);

    /**
     * @notice Returns deposit assets still awaiting processing for an epoch.
     */
    function epochPendingDeposits(uint256 epoch) external view returns (uint256 assets);

    /**
     * @notice Returns prefunded deposit assets still awaiting finalization for an epoch.
     */
    function epochPrefundedDeposits(uint256 epoch) external view returns (uint256 assets);
}
