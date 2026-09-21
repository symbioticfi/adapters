// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {IGuardedCallsCapability} from "../../../interfaces/merkle-adapter/capabilities/IGuardedCallsCapability.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {LibBytes} from "solady/utils/LibBytes.sol";

/// @title GuardedCallsCapability
/// @notice Contract for Merkle-approved protocol calls with Merkle-committed state conditions.
contract GuardedCallsCapability is IGuardedCallsCapability {
    using Address for address;
    using LibBytes for bytes;

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IGuardedCallsCapability
    function execute(Call[] calldata calls, Check[] calldata checks) public returns (bytes[] memory results) {
        if (address(this) != msg.sender) revert InvalidCaller();

        uint256[] memory beforeValues = new uint256[](checks.length);
        for (uint256 i; i < checks.length; ++i) {
            Check calldata condition = checks[i];
            if (condition.observation != Observation.After) beforeValues[i] = _read(condition);
            if (condition.observation == Observation.Before) {
                _check(beforeValues[i], calls, condition);
            }
        }
        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            results[i] = calls[i].target.functionCall(calls[i].data);
        }
        for (uint256 i; i < checks.length; ++i) {
            Check calldata condition = checks[i];
            if (condition.observation == Observation.Before) continue;
            uint256 value = _read(condition);
            if (condition.observation == Observation.Increase) value -= beforeValues[i];
            else if (condition.observation == Observation.Decrease) value = beforeValues[i] - value;
            _check(value, calls, condition);
        }
    }

    /* INTERNAL FUNCTIONS */

    function _read(Check calldata condition) internal view returns (uint256) {
        bytes memory result = condition.query.target.functionStaticCall(condition.query.data);
        if (condition.offset + 32 > result.length) revert();
        return uint256(result.load(condition.offset));
    }

    function _check(uint256 value, Call[] calldata calls, Check calldata condition) internal pure {
        Bound calldata bound = condition.bound;
        uint256 limit = bound.source == Source.Constant
            ? bound.value
            : abi.decode(calls[bound.value].data[bound.offset:bound.offset + 32], (uint256));
        if (
            condition.comparison == Comparison.Equal && value != limit
                || condition.comparison == Comparison.GreaterOrEqual && value < limit
                || condition.comparison == Comparison.LessOrEqual && value > limit
        ) revert CheckFailed();
    }
}
