// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IAdapter} from "./IAdapter.sol";

/**
 * @title IMerkleAdapter
 * @notice Interface for a vault adapter with immediate capital accounting and oracle-valued investments.
 * @dev The portfolio includes this adapter, its account, positions and claims, net of liabilities.
 * Vault transfers must use the delegator; internal portfolio transfers do not change net flow.
 * Collateral must transfer exact amounts without transfer fees, rebases or transfer callbacks.
 */
interface IMerkleAdapter is IAdapter {
    /* ERRORS */

    /**
     * @notice Raised when pushing underlying would consume requested, staged or released withdrawal cash.
     */
    error InsufficientIdleAssets();

    /**
     * @notice Raised when the caller is not the paired account or oracle required by the operation.
     */
    error InvalidCaller();

    /**
     * @notice Raised when a historical flow lookup targets a block that is not completed.
     */
    error InvalidSnapshotBlock();

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
     * @notice Emitted when a report updates the cash authorized for return to the vault.
     */
    event SettleReport(uint256 releasedLiquidity);

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
     * @notice Pushes available underlying to the paired account immediately.
     * @dev Only the account may call through approved actions. Outstanding demand, staged cash and released
     * cash are protected. A cancellation does not unlock an already staged or released batch for investment.
     * @param amount Underlying to transfer to the account.
     */
    function push(uint256 amount) external;

    /**
     * @notice Pulls underlying from the paired account back into the adapter.
     * @dev Only the account may call. Internal transfers do not change net flow or recognize investment PnL.
     * Automatically stages cash against outstanding demand if no batch is already waiting for a report.
     * @param amount Underlying to return to this adapter.
     */
    function pull(uint256 amount) external;

    /**
     * @notice Locks available cash against outstanding demand until a covering report is accepted.
     * @dev Permissionless. An existing batch's amount and block cannot be changed. Direct token and protocol
     * payments into the adapter must be staged before the valuation snapshot to be released by that report.
     * Later arrivals may wait one extra report; allocations, requests, pulls and report settlement stage automatically.
     */
    function stageLiquidity() external;

    /**
     * @notice Releases staged cash covered by an accepted snapshot, then stages any later arrivals.
     * @dev Only the oracle may call, after applying the valuation. Unfunded demand does not reject the report.
     * Released liquidity and outstanding demand are capped by current NAV to recognize losses.
     * @param snapshotBlock Accepted valuation block; must cover the staged batch to release it.
     * @param assets Accepted portfolio NAV adjusted for subsequent vault flows.
     */
    function settleReport(uint48 snapshotBlock, uint256 assets) external;

    /**
     * @notice Returns the cash authorized by accepted reports, minus completed returns to the vault.
     */
    function releasedLiquidity() external view returns (uint256);

    /**
     * @notice Returns the fixed cash batch waiting for a report that includes its staging block.
     */
    function stagedLiquidity() external view returns (uint256);

    /**
     * @notice Returns the pending batch's staging block, or zero when there is no staged cash.
     */
    function stagedBlock() external view returns (uint48);

    /**
     * @notice Returns cumulative completed vault allocations minus completed returns to the vault.
     * @dev Signed because realized profits can make lifetime returns exceed lifetime allocations.
     * Values are bounded to int208 to pack each checkpoint with its uint48 block number.
     */
    function netFlow() external view returns (int256);

    /**
     * @notice Returns cumulative net flow at the end of a completed block, or zero before the first flow.
     * @dev Multiple flows in one block overwrite that block's checkpoint. Current and future blocks revert.
     */
    function netFlowAt(uint48 snapshotBlock) external view returns (int256);

    /**
     * @notice Returns outstanding liquidity demand, excluding completed returns and capped by accepted NAV.
     * @dev The delegator replaces this cumulative request. Allocations do not match it or return cash before a report.
     */
    function pendingDeallocation() external view returns (uint256);

    /**
     * @notice Returns released underlying available for return, capped by live cash and accounted portfolio NAV.
     * @dev Returns zero without reading cash or NAV when no liquidity is released. Does not validate oracle
     * freshness or freeze state. The delegator validates NAV before committing transfers.
     */
    function deallocatable() external view returns (uint256);
}
