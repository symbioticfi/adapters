// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {
    ICREOracle,
    ORACLE_GUARD_ROLE,
    ORACLE_LIMITS_ROLE
} from "../../../interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {IMerkleAdapterOracle} from "../../../interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {IMerkleAdapter} from "../../../interfaces/IMerkleAdapter.sol";

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {Multicallable} from "@symbioticfi/core/src/contracts/common/Multicallable.sol";

/// @title CREOracle
/// @notice Contract for storing MerkleAdapter NAV delivered by an approved CRE forwarder and workflow.
contract CREOracle is Multicallable, MigratableEntity, AccessControlEnumerableUpgradeable, ICREOracle {
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc ICREOracle
    address public immutable WORKFLOW_REGISTRY;

    /// @inheritdoc ICREOracle
    address public immutable FORWARDER;

    /// @inheritdoc ICREOracle
    uint256 public immutable MAX_REPORT_AGE;

    /// @inheritdoc ICREOracle
    uint256 public immutable MAX_ORACLE_AGE;

    /// @inheritdoc ICREOracle
    uint48 public immutable REPORT_INTERVAL;

    /// @inheritdoc ICREOracle
    uint48 public immutable REPORT_BUFFER;

    /* STATE VARIABLES */

    /// @inheritdoc ICREOracle
    address public adapter;

    /// @inheritdoc IMerkleAdapterOracle
    uint256 public nonce;

    /// @inheritdoc IMerkleAdapterOracle
    uint256 public totalAssets;

    /// @inheritdoc ICREOracle
    uint256 public snapshotBlock;

    /// @inheritdoc ICREOracle
    uint256 public snapshotTimestamp;

    /// @inheritdoc ICREOracle
    bytes32 public workflowId;

    /// @inheritdoc ICREOracle
    bool public oracleFrozen;

    /// @inheritdoc ICREOracle
    uint256 public maxOracleGrowthBps;

    /// @inheritdoc ICREOracle
    uint256 public maxOracleLossBps;

    /// @inheritdoc ICREOracle
    bytes32 public rejectedReportHash;

    /// @inheritdoc IMerkleAdapterOracle
    uint256 public cutoff;

    /* CONSTRUCTOR */

    /// @dev Pins delivery, NAV freshness and a Unix-aligned reporting schedule; workflows are accepted per proxy.
    constructor(
        address newFactory,
        address newWorkflowRegistry,
        address newForwarder,
        uint256 newMaxReportAge,
        uint256 newMaxOracleAge,
        uint48 newReportInterval,
        uint48 newReportBuffer
    ) MigratableEntity(newFactory) {
        WORKFLOW_REGISTRY = newWorkflowRegistry;
        FORWARDER = newForwarder;
        MAX_REPORT_AGE = newMaxReportAge;
        MAX_ORACLE_AGE = newMaxOracleAge;
        REPORT_INTERVAL = newReportInterval;
        REPORT_BUFFER = newReportBuffer;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ICREOracle
    function setWorkflowId(bytes32 newWorkflowId) public {
        if (msg.sender != WORKFLOW_REGISTRY) revert InvalidCaller();
        workflowId = newWorkflowId;
        delete rejectedReportHash;
    }

    /// @inheritdoc ICREOracle
    function setOracleLimits(uint256 newGrowthBps, uint256 newLossBps) public onlyRole(ORACLE_LIMITS_ROLE) {
        _setOracleLimits(newGrowthBps, newLossBps);
    }

    /// @inheritdoc ICREOracle
    function freezeOracle() public onlyRole(ORACLE_GUARD_ROLE) {
        oracleFrozen = true;
        delete rejectedReportHash;
        emit FreezeOracle();
    }

    /// @inheritdoc ICREOracle
    function unfreezeOracle(bytes calldata report) public onlyRole(ORACLE_GUARD_ROLE) {
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
        if (snapshotTimestamp == 0 || block.timestamp - snapshotTimestamp > MAX_ORACLE_AGE) revert OracleStale();
        return (totalAssets, cutoff);
    }

    /// @inheritdoc ICREOracle
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
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlEnumerableUpgradeable, IERC165)
        returns (bool)
    {
        // Chainlink IReceiver adds only onReport to IERC165.
        return interfaceId == ICREOracle.onReport.selector || super.supportsInterface(interfaceId);
    }

    /* INTERNAL FUNCTIONS */

    function _setOracleLimits(uint256 newGrowthBps, uint256 newLossBps) internal {
        if (newGrowthBps > 10_000 || newLossBps > 10_000) revert InvalidOracleLimit();

        maxOracleGrowthBps = newGrowthBps;
        maxOracleLossBps = newLossBps;
        emit SetOracleLimits(newGrowthBps, newLossBps);
    }

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
            block.timestamp - update.snapshotTimestamp > MAX_ORACLE_AGE
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

    /// @dev Binds the adapter and applies the oracle's initial role grants and movement limits.
    function _initialize(uint64, address, bytes memory data) internal override {
        (address adapter_, bytes memory oracleData) = abi.decode(data, (address, bytes));
        adapter = adapter_;
        if (adapter.code.length == 0) revert InvalidAdapter();
        InitParams memory params = abi.decode(oracleData, (InitParams));

        __AccessControlEnumerable_init();
        if (params.defaultAdminRoleHolder != address(0)) _grantRole(DEFAULT_ADMIN_ROLE, params.defaultAdminRoleHolder);
        if (params.oracleGuardRoleHolder != address(0)) _grantRole(ORACLE_GUARD_ROLE, params.oracleGuardRoleHolder);
        if (params.oracleLimitsRoleHolder != address(0)) _grantRole(ORACLE_LIMITS_ROLE, params.oracleLimitsRoleHolder);

        _setOracleLimits(params.maxOracleGrowthBps, params.maxOracleLossBps);
    }
}
