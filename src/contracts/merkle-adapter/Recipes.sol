// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {
    IRecipes,
    OP_ADD,
    OP_CALL,
    OP_EQUAL,
    OP_LESS_OR_EQUAL,
    OP_MAX,
    OP_MIN,
    OP_MUL_DIV,
    OP_READ,
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

    function _execute(
        bytes[] calldata queries,
        bytes[] calldata steps,
        uint256[] calldata inputs,
        bytes[] calldata runtime
    ) internal returns (uint256[] memory) {
        uint256 stepsLength = steps.length;
        Execution memory state =
            Execution({inputs: inputs, values: new uint256[](stepsLength), index: 0, runtimeIndex: 0});
        for (; state.index < stepsLength; ++state.index) {
            state.values[state.index] = _run(queries, steps, runtime, state);
        }
        if (state.runtimeIndex != runtime.length) revert InvalidRuntime();
        return state.values;
    }

    // A separate instruction frame keeps nested ABI decoders within the non-IR stack limit.
    function _run(bytes[] calldata queries, bytes[] calldata steps, bytes[] calldata, Execution memory state)
        internal
        virtual
        returns (uint256)
    {
        (uint8 operation, bytes calldata operationData) = _step(steps[state.index]);
        if (operation == OP_READ) {
            (address target, bytes memory data, uint256[] memory bindings, uint256 offset) =
                abi.decode(queries[abi.decode(operationData, (uint256))], (address, bytes, uint256[], uint256));
            _bind(data, bindings, steps, state);
            bytes memory result = target.functionStaticCall(data);
            if (offset + 32 > result.length) revert InvalidQuery();
            return uint256(result.load(offset));
        } else if (operation == OP_CALL) {
            (address target, bytes memory data, uint256[] memory bindings) =
                abi.decode(operationData, (address, bytes, uint256[]));
            _bind(data, bindings, steps, state);
            target.functionCall(data);
        } else if (operation <= OP_LESS_OR_EQUAL) {
            (uint256 a, uint256 b) = abi.decode(operationData, (uint256, uint256));
            a = _value(a, steps, state);
            b = _value(b, steps, state);
            if (operation == OP_ADD) return a + b;
            if (operation == OP_SUB) return a - b;
            if (operation == OP_SATURATING_SUB) return a.saturatingSub(b);
            if (operation == OP_MIN) return Math.min(a, b);
            if (operation == OP_MAX) return Math.max(a, b);
            if (operation == OP_MUL_DIV) {
                // The first two packed operands occupy 64 bytes.
                return a * b / _value(abi.decode(operationData[64:], (uint256)), steps, state);
            }
            if (operation == OP_EQUAL ? a != b : a > b) revert CheckFailed();
        } else {
            revert InvalidOperation();
        }
        return 0;
    }

    function _step(bytes calldata operationAndData) internal pure returns (uint8 operation, bytes calldata data) {
        return (uint8(operationAndData[0]), operationAndData[1:]);
    }

    function _value(uint256 srcAndValue, bytes[] calldata steps, Execution memory state)
        internal
        pure
        returns (uint256)
    {
        uint8 src = uint8(srcAndValue >> 216);
        uint256 value = uint216(srcAndValue);
        if (src == SRC_LITERAL) return value;
        if (src == SRC_INPUT) return state.inputs[value];
        if (src != SRC_RESULT) revert InvalidReference();
        if (value >= state.index || uint8(steps[value][0]) > OP_MUL_DIV) revert InvalidReference();
        return state.values[value];
    }

    function _bind(bytes memory data, uint256[] memory bindings, bytes[] calldata steps, Execution memory state)
        internal
        pure
    {
        uint256 end = 4;
        uint256 bindingsLength = bindings.length;
        uint256 dataLength = data.length;
        for (uint256 i; i < bindingsLength; ++i) {
            uint256 offset = bindings[i] >> 224;
            if (offset < end) revert InvalidCall();
            end = offset + 32;
            if (end > dataLength) revert InvalidCall();
            uint256 value = _value(bindings[i], steps, state);
            assembly ("memory-safe") {
                mstore(add(add(data, 32), offset), value)
            }
        }
    }
}
