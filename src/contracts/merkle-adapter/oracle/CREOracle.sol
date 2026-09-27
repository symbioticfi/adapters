// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {CREOracleBase} from "./CREOracleBase.sol";

import {ICREOracle, ORACLE_GUARD_ROLE} from "../../../interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {IMerkleAdapterOracle} from "../../../interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {IMerkleAdapter} from "../../../interfaces/IMerkleAdapter.sol";
import {ORACLE_LIMITS_ROLE, ORACLE_LIMIT_PRECISION} from "../../../interfaces/merkle-adapter/oracle/ICREOracleBase.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {Multicallable} from "@symbioticfi/core/src/contracts/common/Multicallable.sol";

/// @title CREOracle
/// @notice Contract for storing MerkleAdapter NAV delivered by an approved CRE forwarder and workflow.
contract CREOracle is Multicallable, MigratableEntity, CREOracleBase, ICREOracle {
    /* IMMUTABLES */

    /// @inheritdoc ICREOracle
    address public immutable WORKFLOW_REGISTRY;

    /// @inheritdoc ICREOracle
    uint48 public immutable MAX_REPORT_AGE;

    /// @inheritdoc ICREOracle
    uint48 public immutable MAX_ORACLE_AGE;

    /// @inheritdoc ICREOracle
    uint48 public immutable REPORT_INTERVAL;

    /* STATE VARIABLES */

    /// @inheritdoc ICREOracle
    address public adapter;

    /// @inheritdoc ICREOracle
    bool public oracleFrozen;

    /// @inheritdoc ICREOracle
    int256 public valuationOffset;

    /// @inheritdoc ICREOracle
    uint48 public snapshotBlock;

    /// @inheritdoc ICREOracle
    uint48 public snapshotTimestamp;

    /// @inheritdoc ICREOracle
    bytes32 public rejectedReportHash;

    /* CONSTRUCTOR */

    /// @dev Pins NAV freshness and a Unix-aligned reporting schedule; forwarder and workflow are set per proxy.
    constructor(
        address newFactory,
        address newWorkflowRegistry,
        uint48 newMaxReportAge,
        uint48 newMaxOracleAge,
        uint48 newReportInterval
    ) MigratableEntity(newFactory) {
        WORKFLOW_REGISTRY = newWorkflowRegistry;
        MAX_REPORT_AGE = newMaxReportAge;
        MAX_ORACLE_AGE = newMaxOracleAge;
        REPORT_INTERVAL = newReportInterval;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ICREOracle
    function setWorkflowId(bytes32 newWorkflowId) public {
        if (WORKFLOW_REGISTRY != msg.sender) revert InvalidCaller();
        workflowId = newWorkflowId;
        emit SetWorkflowId(newWorkflowId);
        delete rejectedReportHash;
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
        if (report.length > 0) {
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
    function validate() public view returns (uint256) {
        if (oracleFrozen) revert OracleFrozen();
        if (snapshotTimestamp == 0 || block.timestamp - snapshotTimestamp > MAX_ORACLE_AGE) revert OracleStale();
        return totalAssets();
    }

    /// @inheritdoc IMerkleAdapterOracle
    function totalAssets() public view returns (uint256) {
        (bool valid, uint256 assets) = _assets(valuationOffset, IMerkleAdapter(adapter).netFlow());
        if (!valid) revert InvalidAssets();
        return assets;
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Applies an authenticated NAV update, or freezes and caches the rejected payload instead of reverting.
    function _onReport(bytes calldata metadata, bytes calldata report) internal override {
        if (address(bytes20(metadata[42:62])) != WORKFLOW_REGISTRY) revert InvalidWorkflow();

        if (report.length != 160) revert InvalidReport();

        Report memory update = abi.decode(report, (Report));
        if (_acceptReport(update, false)) return;

        oracleFrozen = true;
        rejectedReportHash = keccak256(report);
        emit RejectReport(rejectedReportHash, update);
    }

    /// @dev A reviewed report bypasses the freeze and movement limits only.
    function _acceptReport(Report memory update, bool reviewed) internal returns (bool) {
        if (update.chainId != block.chainid || update.adapter != adapter) revert InvalidReport();

        if (
            update.snapshotBlock <= snapshotBlock || update.snapshotBlock >= block.number
                || update.snapshotTimestamp <= snapshotTimestamp || update.snapshotTimestamp > block.timestamp
                || block.timestamp - update.snapshotTimestamp > MAX_REPORT_AGE || snapshotTimestamp > 0
                && update.snapshotTimestamp / REPORT_INTERVAL <= snapshotTimestamp / REPORT_INTERVAL
        ) revert StaleReport();

        if (!reviewed && oracleFrozen || block.timestamp - update.snapshotTimestamp > MAX_ORACLE_AGE) return false;
        if (update.totalAssets > uint256(type(int256).max)) return false;

        int256 flow = IMerkleAdapter(adapter).netFlowAt(update.snapshotBlock);
        (bool valid, uint256 assets) = _assets(valuationOffset, flow);
        if (!valid) return false;
        if (!reviewed) {
            uint256 delta = update.totalAssets >= assets ? update.totalAssets - assets : assets - update.totalAssets;
            if (
                delta > oracleTolerance
                    && delta
                        > assets * (update.totalAssets >= assets ? maxOracleGrowth : maxOracleLoss)
                            / ORACLE_LIMIT_PRECISION
            ) return false;
        }

        if (flow < 0 && int256(update.totalAssets) > type(int256).max + flow) return false;
        int256 nextOffset = int256(update.totalAssets) - flow;
        (valid, assets) = _assets(nextOffset, IMerkleAdapter(adapter).netFlow());
        if (!valid) return false;

        valuationOffset = nextOffset;
        snapshotBlock = update.snapshotBlock;
        snapshotTimestamp = update.snapshotTimestamp;
        IMerkleAdapter(adapter).settleReport(update.snapshotBlock, assets);
        emit OnReport(update.totalAssets, update.snapshotBlock, update.snapshotTimestamp);
        return true;
    }

    /// @dev Signed offsets allow losses; negative or overflowing portfolio values are never valid NAV.
    function _assets(int256 offset, int256 flow) internal pure returns (bool, uint256) {
        // Wrapping is intentional; the sign and ordering checks reject sums outside the nonnegative int256 range.
        unchecked {
            int256 assets = offset + flow;
            if (assets < 0 || flow < 0 && assets > offset) return (false, 0);
            return (true, uint256(assets));
        }
    }

    /// @dev Binds the adapter and forwarder and applies the oracle's initial role grants and movement limits.
    function _initialize(uint64, address, bytes memory data) internal override {
        (adapter, data) = abi.decode(data, (address, bytes));
        InitParams memory params = abi.decode(data, (InitParams));
        forwarder = params.forwarder;
        if (params.defaultAdminRoleHolder != address(0)) _grantRole(DEFAULT_ADMIN_ROLE, params.defaultAdminRoleHolder);
        if (params.oracleLimitsRoleHolder != address(0)) _grantRole(ORACLE_LIMITS_ROLE, params.oracleLimitsRoleHolder);
        _setOracleLimits(params.maxOracleGrowth, params.maxOracleLoss, params.oracleTolerance);
        if (params.oracleGuardRoleHolder != address(0)) _grantRole(ORACLE_GUARD_ROLE, params.oracleGuardRoleHolder);
    }
}
