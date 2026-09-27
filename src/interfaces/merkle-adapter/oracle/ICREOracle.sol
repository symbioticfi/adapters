// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {ICREOracleBase} from "./ICREOracleBase.sol";
import {IMerkleAdapterOracle} from "./IMerkleAdapterOracle.sol";

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";
import {IMulticallable} from "@symbioticfi/core/src/interfaces/common/IMulticallable.sol";

/**
 * @dev Role allowed to freeze, unfreeze, and review an exact oracle report.
 */
bytes32 constant ORACLE_GUARD_ROLE = keccak256("ORACLE_GUARD_ROLE");

/**
 * @title ICREOracle
 * @notice Interface for a MerkleAdapter NAV oracle receiving verified CRE reports.
 * @dev Roles are local to each oracle and configured during initialization.
 * Ownership changes do not transfer role grants.
 * Report metadata must identify WORKFLOW_REGISTRY as the workflow owner.
 *
 * onReport expects exactly five ABI words. The workflow values the whole adapter portfolio at a
 * completed block, including adapter and account cash, positions and claims, net of liabilities.
 * The oracle reconciles that snapshot with contract-owned capital-flow checkpoints.
 * Acceptance releases only staged adapter cash whose staging block is covered by the snapshot.
 * Missing cash defers outstanding liquidity demand without rejecting the valuation.
 * At most one snapshot is accepted per Unix-aligned REPORT_INTERVAL; delivery and review never shift it.
 * Authenticated accounting or movement-limit failures freeze the oracle and cache the exact payload.
 * Rejected reports preserve the accepted valuation and snapshot. Delivery success alone is not acceptance.
 */
interface ICREOracle is IMulticallable, IMerkleAdapterOracle, IMigratableEntity, ICREOracleBase {
    /* ERRORS */

    /**
     * @notice Raised when flow reconciliation yields a negative or overflowing portfolio value.
     */
    error InvalidAssets();

    /**
     * @notice Raised when a caller other than WORKFLOW_REGISTRY tries to set the accepted workflow.
     */
    error InvalidCaller();

    /**
     * @notice Raised when a payload is malformed, has a wrong destination, or cannot be accepted during review.
     */
    error InvalidReport();

    /**
     * @notice Raised when NAV-dependent operations are frozen pending curator review.
     */
    error OracleFrozen();

    /**
     * @notice Raised when no snapshot has been accepted or the last accepted NAV has expired.
     */
    error OracleStale();

    /**
     * @notice Raised when a snapshot is expired, in the future, or does not advance the previous snapshot.
     */
    error StaleReport();

    /* STRUCTS */

    /**
     * @notice Oracle-specific initialization parameters.
     * @dev Wrapped as abi.encode(adapter, abi.encode(InitParams)) by the adapter.
     * @param forwarder CRE forwarder that verifies DON signatures before delivering reports.
     * @param defaultAdminRoleHolder Initial holder of DEFAULT_ADMIN_ROLE; zero leaves it unassigned.
     * @param oracleGuardRoleHolder Initial holder of ORACLE_GUARD_ROLE; zero leaves it unassigned. With no admin
     * and no guard, a freeze can only be cleared by migrating the oracle implementation.
     * @param oracleLimitsRoleHolder Initial holder of ORACLE_LIMITS_ROLE; zero leaves it unassigned.
     * @param maxOracleGrowth Maximum increase per accepted report, scaled by ORACLE_LIMIT_PRECISION (1e8 = 100%).
     * @param maxOracleLoss Maximum decrease per accepted report, scaled by ORACLE_LIMIT_PRECISION (1e8 = 100%).
     * @param oracleTolerance Absolute NAV change in vault-asset base units accepted regardless of the limits.
     */
    struct InitParams {
        address forwarder;
        address defaultAdminRoleHolder;
        address oracleGuardRoleHolder;
        address oracleLimitsRoleHolder;
        uint256 maxOracleGrowth;
        uint256 maxOracleLoss;
        uint256 oracleTolerance;
    }

    /**
     * @notice ABI-encoded portfolio valuation delivered as the CRE report payload.
     * @param chainId Destination EVM chain ID.
     * @param adapter MerkleAdapter whose whole portfolio is valued by the workflow.
     * @param totalAssets Portfolio NAV at the snapshot, including adapter and account cash, positions and
     * claims, net of external liabilities. Excludes cash held by the vault.
     * @param snapshotBlock Completed, finalized valuation block, strictly newer than the accepted snapshot.
     * @param snapshotTimestamp Timestamp of that block, checked for freshness and reporting interval.
     */
    struct Report {
        uint256 chainId;
        address adapter;
        uint256 totalAssets;
        uint48 snapshotBlock;
        uint48 snapshotTimestamp;
    }

    /* EVENTS */

    /**
     * @notice Emitted when an authenticated snapshot becomes the accepted valuation.
     * @param totalAssets Portfolio NAV at the snapshot, before subsequent capital-flow adjustments.
     * @param snapshotBlock Valuation block number.
     * @param snapshotTimestamp Valuation block timestamp.
     */
    event OnReport(uint256 totalAssets, uint48 indexed snapshotBlock, uint48 snapshotTimestamp);

    /**
     * @notice Emitted when an authenticated report is rejected and the oracle is frozen.
     * @dev This delivery succeeds so the freeze persists; the valuation and snapshot do not change.
     * The latest rejected report may be accepted directly by unfreezeOracle without another delivery.
     * @param reportHash keccak256 of the exact report payload, usable for curator review.
     * @param report Rejected report.
     */
    event RejectReport(bytes32 indexed reportHash, Report report);

    /**
     * @notice Emitted when a guard-role holder freezes manually.
     */
    event FreezeOracle();

    /**
     * @notice Emitted when a guard-role holder unfreezes, optionally applying the rejected report.
     * @param reportHash Applied report hash, or zero when resuming the previously accepted NAV.
     */
    event UnfreezeOracle(bytes32 indexed reportHash);

    /* FUNCTIONS */

    /**
     * @notice Returns the interval allowing at most one accepted snapshot, in seconds.
     * @dev Intervals are aligned to the Unix epoch; acceptance time does not alter the schedule.
     */
    function REPORT_INTERVAL() external view returns (uint48);

    /**
     * @notice Returns whether report acceptance and NAV-dependent adapter operations are frozen.
     */
    function oracleFrozen() external view returns (bool);

    /**
     * @notice Returns the immutable maximum accepted NAV age in seconds.
     * @dev Configured on the implementation and shared by its proxies; also applies during report review.
     */
    function MAX_ORACLE_AGE() external view returns (uint48);

    /**
     * @notice Returns the hash of the latest authenticated rejected report, or zero.
     * @dev Replaced by subsequent rejected reports and cleared by unfreezing, manual freezing or workflow acceptance.
     */
    function rejectedReportHash() external view returns (bytes32);

    /**
     * @notice Freezes report acceptance and NAV-dependent operations; requires this oracle's ORACLE_GUARD_ROLE.
     */
    function freezeOracle() external;

    /**
     * @notice Unfreezes, optionally accepting the latest rejected report; requires this oracle's ORACLE_GUARD_ROLE.
     * @dev Empty bytes resume the previously accepted NAV with its original snapshot age.
     * Otherwise the payload must match rejectedReportHash and is applied immediately, bypassing only
     * movement limits. Freshness, destination, snapshot ordering and accounting bounds still apply.
     * Failed review reverts without changing the freeze, cached hash or accounting.
     * @param report Empty bytes, or the exact abi.encode(Report) payload from the latest RejectReport event.
     */
    function unfreezeOracle(bytes calldata report) external;

    /**
     * @notice Returns the immutable registry governing workflow proposals, acceptance and Chainlink registration.
     */
    function WORKFLOW_REGISTRY() external view returns (address);

    /**
     * @notice Updates the accepted workflow after registration; callable only by WORKFLOW_REGISTRY.
     * @dev Clears the rejected report hash while preserving valuation, snapshot, limits and freeze.
     * Provider proposal and Oracle-owner acceptance are handled entirely by the registry.
     */
    function setWorkflowId(bytes32 newWorkflowId) external;

    /**
     * @notice Returns the maximum snapshot age in seconds.
     */
    function MAX_REPORT_AGE() external view returns (uint48);

    /**
     * @notice Returns the adapter permanently bound during factory initialization with abi.encode(adapter, oracleData).
     */
    function adapter() external view returns (address);

    /**
     * @notice Returns the accepted snapshot NAV minus cumulative net capital at its block.
     * @dev Current NAV equals this signed offset plus adapter.netFlow().
     */
    function valuationOffset() external view returns (int256);

    /**
     * @notice Returns the block number of the most recently accepted snapshot.
     */
    function snapshotBlock() external view returns (uint48);

    /**
     * @notice Returns the timestamp of the most recently accepted snapshot.
     */
    function snapshotTimestamp() external view returns (uint48);
}
