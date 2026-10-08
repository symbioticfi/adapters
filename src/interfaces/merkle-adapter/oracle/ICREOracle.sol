// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMerkleAdapterOracle} from "./IMerkleAdapterOracle.sol";

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";
import {IMulticallable} from "@symbioticfi/core/src/interfaces/common/IMulticallable.sol";

/**
 * @dev Role allowed to accept the latest rejected oracle report.
 */
bytes32 constant ORACLE_GUARD_ROLE = keccak256("ORACLE_GUARD_ROLE");

/**
 * @dev Role allowed to configure oracle movement limits.
 */
bytes32 constant ORACLE_LIMITS_ROLE = keccak256("ORACLE_LIMITS_ROLE");

/**
 * @dev Precision for oracle movement limits; 1e8 represents 100%.
 */
uint256 constant ORACLE_LIMIT_PRECISION = 1e8;

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
 * The oracle only reads adapter flow history. The adapter synchronizes accepted reports on capital operations
 * and releases only staged cash whose staging block is covered by the snapshot.
 * Missing cash defers outstanding liquidity demand without rejecting the valuation.
 * Accepted snapshots must strictly advance both block number and timestamp.
 * Only movement-limit failures cache the payload hash and emit the rejected report. Other failures revert.
 * Rejection preserves the accepted valuation and its expiry; later reports can still be accepted normally.
 * Delivery success alone is not acceptance.
 */
interface ICREOracle is IMulticallable, IMerkleAdapterOracle, IMigratableEntity, IAccessControlEnumerable, IERC165 {
    /* ERRORS */

    /**
     * @notice Raised when a report reconciles to a negative current portfolio value.
     */
    error InvalidAssets();

    /**
     * @notice Raised when movement limits exceed 1e8 (100%).
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
     * @notice Raised when workflow metadata is malformed or does not match the accepted workflow identity.
     */
    error InvalidWorkflow();

    /**
     * @notice Raised when a snapshot is expired, in the future, or does not advance the previous snapshot.
     */
    error StaleReport();

    /* STRUCTS */

    /**
     * @notice Oracle initialization parameters.
     * @dev Wrapped as abi.encode(adapter, abi.encode(InitParams)) by the adapter.
     * @param defaultAdminRoleHolder Initial holder of DEFAULT_ADMIN_ROLE; zero leaves it unassigned.
     * @param oracleGuardRoleHolder Initial holder of ORACLE_GUARD_ROLE, allowed to accept rejected reports;
     * zero leaves it unassigned.
     * @param oracleLimitsRoleHolder Initial holder of ORACLE_LIMITS_ROLE; zero leaves it unassigned.
     * @param maxOracleGrowth Maximum increase per accepted report, scaled by ORACLE_LIMIT_PRECISION (1e8 = 100%).
     * @param maxOracleLoss Maximum decrease per accepted report, scaled by ORACLE_LIMIT_PRECISION (1e8 = 100%).
     * @param oracleTolerance Absolute NAV change in vault-asset base units accepted regardless of the limits.
     */
    struct InitParams {
        address defaultAdminRoleHolder;
        address oracleGuardRoleHolder;
        address oracleLimitsRoleHolder;
        uint32 maxOracleGrowth;
        uint32 maxOracleLoss;
        uint128 oracleTolerance;
    }

    /**
     * @notice ABI-encoded portfolio valuation delivered as the CRE report payload.
     * @param chainId Destination EVM chain ID.
     * @param adapter MerkleAdapter whose whole portfolio is valued by the workflow.
     * @param totalAssets Portfolio NAV at the snapshot, including adapter and account cash, positions and
     * claims, net of external liabilities. Excludes cash held by the vault.
     * @param snapshotBlock Completed, finalized valuation block, strictly newer than the accepted snapshot.
     * @param snapshotTimestamp Timestamp of that block, checked for freshness and strict advancement.
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
     * @notice Emitted when an authenticated snapshot is accepted or rejected by movement limits.
     * @dev Rejection preserves the accepted valuation and caches the report hash for curator review.
     * @param report Complete portfolio valuation and snapshot identity; abi.encode(report) reconstructs the payload.
     * @param isRejected Whether movement limits rejected the report.
     */
    event OnReport(Report report, bool isRejected);

    /**
     * @notice Emitted when a guard-role holder accepts the latest rejected report.
     * @param report Applied ABI-encoded Report payload.
     */
    event AcceptReport(bytes report);

    /**
     * @notice Emitted when movement limits change.
     * @param maxGrowth Maximum increase, scaled by ORACLE_LIMIT_PRECISION (1e8 = 100%).
     * @param maxLoss Maximum decrease, scaled by ORACLE_LIMIT_PRECISION (1e8 = 100%).
     * @param tolerance Absolute NAV change accepted regardless of the relative limits, in vault-asset base units.
     */
    event SetOracleLimits(uint32 maxGrowth, uint32 maxLoss, uint128 tolerance);

    /* FUNCTIONS */

    /**
     * @notice Returns the hash of the latest authenticated rejected report, or zero.
     * @dev Latest refers to delivery order. Ordinary acceptance preserves this hash; a cached report must still
     * advance the active snapshot to be reviewed. Replaced by subsequent rejected reports and cleared by
     * curator acceptance. Workflow changes preserve the candidate. OnReport emits the complete Report.
     */
    function rejectedReportHash() external view returns (bytes32);

    /**
     * @notice Accepts the latest rejected report; requires this oracle's ORACLE_GUARD_ROLE.
     * @dev The payload must match rejectedReportHash and is applied immediately, bypassing movement limits.
     * Freshness, destination, snapshot ordering and accounting bounds, including a nonnegative historical
     * baseline, still apply. Both snapshot block and
     * timestamp must advance the active report.
     * Success clears the rejected hash. Failed review leaves the hash and accounting unchanged.
     * @param data Exact abi.encode(Report) payload matching rejectedReportHash.
     */
    function acceptReport(bytes calldata data) external;

    /**
     * @notice Returns the immutable registry governing workflow proposals, acceptance and Chainlink registration.
     */
    function WORKFLOW_REGISTRY() external view returns (address);

    /**
     * @notice Returns the adapter permanently bound during factory initialization with abi.encode(adapter, oracleData).
     */
    function adapter() external view returns (address);

    /**
     * @notice Returns the immutable CRE forwarder that verifies DON signatures.
     * @dev Shared by all proxies using this implementation; migration selects the new implementation's forwarder.
     */
    function FORWARDER() external view returns (address);

    /**
     * @notice Returns the maximum increase scaled by ORACLE_LIMIT_PRECISION (1e8 = 100%).
     */
    function maxOracleGrowth() external view returns (uint32);

    /**
     * @notice Returns the maximum decrease scaled by ORACLE_LIMIT_PRECISION (1e8 = 100%).
     */
    function maxOracleLoss() external view returns (uint32);

    /**
     * @notice Returns the absolute NAV change accepted regardless of relative limits, in vault-asset base units.
     */
    function oracleTolerance() external view returns (uint128);

    /**
     * @notice Sets the movement limits and absolute tolerance; requires this oracle's ORACLE_LIMITS_ROLE.
     * @dev Limits range from zero to 1e8 inclusive (100%). A change passes when its absolute value is within
     * the tolerance or its ratio to the flow-adjusted baseline is within the directional limit. Changing limits
     * does not apply a report. Subsequent deliveries use the new limits and can be accepted after a rejection.
     */
    function setOracleLimits(uint32 newGrowth, uint32 newLoss, uint128 newTolerance) external;

    /**
     * @notice Applies a verified report, or caches its hash for curator review when movement limits are exceeded.
     * @dev Supports Chainlink's IReceiver selector via ERC-165. Metadata must use the production 64-byte layout,
     * identify the accepted workflow, and name WORKFLOW_REGISTRY as its owner. Signature verification and DON
     * configuration remain in the forwarder. The accepted workflow ID is read from WORKFLOW_REGISTRY.
     * A negative flow-adjusted historical baseline reverts with SafeCastOverflowedIntToUint.
     * Delivery success alone does not mean the valuation was accepted;
     * inspect OnReport.isRejected and the oracle's state. All other failures revert, preserving the rejected
     * hash and accepted state. Rejection leaves the last accepted NAV usable until its original expiry, subject to
     * valid flow reconciliation. It releases no liquidity.
     * @param metadata Packed workflow ID, name, owner, and report ID.
     * @param data ABI-encoded Report containing the portfolio valuation and snapshot identity.
     */
    function onReport(bytes calldata metadata, bytes calldata data) external;
}
