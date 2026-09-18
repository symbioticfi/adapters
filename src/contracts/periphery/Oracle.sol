// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {IMerkleAdapterOracle} from "../../interfaces/merkle_adapter/IMerkleAdapterOracle.sol";
import {IOracle} from "../../interfaces/periphery/IOracle.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";

/// @title Oracle
/// @notice Contract for storing MerkleAdapter NAV delivered by an approved CRE forwarder and workflow.
contract Oracle is MigratableEntity, IOracle {
    /* IMMUTABLES */

    /// @inheritdoc IOracle
    address public immutable FORWARDER;

    /// @inheritdoc IOracle
    bytes32 public immutable WORKFLOW_ID;

    /// @inheritdoc IOracle
    uint256 public immutable MAX_REPORT_AGE;

    /* STATE VARIABLES */

    /// @inheritdoc IOracle
    address public adapter;

    /// @inheritdoc IMerkleAdapterOracle
    uint256 public nonce;

    /// @inheritdoc IMerkleAdapterOracle
    uint256 public totalAssets;

    /// @inheritdoc IOracle
    uint256 public snapshotBlock;

    /// @inheritdoc IOracle
    uint256 public snapshotTimestamp;

    /* CONSTRUCTOR */

    /// @dev Pins the report authority and age policy in the factory-approved implementation.
    constructor(address newFactory, address newForwarder, bytes32 newWorkflowId, uint256 newMaxReportAge)
        MigratableEntity(newFactory)
    {
        FORWARDER = newForwarder;
        WORKFLOW_ID = newWorkflowId;
        MAX_REPORT_AGE = newMaxReportAge;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IOracle
    function onReport(bytes calldata metadata, bytes calldata report) public {
        if (FORWARDER != msg.sender) revert InvalidSender();

        // Production KeystoneForwarder includes a trailing bytes2 report ID.
        if ((metadata.length != 62 && metadata.length != 64) || bytes32(metadata[:32]) != WORKFLOW_ID) {
            revert InvalidWorkflow();
        }

        if (report.length != 224) revert InvalidReport();

        Report memory update = abi.decode(report, (Report));
        if (update.chainId != block.chainid || update.oracle != address(this) || update.adapter != adapter) {
            revert InvalidReport();
        }

        if (update.nonce != nonce + 1) revert InvalidNonce();

        if (
            update.snapshotBlock <= snapshotBlock || update.snapshotBlock >= block.number
                || update.snapshotTimestamp <= snapshotTimestamp || update.snapshotTimestamp > block.timestamp
                || block.timestamp - update.snapshotTimestamp > MAX_REPORT_AGE
        ) revert StaleReport();

        nonce = update.nonce;
        totalAssets = update.totalAssets;
        snapshotBlock = update.snapshotBlock;
        snapshotTimestamp = update.snapshotTimestamp;
        emit OnReport(update.nonce, update.totalAssets, update.snapshotBlock, update.snapshotTimestamp);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        // Chainlink IReceiver adds only onReport to IERC165.
        return interfaceId == IOracle.onReport.selector || interfaceId == type(IERC165).interfaceId;
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Matches the adapter's existing oracle-factory initialization payload.
    function _initialize(uint64, address, bytes memory data) internal override {
        adapter = abi.decode(data, (address));
        if (adapter.code.length == 0) revert InvalidAdapter();
    }

    /// @dev Keeps accounting state while allowing the owner to accept a newly whitelisted report authority.
    function _migrate(uint64, uint64, bytes calldata data) internal pure override {
        if (data.length != 0) revert InvalidMigrationData();
    }
}
