// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMerkleAdapterOracle} from "../merkle_adapter/IMerkleAdapterOracle.sol";

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
     * @notice Raised when migration data is nonempty.
     */
    error InvalidMigrationData();

    /**
     * @notice Raised when the report does not advance exactly one accounting epoch.
     */
    error InvalidNonce();

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

    /* FUNCTIONS */

    /**
     * @notice Returns the approved CRE forwarder that verifies DON signatures.
     */
    function FORWARDER() external view returns (address);

    /**
     * @notice Returns the exact authorized CRE workflow ID, fixed by the approved implementation.
     */
    function WORKFLOW_ID() external view returns (bytes32);

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
     * @param metadata Packed workflow ID, name, owner, and optional report ID.
     * @param report abi.encode(Report), containing exactly seven ABI words.
     */
    function onReport(bytes calldata metadata, bytes calldata report) external;
}
