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
     * @notice Raised when funds are moved by anyone other than the paired account.
     */
    error InvalidCaller();

    /* STRUCTS */

    /**
     * @notice Adapter-specific initialization parameters.
     * @param defaultAdminRoleHolder Initial holder of the account's `DEFAULT_ADMIN_ROLE`.
     */
    struct InitParams {
        address defaultAdminRoleHolder;
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
     * @notice Returns assets awaiting oracle accounting for an epoch.
     * @param nonce Oracle epoch nonce.
     * @return amount Pending assets in vault-asset units.
     */
    function pendingAllocation(uint256 nonce) external view returns (uint256);

    /**
     * @notice Returns assets requested for release after an oracle epoch.
     * @param nonce Oracle epoch nonce.
     * @return amount Requested assets in vault-asset units.
     */
    function toDeallocate(uint256 nonce) external view returns (uint256);

    /**
     * @notice Returns the last oracle epoch incorporated into deallocation accounting.
     * @return nonce Last synchronized oracle epoch nonce.
     */
    function lastSyncedNonce() external view returns (uint256);

    /**
     * @notice Returns idle assets reserved for deallocation as of the last synchronization.
     * @return amount Reserved assets in vault-asset units.
     */
    function deallocatable() external view returns (uint256);

    /**
     * @notice Returns vault assets reserved for pending allocations and matured withdrawals.
     * @dev Includes withdrawal requests matured at the current oracle epoch even before synchronization.
     * @return amount Reserved assets in vault-asset units.
     */
    function reservedAssets() external view returns (uint256 amount);

    /**
     * @notice Returns assets reserved at an accounting epoch, including pending allocations and matured withdrawals.
     * @dev Oracle uses the next epoch to validate a report before advancing its nonce.
     * @param nonce Accounting epoch at or after lastSyncedNonce.
     * @return amount Reserved assets in vault-asset units.
     */
    function reservedAssetsAt(uint256 nonce) external view returns (uint256 amount);

    /**
     * @notice Returns withdrawals matured at an accounting epoch, including unsynchronized requests.
     * @param nonce Accounting epoch at or after lastSyncedNonce.
     * @return amount Matured withdrawals in vault-asset units.
     */
    function deallocatableAt(uint256 nonce) external view returns (uint256 amount);
}
