// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IAdapter} from "./IAdapter.sol";

/**
 * @title IMerkleAdapter
 * @notice Interface for MerkleAdapter.
 */
interface IMerkleAdapter is IAdapter {
    /* ERRORS */

    /**
     * @notice Raised when pushing underlying would consume reserved idle assets.
     */
    error InsufficientIdleAssets();

    /**
     * @notice Raised when a caller is not the paired account or oracle required by the operation.
     */
    error InvalidCaller();

    /* STRUCTS */

    /**
     * @notice Adapter-specific initialization parameters.
     * @param oracleData Oracle-specific initialization data.
     * @param merkleAccountData Account-specific initialization data.
     * @dev Each child receives abi.encode(address(this), its initialization data).
     */
    struct InitParams {
        bytes oracleData;
        bytes merkleAccountData;
    }

    /**
     * @notice Net allocations or withdrawal requests awaiting a report.
     * @param allocation Pending deposits, excluded from accepted Oracle NAV.
     * @param deallocation Withdrawal request, capped by surviving NAV when the batch settles.
     */
    struct Batch {
        uint256 allocation;
        uint256 deallocation;
    }

    /* EVENTS */

    /**
     * @notice Emitted when the adapter creates its strategy account.
     * @param account Account that holds positions and executes approved calls.
     */
    event SetAccount(address indexed account);

    /**
     * @notice Emitted when underlying is pushed to the strategy account.
     * @param amount Underlying transferred to the account.
     */
    event Push(uint256 amount);

    /**
     * @notice Emitted when the adapter creates its accounting oracle.
     * @param oracle Address of the created oracle.
     */
    event SetOracle(address indexed oracle);

    /**
     * @notice Emitted when underlying is pulled back into the adapter.
     * @param amount Underlying transferred from the account.
     */
    event Pull(uint256 amount);

    /**
     * @notice Emitted when a report settles the current batch and promotes the next batch.
     * @param released Assets added to matured withdrawal reserves.
     */
    event SettleReport(uint256 released);

    /* FUNCTIONS */

    /**
     * @notice Returns the migratable factory used to create the strategy account.
     */
    function ACCOUNT_FACTORY() external view returns (address);

    /**
     * @notice Pulls underlying from the paired account back into vault custody.
     * @dev Only the account may call through its approved actions; initialization grants this adapter allowance.
     * @param amount Underlying to return to this adapter.
     */
    function pull(uint256 amount) external;

    /**
     * @notice Settles the current batch against NAV authenticated by the paired oracle.
     * @dev Only the oracle may call. Reverts if stored reserves overflow; rejects without mutation
     * if report NAV plus reserves overflows or reserves lack backing.
     * On acceptance, caps the withdrawal by NAV, reserves it and promotes the next batch.
     * @param assets Report NAV including current allocations and withdrawals about to mature.
     * @return accepted Whether reserve checks passed and the batch was settled.
     * @return remainingAssets Report NAV after reserving the newly matured withdrawal.
     */
    function settleReport(uint256 assets) external returns (bool accepted, uint256 remainingAssets);

    /**
     * @notice Returns the account holding the strategy's positions, approvals and signatures.
     * @return account_ Paired account, permanently bound at initialization.
     */
    function account() external view returns (address account_);

    /**
     * @notice Pushes unreserved underlying to the paired account.
     * @dev Only the account may call, normally through an approved manage action. The recipient is fixed.
     * Reverts atomically if the remaining balance cannot cover pending allocations and matured withdrawals.
     * @param amount Underlying to transfer to the account.
     */
    function push(uint256 amount) external;

    /**
     * @notice Returns the migratable factory used to create the accounting oracle.
     * @return factory Oracle factory address.
     */
    function ORACLE_FACTORY() external view returns (address);

    /**
     * @notice Returns the accounting oracle created for this adapter.
     * @return oracle_ Accounting oracle address.
     */
    function oracle() external view returns (address);

    /**
     * @notice Returns the batch consumed by the next accepted report.
     * @dev May be changed or matched only before oracle.cutoff().
     * @return allocation Pending allocations in vault-asset units.
     * @return deallocation Requested withdrawals in vault-asset units.
     */
    function currentBatch() external view returns (uint256 allocation, uint256 deallocation);

    /**
     * @notice Returns the batch collecting allocations and requests at or after oracle.cutoff().
     * @dev Promoted to currentBatch when the current report is accepted.
     * @return allocation Pending allocations in vault-asset units.
     * @return deallocation Requested withdrawals in vault-asset units.
     */
    function nextBatch() external view returns (uint256 allocation, uint256 deallocation);

    /**
     * @notice Returns idle assets reserved for immediate deallocation.
     * @return amount Reserved assets in vault-asset units.
     */
    function deallocatable() external view returns (uint256);

    /**
     * @notice Returns vault assets reserved for pending allocations and matured withdrawals.
     * @dev Sum of both batches' pending allocations and matured withdrawals.
     * @return amount Reserved assets in vault-asset units.
     */
    function reservedAssets() external view returns (uint256 amount);
}
