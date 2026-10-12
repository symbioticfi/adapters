// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {
    IRecipes,
    NUMERICAL_OPERATIONS,
    OP_ADD,
    OP_CALL,
    OP_CALL_IF,
    OP_EQUAL,
    OP_LESS_OR_EQUAL,
    OP_MAX,
    OP_MIN,
    OP_MUL_DIV,
    OP_READ,
    OP_READ_CACHED,
    OP_READ_IF,
    OP_READ_WORD,
    OP_SATURATING_SUB,
    OP_SUB,
    SRC_INPUT,
    SRC_LITERAL,
    SRC_RESULT
} from "../../interfaces/merkle-adapter/IRecipes.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LibBytes} from "solady/utils/LibBytes.sol";

/// @title Recipes
/// @notice Base contract for the stateless interpreter shared by executor and account capability recipes.
/// @dev Authorization and account management belong to the concrete execution wrapper.
abstract contract Recipes is IRecipes {
    using Address for address;
    using LibBytes for bytes;
    using Math for uint256;

    /* INTERNAL FUNCTIONS */

    function _run(bytes[] calldata queries, bytes[] calldata steps, uint256[] calldata inputs, State memory state)
        internal
        returns (uint256)
    {
        (uint8 operation, bytes calldata operationData) = _step(steps[state.index]);
        if (operation == OP_READ || (operation == OP_READ_IF || operation == OP_READ_CACHED)) {
            uint256 queryIndex;
            if (operation == OP_READ_IF) {
                uint256 gate;
                uint256 fallbackValue;
                (gate, queryIndex, fallbackValue) = abi.decode(operationData, (uint256, uint256, uint256));
                if (_value(gate, steps, inputs, state) == 0) return _value(fallbackValue, steps, inputs, state);
            } else {
                queryIndex = abi.decode(operationData, (uint256));
            }
            (address target, bytes memory data, uint256[] memory bindings, uint256 offset) =
                abi.decode(queries[queryIndex], (address, bytes, uint256[], uint256));
            _bind(data, bindings, steps, inputs, state);
            bytes memory result = target.functionStaticCall(data);
            if (offset + 32 > result.length) revert InvalidQuery();
            if (operation == OP_READ_CACHED) {
                state.readData = result;
                state.readIndex = state.index + 1;
            }
            return uint256(result.load(offset));
        } else if (operation == OP_CALL || operation == OP_CALL_IF) {
            address target;
            bytes memory data;
            uint256[] memory bindings;
            if (operation == OP_CALL_IF) {
                if (_value(abi.decode(operationData, (uint256)), steps, inputs, state) == 0) return 0;
                (, target, data, bindings) = abi.decode(operationData, (uint256, address, bytes, uint256[]));
            } else {
                (target, data, bindings) = abi.decode(operationData, (address, bytes, uint256[]));
            }
            _bind(data, bindings, steps, inputs, state);
            target.functionCall(data);
        } else if (operation <= OP_LESS_OR_EQUAL) {
            (uint256 a, uint256 b) = abi.decode(operationData, (uint256, uint256));
            a = _value(a, steps, inputs, state);
            b = _value(b, steps, inputs, state);
            if (operation == OP_ADD) return a + b;
            if (operation == OP_SUB) return a - b;
            if (operation == OP_SATURATING_SUB) return a.saturatingSub(b);
            if (operation == OP_MIN) return Math.min(a, b);
            if (operation == OP_MAX) return Math.max(a, b);
            if (operation == OP_MUL_DIV) {
                // The first two packed operands occupy 64 bytes.
                return a * b / _value(abi.decode(operationData[64:], (uint256)), steps, inputs, state);
            }
            if (operation == OP_EQUAL ? a != b : a > b) revert CheckFailed();
        } else if (operation == OP_READ_WORD) {
            (uint256 producerIndex, uint256 offset) = abi.decode(operationData, (uint256, uint256));
            if (
                producerIndex >= state.index || state.readIndex != producerIndex + 1
                    || uint8(steps[producerIndex][0]) != OP_READ_CACHED
            ) revert InvalidReference();
            if (offset + 32 > state.readData.length) revert InvalidQuery();
            return uint256(state.readData.load(offset));
        } else {
            revert InvalidOperation();
        }
        return 0;
    }

    function _step(bytes calldata operationAndData) internal pure returns (uint8 operation, bytes calldata data) {
        return (uint8(operationAndData[0]), operationAndData[1:]);
    }

    function _value(uint256 srcAndValue, bytes[] calldata steps, uint256[] calldata inputs, State memory state)
        internal
        pure
        returns (uint256)
    {
        uint8 src = uint8(srcAndValue >> 216);
        uint256 value = uint216(srcAndValue);
        if (src == SRC_LITERAL) return value;
        if (src == SRC_INPUT) return inputs[value];
        if (src != SRC_RESULT) revert InvalidReference();
        if (value >= state.index) revert InvalidReference();
        uint8 operation = uint8(steps[value][0]);
        if (NUMERICAL_OPERATIONS >> operation & 1 == 0) revert InvalidReference();
        return state.values[value];
    }

    function _bind(
        bytes memory data,
        uint256[] memory bindings,
        bytes[] calldata steps,
        uint256[] calldata inputs,
        State memory state
    ) internal pure {
        uint256 end = 4;
        uint256 bindingsLength = bindings.length;
        uint256 dataLength = data.length;
        for (uint256 i; i < bindingsLength; ++i) {
            uint256 offset = bindings[i] >> 224;
            if (offset < end) revert InvalidCall();
            end = offset + 32;
            if (end > dataLength) revert InvalidCall();
            uint256 value = _value(bindings[i], steps, inputs, state);
            assembly ("memory-safe") {
                mstore(add(add(data, 32), offset), value)
            }
        }
    }
}
