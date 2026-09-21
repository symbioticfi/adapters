// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {IMerkleAccount} from "../../../interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapterOracle} from "../../../interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {IMerkleAdapter} from "../../../interfaces/IMerkleAdapter.sol";
import {IOracle} from "../../../interfaces/merkle-adapter/oracle/IOracle.sol";
import {IRoles} from "../../../interfaces/merkle-adapter/oracle/IRoles.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {Multicallable} from "@symbioticfi/core/src/contracts/common/Multicallable.sol";

/// @title Oracle
/// @notice Contract for storing MerkleAdapter NAV delivered by an approved CRE forwarder and workflow.
contract Oracle is Multicallable, MigratableEntity, IRoles, IOracle {
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc IOracle
    address public immutable FORWARDER;

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

    /// @inheritdoc IOracle
    bytes32 public workflowId;

    /// @inheritdoc IOracle
    bytes32 public proposedWorkflowId;

    /// @inheritdoc IOracle
    bool public oracleFrozen;

    /// @inheritdoc IOracle
    uint256 public maxOracleGrowthBps;

    /// @inheritdoc IOracle
    uint256 public maxOracleLossBps;

    /// @inheritdoc IOracle
    uint256 public maxOracleAge;

    /// @inheritdoc IOracle
    bytes32 public approvedOracleReport;

    /* MODIFIERS */

    modifier onlyAccountRole(bytes32 role) {
        if (!IMerkleAccount(IMerkleAdapter(adapter).account()).hasRole(role, msg.sender)) revert InvalidCaller();
        _;
    }

    /* CONSTRUCTOR */

    /// @dev Pins the report forwarder and delivery age; workflows are proposed and accepted per proxy.
    constructor(address newFactory, address newForwarder, uint256 newMaxReportAge) MigratableEntity(newFactory) {
        FORWARDER = newForwarder;
        MAX_REPORT_AGE = newMaxReportAge;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IOracle
    function proposeWorkflow(bytes32 newWorkflowId) public {
        if (Ownable(FACTORY).owner() != msg.sender) revert InvalidCaller();

        proposedWorkflowId = newWorkflowId;
        emit ProposeWorkflow(newWorkflowId);
    }

    /// @inheritdoc IOracle
    function acceptWorkflow(bytes32 newWorkflowId) public {
        if (Ownable(IMerkleAdapter(adapter).account()).owner() != msg.sender) revert InvalidCaller();
        if (newWorkflowId == bytes32(0) || newWorkflowId != proposedWorkflowId) revert InvalidWorkflow();

        workflowId = newWorkflowId;
        delete proposedWorkflowId;
        delete approvedOracleReport;
        emit AcceptWorkflow(newWorkflowId);
    }

    /// @inheritdoc IOracle
    function setOracleLimits(uint256 newGrowthBps, uint256 newLossBps) public onlyAccountRole(ORACLE_LIMITS_ROLE) {
        if (newGrowthBps > 10_000 || newLossBps > 10_000) revert InvalidOracleLimit();

        maxOracleGrowthBps = newGrowthBps;
        maxOracleLossBps = newLossBps;
        emit SetOracleLimits(newGrowthBps, newLossBps);
    }

    /// @inheritdoc IOracle
    function setMaxOracleAge(uint256 newMaxAge) public onlyAccountRole(ORACLE_AGE_ROLE) {
        if (newMaxAge == 0) revert InvalidOracleLimit();

        maxOracleAge = newMaxAge;
        emit SetMaxOracleAge(newMaxAge);
    }

    /// @inheritdoc IOracle
    function freezeOracle() public onlyAccountRole(ORACLE_GUARD_ROLE) {
        oracleFrozen = true;
        delete approvedOracleReport;
        emit FreezeOracle(bytes32(0));
    }

    /// @inheritdoc IOracle
    function unfreezeOracle(bytes32 approvedReport) public onlyAccountRole(ORACLE_GUARD_ROLE) {
        oracleFrozen = false;
        approvedOracleReport = approvedReport;
        emit UnfreezeOracle(approvedReport);
    }

    /// @inheritdoc IMerkleAdapterOracle
    function validate() public view {
        if (oracleFrozen) revert OracleFrozen();
        if (workflowId == bytes32(0)) revert InvalidWorkflow();
        if (snapshotTimestamp == 0 || block.timestamp - snapshotTimestamp > maxOracleAge) revert OracleStale();
    }

    /// @inheritdoc IOracle
    function onReport(bytes calldata metadata, bytes calldata report) public {
        if (FORWARDER != msg.sender) revert InvalidSender();

        // Production KeystoneForwarder includes a trailing bytes2 report ID.
        if (
            workflowId == bytes32(0) || (metadata.length != 62 && metadata.length != 64)
                || bytes32(metadata[:32]) != workflowId
        ) revert InvalidWorkflow();

        if (report.length != 224) revert InvalidReport();

        Report memory update = abi.decode(report, (Report));
        if (update.chainId != block.chainid || update.adapter != adapter) revert InvalidReport();
        if (update.oracle != address(this)) revert InvalidReport();

        if (update.nonce != nonce + 1) revert InvalidNonce();

        if (
            update.snapshotBlock <= snapshotBlock || update.snapshotBlock >= block.number
                || update.snapshotTimestamp <= snapshotTimestamp || update.snapshotTimestamp > block.timestamp
                || block.timestamp - update.snapshotTimestamp > MAX_REPORT_AGE
        ) revert StaleReport();

        bytes32 reportHash = keccak256(report);
        if (oracleFrozen) {
            emit RejectReport(reportHash, update);
            return;
        }

        uint256 nextReservedAssets = IMerkleAdapter(adapter).reservedAssetsAt(update.nonce);
        (bool validBaseline, uint256 baseline) =
            Math.tryAdd(totalAssets, IMerkleAdapter(adapter).pendingAllocation(nonce));
        (bool validAssets, uint256 assets) = Math.tryAdd(
            update.totalAssets,
            IMerkleAdapter(adapter).deallocatableAt(update.nonce) - IMerkleAdapter(adapter).deallocatableAt(nonce)
        );
        (bool validTotal,) = Math.tryAdd(update.totalAssets, nextReservedAssets);
        if (
            !validBaseline || !validAssets || !validTotal || block.timestamp - update.snapshotTimestamp > maxOracleAge
                || IMerkleAdapter(adapter).freeAssets() < nextReservedAssets
                || (reportHash != approvedOracleReport
                    && (assets >= baseline
                            ? assets - baseline > baseline.mulDiv(maxOracleGrowthBps, 10_000)
                            : baseline - assets > baseline.mulDiv(maxOracleLossBps, 10_000)))
        ) {
            oracleFrozen = true;
            emit FreezeOracle(reportHash);
            emit RejectReport(reportHash, update);
            return;
        }

        delete approvedOracleReport;
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

        maxOracleGrowthBps = 1000;
        maxOracleLossBps = 1000;
        maxOracleAge = 1 days;
    }

    /// @dev Keeps accepted workflow, guard policy and accounting state across implementation upgrades.
    function _migrate(uint64, uint64, bytes calldata data) internal pure override {
        if (data.length != 0) revert InvalidMigrationData();
    }
}
