// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IAdapter} from "./IAdapter.sol";

/**
 * @title IMerkleAdapter
 * @notice Interface for a vault adapter with immediate capital accounting and oracle-valued investments.
 * @dev Reported NAV includes lockedLiquidity() plus the account's assets, positions and claims, net of liabilities.
 * All values are read at the report's snapshot block. Untracked adapter cash is excluded from NAV and cannot be recovered.
 * Current NAV is oracle.totalAssets() - netFlowAt(oracle.snapshotBlock()) + netFlow(). Those oracle getters
 * and latestSnapshot() expose the previous report during the block in which a new report is accepted.
 * The oracle validates reported NAV; the adapter applies later flows
 * using checked signed arithmetic.
 * Vault transfers must use the delegator; internal portfolio transfers do not change net flow.
 * Allocations immediately forward the allocated amount to the paired account.
 * Collateral must transfer exact amounts without transfer fees, rebases or transfer callbacks.
 * Block numbers must be nonzero and fit uint48; cumulative staged amounts must fit uint208.
 */
interface IMerkleAdapter is IAdapter {
    /* ERRORS */

    /**
     * @notice Raised when the caller is not the paired account required by the operation.
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

    /* EVENTS */

    /**
     * @notice Emitted when the adapter creates its strategy account.
     */
    event SetAccount(address indexed account);

    /**
     * @notice Emitted when the adapter creates its accounting oracle.
     */
    event SetOracle(address indexed oracle);

    /**
     * @notice Emitted when underlying moves from the account to its adapter, without changing portfolio NAV.
     */
    event Pull(uint256 amount);

    /* FUNCTIONS */

    /**
     * @notice Returns the migratable factory used to create the strategy account.
     */
    function ACCOUNT_FACTORY() external view returns (address);

    /**
     * @notice Returns the migratable factory used to create the accounting oracle.
     */
    function ORACLE_FACTORY() external view returns (address);

    /**
     * @notice Returns the account holding the strategy's positions, approvals and signatures.
     */
    function account() external view returns (address);

    /**
     * @notice Returns the accounting oracle created for this adapter.
     */
    function oracle() external view returns (address);

    /**
     * @notice Returns immediately withdrawable cash covered by an accepted report.
     * @dev Includes staged liquidity covered by an accepted unsynced report from an earlier block, capped by current NAV.
     * Uncovered cash cannot be withdrawn immediately. Requests do not change liquidity accounting.
     */
    function freeAssets() external view returns (uint256);

    /**
     * @notice Pulls underlying from the paired account back into the adapter.
     * @dev Only the account may call. Internal transfers do not change net flow or recognize investment PnL.
     * Stages exactly amount at the current block, regardless of withdrawal requests.
     * Direct token transfers remain untracked, including after a zero-amount pull, and are excluded from reported NAV.
     * @param amount Underlying to return to this adapter.
     */
    function pull(uint256 amount) external;

    /**
     * @notice Returns the snapshot block last applied to withdrawal liquidity, or zero before synchronization.
     */
    function syncedSnapshotBlock() external view returns (uint48);

    /**
     * @notice Returns cash released by synchronized reports, minus completed returns and NAV caps.
     * @dev Released and staged liquidity remain cash-backed, so payouts need no additional balance cap.
     */
    function releasedLiquidity() external view returns (uint256);

    /**
     * @notice Returns staged cash not yet covered by a synchronized report.
     */
    function stagedLiquidity() external view returns (uint256);

    /**
     * @notice Returns released liquidity plus staged cash not yet covered by a synchronized report.
     * @dev The NAV producer uses this value at its snapshot block as the adapter's accounted cash.
     * Untracked donations and cash removed from release capacity by NAV caps are excluded.
     */
    function lockedLiquidity() external view returns (uint256);

    /**
     * @notice Returns cumulative cash staged at or before the given block, including cash already released or paid out.
     * @dev Zero before the first stage. Current and future blocks return the latest cumulative amount.
     * Synchronization releases the increase since syncedSnapshotBlock; earlier covered cash cannot be released twice.
     */
    function stagedLiquidityAt(uint48 snapshotBlock) external view returns (uint256);

    /**
     * @notice Returns cumulative completed vault allocations minus completed returns to the vault.
     * @dev Signed because realized profits can make lifetime returns exceed lifetime allocations.
     * Values are bounded to int208 to pack each checkpoint with its uint48 block number.
     */
    function netFlow() external view returns (int256);

    /**
     * @notice Returns the latest cumulative net flow recorded at or before the given block, or zero before the first flow.
     * @dev Multiple flows in one block overwrite that block's checkpoint. Current and future blocks return the latest flow.
     */
    function netFlowAt(uint48 snapshotBlock) external view returns (int256);
}
