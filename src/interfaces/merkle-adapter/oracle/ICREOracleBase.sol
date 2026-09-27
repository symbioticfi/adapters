// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @dev Role allowed to configure oracle movement limits.
 */
bytes32 constant ORACLE_LIMITS_ROLE = keccak256("ORACLE_LIMITS_ROLE");

/**
 * @dev Precision for oracle movement limits; 1e8 represents 100%.
 */
uint256 constant ORACLE_LIMIT_PRECISION = 1e8;

/**
 * @title ICREOracleBase
 * @notice Interface for a receiver of verified CRE reports from one accepted workflow.
 * @dev Forwarder authentication, workflow gating and configurable movement limits are shared. How the accepted workflow is
 * chosen and how a verified payload is handled are implementation-specific.
 */
interface ICREOracleBase is IAccessControlEnumerable, IERC165 {
    /* ERRORS */

    /**
     * @notice Raised when movement limits exceed 1e8 (100%).
     */
    error InvalidOracleLimit();

    /**
     * @notice Raised when the report is not delivered by the configured forwarder.
     */
    error InvalidSender();

    /**
     * @notice Raised when workflow metadata is malformed or does not match the accepted workflow identity.
     */
    error InvalidWorkflow();

    /* STRUCTS */

    /**
     * @notice Receiver initialization parameters.
     * @param forwarder CRE forwarder that verifies DON signatures before delivering reports.
     * @param defaultAdminRoleHolder Initial holder of DEFAULT_ADMIN_ROLE; zero leaves it unassigned.
     * @param oracleLimitsRoleHolder Initial holder of ORACLE_LIMITS_ROLE; zero leaves it unassigned.
     * @param maxOracleGrowth Maximum increase, scaled by ORACLE_LIMIT_PRECISION (1e8 = 100%).
     * @param maxOracleLoss Maximum decrease, scaled by ORACLE_LIMIT_PRECISION (1e8 = 100%).
     * @param oracleTolerance Absolute change accepted regardless of the relative limits, in the reported value's units.
     */
    struct ReceiverParams {
        address forwarder;
        address defaultAdminRoleHolder;
        address oracleLimitsRoleHolder;
        uint256 maxOracleGrowth;
        uint256 maxOracleLoss;
        uint256 oracleTolerance;
    }

    /* EVENTS */

    /**
     * @notice Emitted when movement limits change.
     * @param maxGrowth Maximum increase, scaled by ORACLE_LIMIT_PRECISION (1e8 = 100%).
     * @param maxLoss Maximum decrease, scaled by ORACLE_LIMIT_PRECISION (1e8 = 100%).
     * @param tolerance Absolute change accepted regardless of the relative limits, in the reported value's units.
     */
    event SetOracleLimits(uint256 maxGrowth, uint256 maxLoss, uint256 tolerance);

    /**
     * @notice Emitted when the accepted workflow changes.
     * @param workflowId New accepted workflow ID, or zero when no workflow is accepted.
     */
    event SetWorkflowId(bytes32 indexed workflowId);

    /* FUNCTIONS */

    /**
     * @notice Returns the approved CRE forwarder that verifies DON signatures.
     */
    function forwarder() external view returns (address);

    /**
     * @notice Returns the maximum increase scaled by ORACLE_LIMIT_PRECISION (1e8 = 100%).
     */
    function maxOracleGrowth() external view returns (uint32);

    /**
     * @notice Returns the maximum decrease scaled by ORACLE_LIMIT_PRECISION (1e8 = 100%).
     */
    function maxOracleLoss() external view returns (uint32);

    /**
     * @notice Returns the absolute change accepted regardless of relative limits, in the reported value's units.
     */
    function oracleTolerance() external view returns (uint128);

    /**
     * @notice Sets the movement limits and absolute tolerance; requires this receiver's ORACLE_LIMITS_ROLE.
     * @dev Limits range from zero to 1e8 inclusive (100%). A change passes when its absolute value is within
     * the tolerance or its ratio to the baseline is within the directional limit. Changing limits does not
     * apply a report or change its validation state. Implementations choose the baseline and reported units.
     */
    function setOracleLimits(uint256 newGrowth, uint256 newLoss, uint256 newTolerance) external;

    /**
     * @notice Returns the accepted CRE workflow ID, or zero while no workflow is accepted.
     */
    function workflowId() external view returns (bytes32);

    /**
     * @notice Handles a report verified by the configured CRE forwarder for the accepted workflow.
     * @dev Supports Chainlink's IReceiver selector via ERC-165. Validates the first 32 bytes of
     * workflow metadata in the production 64-byte layout, then hands metadata and payload to the implementation.
     * Signature verification and DON configuration remain in the forwarder.
     * Delivery success alone does not mean the payload was applied; check implementation-specific state.
     * @param metadata Packed workflow ID, name, owner, and report ID.
     * @param report Workflow report payload.
     */
    function onReport(bytes calldata metadata, bytes calldata report) external;
}
