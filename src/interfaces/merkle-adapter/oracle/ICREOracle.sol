// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMerkleAdapterOracle} from "./IMerkleAdapterOracle.sol";

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";
import {IMulticallable} from "@symbioticfi/core/src/interfaces/common/IMulticallable.sol";

/**
 * @dev Role allowed to freeze, unfreeze, and review an exact oracle report.
 */
bytes32 constant ORACLE_GUARD_ROLE = keccak256("ORACLE_GUARD_ROLE");

/**
 * @dev Role allowed to configure NAV growth and loss limits.
 */
bytes32 constant ORACLE_LIMITS_ROLE = keccak256("ORACLE_LIMITS_ROLE");

/**
 * @title ICREOracle
 * @notice Interface for a MerkleAdapter NAV oracle receiving verified CRE reports.
 * @dev Roles are local to each oracle and configured during initialization.
 * Ownership changes do not transfer role grants.
 */
interface ICREOracle is IMulticallable, IMerkleAdapterOracle, IMigratableEntity, IAccessControlEnumerable, IERC165 {
    /* ERRORS */

    /**
     * @notice Raised when a caller other than WORKFLOW_REGISTRY tries to set the accepted workflow.
     */
    error InvalidCaller();

    /**
     * @notice Raised when the report does not advance exactly one accounting epoch.
     */
    error InvalidNonce();

    /**
     * @notice Raised when movement limits exceed 10,000 bps.
     */
    error InvalidOracleLimit();

    /**
     * @notice Raised when a payload is malformed, has a wrong destination, or cannot be accepted during review.
     */
    error InvalidReport();

    /**
     * @notice Raised when the report is not delivered by the configured forwarder.
     */
    error InvalidSender();

    /**
     * @notice Raised when the workflow ID is unexpected or absent from metadata.
     */
    error InvalidWorkflow();

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
     * @param defaultAdminRoleHolder Initial holder of DEFAULT_ADMIN_ROLE; zero leaves it unassigned.
     * @param oracleGuardRoleHolder Initial holder of ORACLE_GUARD_ROLE; zero leaves it unassigned.
     * @param oracleLimitsRoleHolder Initial holder of ORACLE_LIMITS_ROLE; zero leaves it unassigned.
     * @param maxOracleGrowthBps Maximum increase per accepted report, in basis points.
     * @param maxOracleLossBps Maximum decrease per accepted report, in basis points.
     */
    struct InitParams {
        address defaultAdminRoleHolder;
        address oracleGuardRoleHolder;
        address oracleLimitsRoleHolder;
        uint256 maxOracleGrowthBps;
        uint256 maxOracleLossBps;
    }

    /**
     * @notice ABI-encoded NAV update delivered as the CRE report payload.
     * @param chainId Destination EVM chain ID.
     * @param oracle Destination oracle proxy, binding the payload to this receiver.
     * @param adapter MerkleAdapter valued by the workflow.
     * @param nonce Next accounting epoch, exactly current nonce plus one.
     * @param totalAssets NAV including allocations in the closed current batch, before releasing its
     * withdrawals. Excludes following-batch allocations and already-matured withdrawals. The adapter
     * caps the new release by this value; Oracle stores the remainder in its totalAssets getter.
     * @param snapshotBlock Finalized block used for valuation, strictly newer than the previous report's block.
     * @param snapshotTimestamp Timestamp of that block, at or after cutoff and checked against MAX_REPORT_AGE.
     */
    struct Report {
        uint256 chainId;
        address oracle;
        address adapter;
        uint256 nonce;
        uint256 totalAssets;
        uint256 snapshotBlock;
        uint256 snapshotTimestamp;
    }

    /* EVENTS */

    /**
     * @notice Emitted when a verified report advances NAV and its accounting epoch.
     * @param nonce New accounting epoch.
     * @param totalAssets Accepted NAV after releasing newly matured withdrawals, in vault-asset base units.
     * @param snapshotBlock Valuation block number.
     * @param snapshotTimestamp Valuation block timestamp.
     */
    event OnReport(uint256 indexed nonce, uint256 totalAssets, uint256 snapshotBlock, uint256 snapshotTimestamp);

    /**
     * @notice Emitted when an authenticated report is rejected and the oracle is frozen.
     * @dev This delivery succeeds so the freeze persists; NAV and nonce do not change.
     * The latest rejected report may be accepted directly by unfreezeOracle without another delivery.
     * @param reportHash keccak256 of the exact report payload, usable for curator review.
     * @param report Rejected report.
     */
    event RejectReport(bytes32 indexed reportHash, Report report);

    /**
     * @notice Emitted when NAV growth and loss limits change, in basis points.
     */
    event SetOracleLimits(uint256 maxGrowthBps, uint256 maxLossBps);

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
     * @notice Returns the fixed interval between scheduled reports, in seconds.
     * @dev Scheduled times are multiples of this interval since the Unix epoch.
     */
    function REPORT_INTERVAL() external view returns (uint48);

    /**
     * @notice Returns how many seconds before a scheduled report its batch closes.
     * @dev Configure below REPORT_INTERVAL. The workflow must use a finalized snapshot at or after cutoff.
     */
    function REPORT_BUFFER() external view returns (uint48);

    /**
     * @notice Returns whether report acceptance and NAV-dependent adapter operations are frozen.
     */
    function oracleFrozen() external view returns (bool);

    /**
     * @notice Returns the maximum increase per accepted report in basis points.
     */
    function maxOracleGrowthBps() external view returns (uint256);

    /**
     * @notice Returns the maximum decrease per accepted report in basis points.
     */
    function maxOracleLossBps() external view returns (uint256);

    /**
     * @notice Returns the immutable maximum accepted NAV age in seconds.
     * @dev Configured on the implementation and shared by its proxies; also applies during report review.
     */
    function MAX_ORACLE_AGE() external view returns (uint256);

    /**
     * @notice Returns the hash of the latest authenticated rejected report, or zero.
     * @dev Replaced by subsequent rejected reports and cleared by unfreezing, manual freezing or workflow acceptance.
     */
    function rejectedReportHash() external view returns (bytes32);

    /**
     * @notice Sets independent increase and decrease limits; requires this oracle's ORACLE_LIMITS_ROLE.
     * @dev Values range from zero to 10,000 inclusive. Zero permits no change in that direction.
     * Limits apply per report after reconciling allocations and withdrawals. Changing them does
     * not unfreeze the oracle, refresh NAV, or change the workflow.
     */
    function setOracleLimits(uint256 newGrowthBps, uint256 newLossBps) external;

    /**
     * @notice Freezes report acceptance and NAV-dependent operations; requires this oracle's ORACLE_GUARD_ROLE.
     */
    function freezeOracle() external;

    /**
     * @notice Unfreezes, optionally accepting the latest rejected report; requires this oracle's ORACLE_GUARD_ROLE.
     * @dev Empty bytes resume the previously accepted NAV with its original snapshot age.
     * Otherwise the payload must match rejectedReportHash and is applied immediately, bypassing only
     * movement limits. Freshness, destination, nonce, cutoff, overflow and reserve checks still apply.
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
     * @dev Clears the rejected report hash while preserving NAV, nonce, snapshot, limits and freeze.
     * Provider proposal and Oracle-owner acceptance are handled entirely by the registry.
     */
    function setWorkflowId(bytes32 newWorkflowId) external;

    /**
     * @notice Returns the approved CRE forwarder that verifies DON signatures.
     */
    function FORWARDER() external view returns (address);

    /**
     * @notice Returns the curator-accepted CRE workflow ID, or zero before the first acceptance.
     */
    function workflowId() external view returns (bytes32);

    /**
     * @notice Returns the maximum snapshot age in seconds.
     */
    function MAX_REPORT_AGE() external view returns (uint256);

    /**
     * @notice Returns the adapter permanently bound during factory initialization with abi.encode(adapter, oracleData).
     */
    function adapter() external view returns (address);

    /**
     * @notice Returns the block number of the most recently accepted snapshot.
     */
    function snapshotBlock() external view returns (uint256);

    /**
     * @notice Returns the timestamp of the most recently accepted snapshot.
     */
    function snapshotTimestamp() external view returns (uint256);

    /**
     * @notice Accepts a NAV report verified by the configured CRE forwarder.
     * @dev Supports Chainlink's IReceiver selector via ERC-165. Validates the first 32 bytes of
     * workflow metadata in the production 64-byte layout.
     * Signature verification and DON configuration remain in the forwarder. NAV computation and
     * snapshot correctness remain in the pinned workflow. Curators can apply only an already-authenticated report.
     * Reports include the assets about to become withdrawal reserves; stored NAV and OnReport exclude them.
     * The new withdrawal reserve is capped by authenticated report NAV, preserving already-matured reserves.
     * The snapshot must be at or after cutoff, when the current batch stopped accepting changes.
     * Acceptance closes that batch and schedules a strictly future cutoff for the following batch.
     * Oracle checks NAV movement and freshness; an overflowing accounting baseline reverts.
     * The adapter checks reserve backing and overflow
     * before settling the batch. A guard rejection latches oracleFrozen and returns successfully with
     * RejectReport, caching its hash and preserving old NAV, nonce and snapshot. Reverting would undo the freeze.
     * Delivery success alone does not mean NAV acceptance; check OnReport and the stored nonce.
     * @param metadata Packed workflow ID, name, owner, and report ID.
     * @param report abi.encode(Report), containing exactly seven ABI words.
     */
    function onReport(bytes calldata metadata, bytes calldata report) external;
}
