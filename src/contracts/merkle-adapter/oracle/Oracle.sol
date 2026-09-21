// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {IMerkleAccount} from "../../../interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapterOracle} from "../../../interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {IMerkleAdapter} from "../../../interfaces/IMerkleAdapter.sol";
import {
    IOracle,
    ORACLE_AGE_ROLE,
    ORACLE_GUARD_ROLE,
    ORACLE_LIMITS_ROLE
} from "../../../interfaces/merkle-adapter/oracle/IOracle.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {Multicallable} from "@symbioticfi/core/src/contracts/common/Multicallable.sol";

/// @title Oracle
/// @notice Contract for storing MerkleAdapter NAV delivered by an approved CRE forwarder and workflow.
contract Oracle is Multicallable, MigratableEntity, IOracle {
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc IOracle
    address public immutable FORWARDER;

    /// @inheritdoc IOracle
    uint256 public immutable MAX_REPORT_AGE;

    /// @inheritdoc IOracle
    uint48 public immutable REPORT_INTERVAL;

    /// @inheritdoc IOracle
    uint48 public immutable REPORT_BUFFER;

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
    bytes32 public rejectedReportHash;

    /// @inheritdoc IMerkleAdapterOracle
    uint256 public cutoff;

    /* MODIFIERS */

    modifier onlyAccountRole(bytes32 role) {
        if (!IMerkleAccount(IMerkleAdapter(adapter).account()).hasRole(role, msg.sender)) revert InvalidCaller();
        _;
    }

    /* CONSTRUCTOR */

    /// @dev Pins delivery and a Unix-aligned reporting schedule; workflows are accepted per proxy.
    constructor(
        address newFactory,
        address newForwarder,
        uint256 newMaxReportAge,
        uint48 newReportInterval,
        uint48 newReportBuffer
    ) MigratableEntity(newFactory) {
        if (newReportInterval == 0 || newReportBuffer >= newReportInterval) {
            revert InvalidSchedule();
        }

        FORWARDER = newForwarder;
        MAX_REPORT_AGE = newMaxReportAge;
        REPORT_INTERVAL = newReportInterval;
        REPORT_BUFFER = newReportBuffer;
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
        delete rejectedReportHash;
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
        delete rejectedReportHash;
        emit FreezeOracle();
    }

    /// @inheritdoc IOracle
    function unfreezeOracle(bytes calldata report) public onlyAccountRole(ORACLE_GUARD_ROLE) {
        bytes32 reportHash;
        if (report.length != 0) {
            reportHash = keccak256(report);
            if (reportHash != rejectedReportHash || !_acceptReport(abi.decode(report, (Report)), true)) {
                revert InvalidReport();
            }
        }
        oracleFrozen = false;
        delete rejectedReportHash;
        emit UnfreezeOracle(reportHash);
    }

    /// @inheritdoc IMerkleAdapterOracle
    function validate() public view returns (uint256, uint256) {
        if (oracleFrozen) revert OracleFrozen();
        if (snapshotTimestamp == 0 || block.timestamp - snapshotTimestamp > maxOracleAge) revert OracleStale();
        return (totalAssets, cutoff);
    }

    /// @inheritdoc IOracle
    function onReport(bytes calldata metadata, bytes calldata report) public {
        if (FORWARDER != msg.sender) revert InvalidSender();

        // Production KeystoneForwarder includes a trailing bytes2 report ID.
        if (workflowId == bytes32(0) || metadata.length != 64 || bytes32(metadata[:32]) != workflowId) {
            revert InvalidWorkflow();
        }

        if (report.length != 224) revert InvalidReport();

        Report memory update = abi.decode(report, (Report));
        if (_acceptReport(update, false)) return;

        oracleFrozen = true;
        rejectedReportHash = keccak256(report);
        emit RejectReport(rejectedReportHash, update);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        // Chainlink IReceiver adds only onReport to IERC165.
        return interfaceId == IOracle.onReport.selector || interfaceId == type(IERC165).interfaceId;
    }

    /* INTERNAL FUNCTIONS */

    /// @dev A reviewed report bypasses the freeze and movement limits only.
    function _acceptReport(Report memory update, bool reviewed) internal returns (bool) {
        if (update.chainId != block.chainid || update.adapter != adapter || update.oracle != address(this)) {
            revert InvalidReport();
        }

        if (update.nonce != nonce + 1) revert InvalidNonce();

        if (
            update.snapshotBlock <= snapshotBlock || update.snapshotBlock >= block.number
                || update.snapshotTimestamp == 0 || update.snapshotTimestamp > block.timestamp
                || update.snapshotTimestamp < cutoff || block.timestamp - update.snapshotTimestamp > MAX_REPORT_AGE
        ) revert StaleReport();

        if (!reviewed && oracleFrozen) return false;

        (uint256 pending,) = IMerkleAdapter(adapter).currentBatch();
        uint256 baseline = totalAssets + pending;
        if (
            block.timestamp - update.snapshotTimestamp > maxOracleAge
                || (!reviewed
                    && (update.totalAssets >= baseline
                            ? update.totalAssets - baseline > baseline.mulDiv(maxOracleGrowthBps, 10_000)
                            : baseline - update.totalAssets > baseline.mulDiv(maxOracleLossBps, 10_000)))
        ) return false;

        (bool valid, uint256 assets) = IMerkleAdapter(adapter).settleReport(update.totalAssets);
        if (!valid) return false;

        nonce = update.nonce;
        totalAssets = assets;
        snapshotBlock = update.snapshotBlock;
        snapshotTimestamp = update.snapshotTimestamp;
        // Delayed acceptance still leaves the next batch's cutoff strictly in the future.
        cutoff = block.timestamp + REPORT_INTERVAL - (block.timestamp + REPORT_BUFFER) % REPORT_INTERVAL;
        emit OnReport(update.nonce, assets, update.snapshotBlock, update.snapshotTimestamp);
        return true;
    }

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
