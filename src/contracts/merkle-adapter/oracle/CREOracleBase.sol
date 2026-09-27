// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {
    ICREOracleBase,
    ORACLE_LIMITS_ROLE,
    ORACLE_LIMIT_PRECISION
} from "../../../interfaces/merkle-adapter/oracle/ICREOracleBase.sol";

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title CREOracleBase
/// @notice Base contract for a CRE receiver with workflow authentication and role-controlled movement limits.
/// @dev Implementations initialize receiver settings, govern workflowId and handle verified payloads in _onReport.
abstract contract CREOracleBase is AccessControlEnumerableUpgradeable, ICREOracleBase {
    using SafeCast for uint256;

    /* STATE VARIABLES */

    /// @inheritdoc ICREOracleBase
    address public forwarder;

    /// @inheritdoc ICREOracleBase
    bytes32 public workflowId;

    /// @inheritdoc ICREOracleBase
    uint32 public maxOracleGrowth;

    /// @inheritdoc ICREOracleBase
    uint32 public maxOracleLoss;

    /// @inheritdoc ICREOracleBase
    uint128 public oracleTolerance;

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ICREOracleBase
    function setOracleLimits(uint256 newGrowth, uint256 newLoss, uint256 newTolerance)
        public
        onlyRole(ORACLE_LIMITS_ROLE)
    {
        _setOracleLimits(newGrowth, newLoss, newTolerance);
    }

    /// @inheritdoc ICREOracleBase
    function onReport(bytes calldata metadata, bytes calldata report) public {
        if (forwarder != msg.sender) revert InvalidSender();

        // Production KeystoneForwarder includes a trailing bytes2 report ID.
        if (workflowId == bytes32(0) || metadata.length != 64 || bytes32(metadata[:32]) != workflowId) {
            revert InvalidWorkflow();
        }

        _onReport(metadata, report);
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
        return interfaceId == ICREOracleBase.onReport.selector || super.supportsInterface(interfaceId);
    }

    /* INTERNAL FUNCTIONS */

    function _setOracleLimits(uint256 newGrowth, uint256 newLoss, uint256 newTolerance) internal {
        if (newGrowth > ORACLE_LIMIT_PRECISION || newLoss > ORACLE_LIMIT_PRECISION) revert InvalidOracleLimit();

        maxOracleGrowth = uint32(newGrowth);
        maxOracleLoss = uint32(newLoss);
        oracleTolerance = newTolerance.toUint128();
        emit SetOracleLimits(newGrowth, newLoss, newTolerance);
    }

    /// @dev Handles metadata and payload delivered by the forwarder for the accepted workflow.
    function _onReport(bytes calldata metadata, bytes calldata report) internal virtual;
}
