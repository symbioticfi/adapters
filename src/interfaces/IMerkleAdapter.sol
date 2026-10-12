// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IAdapter} from "./IAdapter.sol";

/**
 * @title IMerkleAdapter
 * @notice Interface for a vault adapter with immediate capital accounting and oracle-valued investments.
 * @dev The portfolio includes this adapter, its account, positions and claims, net of liabilities.
 * Current NAV is reportedAssets - netFlowAt(snapshotBlock) + netFlow(); oracle.latestSnapshot() returns the
 * snapshot block and NAV after validating freshness. The oracle validates reported NAV; the adapter applies later flows
 * using checked signed arithmetic.
 * Vault transfers must use the delegator; internal portfolio transfers do not change net flow.
 * Collateral must transfer exact amounts without transfer fees, rebases or transfer callbacks.
 * Block numbers must be nonzero and fit uint48; cumulative staged amounts must fit uint208.
 */
interface IMerkleAdapter is IAdapter {
    /* ERRORS */

    /**
     * @notice Raised when pushing underlying would consume requested, staged or released withdrawal cash.
     */
    error InsufficientIdleAssets();

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
     * @notice Emitted when underlying moves from the adapter to its account, without changing portfolio NAV.
     */
    event Push(uint256 amount);

    /**
     * @notice Emitted when underlying moves from the account to its adapter, without changing portfolio NAV.
     */
    event Pull(uint256 amount);

    /**
     * @notice Emitted when requested cash is locked until a report covers this block.
     */
    event StageLiquidity(uint256 amount, uint48 indexed stagedBlock);

    /**
     * @notice Emitted when an accepted report is synchronized to update withdrawal liquidity.
     * @param snapshotBlock Snapshot applied to the adapter.
     * @param releasedLiquidity Cash authorized for return to the vault after synchronization.
     */
    event SyncReport(uint48 indexed snapshotBlock, uint256 releasedLiquidity);

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
     * @notice Returns immediately withdrawable cash covered by a fresh accepted report.
     * @dev Includes staged liquidity newly covered by an accepted unsynced report, capped by physical cash and
     * current NAV. Uncovered cash remains available for investment and staging, but cannot be withdrawn immediately.
     */
    function freeAssets() external view override returns (uint256);

    /**
     * @notice Pushes available underlying to the paired account immediately.
     * @dev Only the account may call through approved actions. Outstanding demand, staged cash and released
     * cash are protected. A cancellation does not unlock an already staged or released batch for investment.
     * @param amount Underlying to transfer to the account.
     */
    function push(uint256 amount) external;

    /**
     * @notice Pulls underlying from the paired account back into the adapter.
     * @dev Only the account may call. Internal transfers do not change net flow or recognize investment PnL.
     * Automatically stages additional cash against outstanding demand at the current block.
     * @param amount Underlying to return to this adapter.
     */
    function pull(uint256 amount) external;

    /**
     * @notice Applies the latest accepted report to withdrawal liquidity and stages any later cash.
     * @dev Anyone may call. A newer snapshot requires fresh NAV, releases covered staged cash and caps
     * released liquidity and pending demand by current NAV. Each snapshot is applied once.
     */
    function syncReport() external;

    /**
     * @notice Stages available cash against outstanding withdrawal demand until a report covers its block.
     * @dev Anyone may call, including while NAV is stale. Records additional eligible cash in cumulative
     * block checkpoints without changing earlier blocks. Multiple arrivals in one block share a checkpoint.
     */
    function stageLiquidity() external;

    /**
     * @notice Returns the snapshot block last applied to withdrawal liquidity, or zero before synchronization.
     */
    function syncedSnapshotBlock() external view returns (uint48);

    /**
     * @notice Returns cash released by synchronized reports, minus completed returns to the vault.
     * @dev Released and staged liquidity remain cash-backed, so payouts need no additional balance cap.
     */
    function releasedLiquidity() external view returns (uint256);

    /**
     * @notice Returns staged cash not yet covered by a synchronized report.
     */
    function stagedLiquidity() external view returns (uint256);

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

    /**
     * @notice Returns outstanding liquidity demand, excluding completed returns and capped when reports synchronize.
     * @dev The delegator replaces this cumulative request. Allocations do not match it or return cash before a report.
     */
    function pendingDeallocation() external view returns (uint256);
}
