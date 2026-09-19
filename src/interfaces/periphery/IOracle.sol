// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMerkleAdapterOracle} from "../merkle-adapter/IMerkleAdapterOracle.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";

/**
 * @title IOracle
 * @notice Interface for a MerkleAdapter NAV oracle receiving verified CRE reports.
 */
interface IOracle is IMerkleAdapterOracle, IMigratableEntity, IERC165 {
    /* ERRORS */

    /**
     * @notice Raised when the adapter is not a contract.
     */
    error InvalidAdapter();

    /**
     * @notice Raised when a workflow proposer, accepting curator or guard-policy caller is unauthorized.
     */
    error InvalidCaller();

    /**
     * @notice Raised when migration data is nonempty.
     */
    error InvalidMigrationData();

    /**
     * @notice Raised when the report does not advance exactly one accounting epoch.
     */
    error InvalidNonce();

    /**
     * @notice Raised when movement limits exceed 10,000 bps or the age limit is zero.
     */
    error InvalidOracleLimit();

    /**
     * @notice Raised when the payload has an invalid length or belongs to another chain, oracle, or adapter.
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
     * @notice ABI-encoded NAV update delivered as the CRE report payload.
     * @param chainId Destination EVM chain ID.
     * @param oracle Destination oracle proxy, binding the payload to this receiver.
     * @param adapter MerkleAdapter valued by the workflow.
     * @param nonce Next accounting epoch, exactly current nonce plus one.
     * @param totalAssets NAV after excluding pending allocations and matured deallocation reserves.
     * @param snapshotBlock Finalized block used for valuation, strictly newer than the previous report's block.
     * @param snapshotTimestamp Timestamp of that block, checked against MAX_REPORT_AGE.
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
     * @param totalAssets Reported NAV in vault-asset base units.
     * @param snapshotBlock Valuation block number.
     * @param snapshotTimestamp Valuation block timestamp.
     */
    event OnReport(uint256 indexed nonce, uint256 totalAssets, uint256 snapshotBlock, uint256 snapshotTimestamp);

    /**
     * @notice Emitted when an authenticated report is rejected by the oracle guard.
     * @dev This delivery succeeds so the freeze persists; NAV and nonce do not change.
     * A corrected or curator-reviewed report needs a new CRE execution, with the same next nonce.
     * @param reportHash keccak256 of the exact report payload, usable for curator review.
     * @param report Rejected report.
     */
    event RejectReport(bytes32 indexed reportHash, Report report);

    /**
     * @notice Emitted when the factory owner replaces or clears this oracle's proposed workflow.
     * @param workflowId Proposed CRE workflow ID; zero cancels the pending proposal.
     */
    event ProposeWorkflow(bytes32 indexed workflowId);

    /**
     * @notice Emitted when the current adapter owner accepts the exact proposed workflow.
     * @param workflowId Accepted CRE workflow ID.
     */
    event AcceptWorkflow(bytes32 indexed workflowId);

    /**
     * @notice Emitted when NAV growth and loss limits change, in basis points.
     */
    event SetOracleLimits(uint256 maxGrowthBps, uint256 maxLossBps);

    /**
     * @notice Emitted when the maximum accepted NAV age changes, in seconds.
     */
    event SetMaxOracleAge(uint256 maxAge);

    /**
     * @notice Emitted when a report trips the guard or a guard-role holder freezes manually.
     */
    event FreezeOracle(bytes32 indexed reportHash);

    /**
     * @notice Emitted when a guard-role holder unfreezes, optionally approving one exact report.
     */
    event UnfreezeOracle(bytes32 indexed approvedReport);

    /* FUNCTIONS */

    /**
     * @notice Returns whether report acceptance and NAV-dependent adapter operations are frozen.
     */
    function oracleFrozen() external view returns (bool);

    /**
     * @notice Returns the maximum increase per accepted report in basis points, initially 1,000 (10%).
     */
    function maxOracleGrowthBps() external view returns (uint256);

    /**
     * @notice Returns the maximum decrease per accepted report in basis points, initially 1,000 (10%).
     */
    function maxOracleLossBps() external view returns (uint256);

    /**
     * @notice Returns the maximum accepted NAV age in seconds, initially one day.
     */
    function maxOracleAge() external view returns (uint256);

    /**
     * @notice Returns the exact report hash approved for one deviation exception, or zero.
     */
    function approvedOracleReport() external view returns (bytes32);

    /**
     * @notice Sets independent increase and decrease limits; requires the bound adapter's ORACLE_LIMITS_ROLE.
     * @dev Values range from zero to 10,000 inclusive. Zero permits no change in that direction.
     * Limits apply per report after reconciling allocations and withdrawals. Changing them does
     * not unfreeze the oracle, refresh NAV, or change the workflow.
     */
    function setOracleLimits(uint256 newGrowthBps, uint256 newLossBps) external;

    /**
     * @notice Sets a nonzero maximum accepted NAV age; requires the bound adapter's ORACLE_AGE_ROLE.
     * @dev Does not change the immutable MAX_REPORT_AGE delivery bound.
     */
    function setMaxOracleAge(uint256 newMaxAge) external;

    /**
     * @notice Freezes report acceptance and NAV-dependent operations; requires the adapter's ORACLE_GUARD_ROLE.
     */
    function freezeOracle() external;

    /**
     * @notice Clears the freeze; requires the bound adapter's ORACLE_GUARD_ROLE.
     * @dev Pass zero for ordinary recovery, or keccak256(abi.encode(Report)) to allow that exact
     * authenticated report to exceed deviation limits once. Freshness, reserves, destination,
     * epoch and workflow checks still apply. This function cannot write NAV. Any accepted report
     * or workflow change clears the exception. The accepted snapshot retains its original age.
     */
    function unfreezeOracle(bytes32 approvedReport) external;

    /**
     * @notice Returns the workflow ID proposed by the factory owner for this oracle, or zero.
     */
    function proposedWorkflowId() external view returns (bytes32);

    /**
     * @notice Proposes a CRE workflow for this oracle; callable only by the current oracle-factory owner.
     * @dev Each proxy has its own proposal. Replacing or clearing a proposal leaves its accepted
     * workflow active. The ID commits the reviewed compiled code, configuration and workflow owner.
     * @param newWorkflowId Exact proposed workflow ID, or zero to cancel the pending proposal.
     */
    function proposeWorkflow(bytes32 newWorkflowId) external;

    /**
     * @notice Accepts the exact nonzero proposal; callable only by the bound adapter's current owner.
     * @dev Consumes the proposal and clears any reviewed-report exception. Preserves the accepted NAV,
     * nonce, snapshot, limits and freeze. It neither needs a migration nor affects any other oracle.
     * @param newWorkflowId Expected proposal ID, preventing acceptance of a replaced proposal.
     */
    function acceptWorkflow(bytes32 newWorkflowId) external;

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
     * @notice Returns the adapter permanently bound during factory initialization with abi.encode(adapter).
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
     * workflow metadata; accepts the production 64-byte layout and the 62-byte identity layout.
     * Signature verification and DON configuration remain in the forwarder. NAV computation and
     * snapshot correctness remain in the pinned workflow. No curator override can submit NAV.
     * Oracle checks NAV movement, freshness, addition overflow and the adapter's next-epoch reserves
     * before acceptance. A guard rejection latches oracleFrozen and returns successfully with
     * RejectReport, preserving the freeze and old NAV, nonce and snapshot. Reverting would undo it.
     * Delivery success alone does not mean NAV acceptance; check OnReport and the stored nonce.
     * @param metadata Packed workflow ID, name, owner, and optional report ID.
     * @param report abi.encode(Report), containing exactly seven ABI words.
     */
    function onReport(bytes calldata metadata, bytes calldata report) external;
}
