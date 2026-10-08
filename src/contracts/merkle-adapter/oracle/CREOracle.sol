// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {
    ICREOracle,
    ORACLE_GUARD_ROLE,
    ORACLE_LIMITS_ROLE,
    ORACLE_LIMIT_PRECISION
} from "../../../interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ICREWorkflowRegistry} from "../../../interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {IMerkleAdapterOracle} from "../../../interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {IMerkleAdapter} from "../../../interfaces/IMerkleAdapter.sol";

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {Multicallable} from "@symbioticfi/core/src/contracts/common/Multicallable.sol";

/// @title CREOracle
/// @notice Contract for storing MerkleAdapter NAV delivered by an approved CRE forwarder and workflow.
contract CREOracle is Multicallable, MigratableEntity, AccessControlEnumerableUpgradeable, ICREOracle {
    using SafeCast for int256;
    using SafeCast for uint256;

    /* IMMUTABLES */

    /// @inheritdoc ICREOracle
    address public immutable WORKFLOW_REGISTRY;

    /// @inheritdoc ICREOracle
    address public immutable FORWARDER;

    /// @inheritdoc IMerkleAdapterOracle
    uint48 public immutable MAX_REPORT_AGE;

    /* STATE VARIABLES */

    /// @inheritdoc ICREOracle
    uint32 public maxOracleGrowth;

    /// @inheritdoc ICREOracle
    uint32 public maxOracleLoss;

    /// @inheritdoc ICREOracle
    uint128 public oracleTolerance;

    /// @inheritdoc ICREOracle
    address public adapter;

    /// @inheritdoc IMerkleAdapterOracle
    uint256 public totalAssets;

    /// @inheritdoc IMerkleAdapterOracle
    uint48 public snapshotBlock;

    /// @inheritdoc IMerkleAdapterOracle
    uint48 public snapshotTimestamp;

    /// @inheritdoc ICREOracle
    bytes32 public rejectedReportHash;

    /* CONSTRUCTOR */

    /// @dev Pins report authentication and freshness; the registry stores each proxy's workflow.
    constructor(address newFactory, address newWorkflowRegistry, address newForwarder, uint48 newMaxReportAge)
        MigratableEntity(newFactory)
    {
        WORKFLOW_REGISTRY = newWorkflowRegistry;
        FORWARDER = newForwarder;
        MAX_REPORT_AGE = newMaxReportAge;
    }

    /* VIEW FUNCTIONS */

    /// @inheritdoc IMerkleAdapterOracle
    function latestSnapshot() public view returns (uint48 reportBlock, uint256 assets) {
        if (snapshotTimestamp == 0 || block.timestamp - snapshotTimestamp > MAX_REPORT_AGE) revert OracleStale();
        return (snapshotBlock, totalAssets);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlEnumerableUpgradeable, IERC165)
        returns (bool)
    {
        // Chainlink IReceiver adds only onReport to IERC165.
        return interfaceId == ICREOracle.onReport.selector || super.supportsInterface(interfaceId);
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ICREOracle
    function setOracleLimits(uint32 newGrowth, uint32 newLoss, uint128 newTolerance)
        public
        onlyRole(ORACLE_LIMITS_ROLE)
    {
        _setOracleLimits(newGrowth, newLoss, newTolerance);
    }

    /// @inheritdoc ICREOracle
    function acceptReport(bytes calldata data) public onlyRole(ORACLE_GUARD_ROLE) {
        if (keccak256(data) != rejectedReportHash) revert InvalidReport();
        _onReport(data, true);
        delete rejectedReportHash;
        emit AcceptReport(data);
    }

    /// @inheritdoc ICREOracle
    function onReport(bytes calldata metadata, bytes calldata data) public {
        if (FORWARDER != msg.sender) revert InvalidSender();

        // KeystoneForwarder includes a trailing bytes2 report ID.
        if (
            metadata.length != 64 || address(bytes20(metadata[42:62])) != WORKFLOW_REGISTRY
                || bytes32(metadata[:32]) == bytes32(0)
                || bytes32(metadata[:32]) != ICREWorkflowRegistry(WORKFLOW_REGISTRY).workflowId(address(this))
        ) revert InvalidWorkflow();
        if (data.length != 160) revert InvalidReport();
        _onReport(data, false);
    }

    /* INTERNAL FUNCTIONS */

    function _setOracleLimits(uint32 newGrowth, uint32 newLoss, uint128 newTolerance) internal {
        if (newGrowth > ORACLE_LIMIT_PRECISION || newLoss > ORACLE_LIMIT_PRECISION) revert InvalidOracleLimit();

        maxOracleGrowth = newGrowth;
        maxOracleLoss = newLoss;
        oracleTolerance = newTolerance;
        emit SetOracleLimits(newGrowth, newLoss, newTolerance);
    }

    /// @dev A reviewed report bypasses movement limits only.
    function _onReport(bytes calldata data, bool reviewed) internal {
        Report memory report = abi.decode(data, (Report));
        if (report.chainId != block.chainid || report.adapter != adapter) revert InvalidReport();

        if (
            report.snapshotBlock <= snapshotBlock || report.snapshotBlock >= block.number
                || report.snapshotTimestamp <= snapshotTimestamp || report.snapshotTimestamp > block.timestamp
                || block.timestamp - report.snapshotTimestamp > MAX_REPORT_AGE
        ) revert StaleReport();

        int256 newFlow = IMerkleAdapter(adapter).netFlowAt(report.snapshotBlock);
        if (report.totalAssets.toInt256() - newFlow + IMerkleAdapter(adapter).netFlow() < 0) revert InvalidAssets();
        uint256 baseline =
            (int256(totalAssets) - IMerkleAdapter(adapter).netFlowAt(snapshotBlock) + newFlow).toUint256();
        if (!reviewed) {
            bool grows = report.totalAssets >= baseline;
            uint256 delta = grows ? report.totalAssets - baseline : baseline - report.totalAssets;
            if (
                delta > oracleTolerance
                    && delta > baseline * (grows ? maxOracleGrowth : maxOracleLoss) / ORACLE_LIMIT_PRECISION
            ) {
                rejectedReportHash = keccak256(data);
                emit OnReport(report, true);
                return;
            }
        }
        totalAssets = report.totalAssets;
        snapshotBlock = report.snapshotBlock;
        snapshotTimestamp = report.snapshotTimestamp;
        emit OnReport(report, false);
    }

    /* INITIALIZATION */

    /// @dev Binds the adapter and applies the oracle's initial role grants and movement limits.
    function _initialize(uint64, address, bytes memory data) internal override {
        (adapter, data) = abi.decode(data, (address, bytes));
        InitParams memory params = abi.decode(data, (InitParams));

        _setOracleLimits(params.maxOracleGrowth, params.maxOracleLoss, params.oracleTolerance);

        if (params.defaultAdminRoleHolder != address(0)) _grantRole(DEFAULT_ADMIN_ROLE, params.defaultAdminRoleHolder);
        if (params.oracleLimitsRoleHolder != address(0)) _grantRole(ORACLE_LIMITS_ROLE, params.oracleLimitsRoleHolder);
        if (params.oracleGuardRoleHolder != address(0)) _grantRole(ORACLE_GUARD_ROLE, params.oracleGuardRoleHolder);
    }
}
