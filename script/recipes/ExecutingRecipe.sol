// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {
    NUMERICAL_OPERATIONS,
    OP_ADD,
    OP_APPROVE,
    OP_CALL,
    OP_CALL_IF,
    OP_CLEAR_APPROVAL,
    OP_EQUAL,
    OP_LESS_OR_EQUAL,
    OP_MANAGE,
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
    SRC_RESULT
} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {LibBytes} from "solady/utils/LibBytes.sol";

/**
 * @title ExecutingRecipe
 * @notice Library for compiling approved actions, reads and conditions into one committed recipe.
 * @dev Action methods return runtime-payload indices; values reference instruction indices.
 * Arithmetic and checks are optimized as they are built, so returned operands may also be literals.
 * Use returned operands and runtimeSteps rather than predicting instruction indices. balance reuses ERC20
 * balances until the next action; generic reads stay fresh. instruction emits an unoptimized instruction.
 */
library ExecutingRecipe {
    using LibBytes for bytes;
    using SafeCast for uint256;

    error InvalidConfiguration();

    // Script-only containers; the executor ABI accepts arrays and native query tuples.
    struct Recipe {
        bytes[] queries;
        bytes[] steps;
    }

    struct Query {
        address target;
        bytes data;
        uint256[] bindings;
        uint256 offset;
    }

    struct Read {
        address target;
        bytes data;
        uint256 offset;
    }

    struct Call {
        address target;
        bytes data;
    }

    struct Source {
        // Optional executor-origin call, performed only while the requested cash is still missing.
        Call prepare;
        // An empty query on the final external source requests the full remaining shortfall.
        Read capacity;
        bytes32[] leaves;
        uint256[][] amountOffsets;
    }

    struct Funding {
        address adapter;
        address account;
        bytes32 pushLeaf;
        address asset;
        // Skip unused capacity and post-withdrawal balance reads.
        bool skipUnusedReads;
        Source[] sources;
    }

    struct Builder {
        bytes[] steps;
        bytes[] queries;
        uint256 length;
        uint256 queryLength;
        uint256 runtimeLength;
    }

    function start(uint256 capacity) internal pure returns (Builder memory builder) {
        builder.steps = new bytes[](capacity);
        builder.queries = new bytes[](capacity);
    }

    function literal(Builder memory, uint256 value) internal pure returns (uint256) {
        return value.toUint216();
    }

    function input(Builder memory, uint256 index) internal pure returns (uint256) {
        return uint256(SRC_INPUT) << 216 | index.toUint216();
    }

    function result(uint256 index) internal pure returns (uint256) {
        return uint256(SRC_RESULT) << 216 | index.toUint216();
    }

    function binding(uint256 offset, uint256 srcAndValue) internal pure returns (uint256) {
        return uint256(offset.toUint32()) << 224 | srcAndValue.toUint224();
    }

    function query(Read memory readConfig) internal pure returns (Query memory) {
        return Query({
            target: readConfig.target, data: readConfig.data, bindings: new uint256[](0), offset: readConfig.offset
        });
    }

    function balanceQuery(address token, address account) internal pure returns (Query memory) {
        return query(Read({target: token, data: abi.encodeCall(IERC20.balanceOf, (account)), offset: 0}));
    }

    function read(Builder memory builder, Read memory readConfig) internal pure returns (uint256) {
        return readQuery(builder, query(readConfig));
    }

    function readQuery(Builder memory builder, Query memory readConfig) internal pure returns (uint256) {
        return _read(builder, readConfig, 1, 0, false);
    }

    function readCached(Builder memory builder, Read memory readConfig) internal pure returns (uint256) {
        return readCachedQuery(builder, query(readConfig));
    }

    function readCachedQuery(Builder memory builder, Query memory readConfig) internal pure returns (uint256) {
        return _read(builder, readConfig, 1, 0, true);
    }

    function readWord(Builder memory builder, uint256 cachedRead, uint256 offset) internal pure returns (uint256) {
        if (
            cachedRead > type(uint224).max || uint8(cachedRead >> 216) != SRC_RESULT
                || uint216(cachedRead) >= builder.length
                || uint8(builder.steps[uint216(cachedRead)][0]) != OP_READ_CACHED
        ) revert InvalidConfiguration();
        // Only the most recent explicit cached read retains its complete response.
        for (uint256 i = uint256(uint216(cachedRead)) + 1; i < builder.length; ++i) {
            if (uint8(builder.steps[i][0]) == OP_READ_CACHED) revert InvalidConfiguration();
        }
        return result(instruction(builder, OP_READ_WORD, abi.encode(uint256(uint216(cachedRead)), offset)));
    }

    function readIf(Builder memory builder, Query memory readConfig, uint256 gate, uint256 fallbackValue)
        internal
        pure
        returns (uint256)
    {
        return _read(builder, readConfig, gate, fallbackValue, false);
    }

    function balance(Builder memory builder, address token, address account) internal pure returns (uint256) {
        // ERC20 balances are stable between actions. Use readQuery directly for nonstandard, volatile getters.
        bytes32 hash = keccak256(abi.encode(token, abi.encodeCall(IERC20.balanceOf, (account)), new uint256[](0), 0));
        for (uint256 i = builder.length; i > 0;) {
            bytes memory step = builder.steps[--i];
            uint8 operation = uint8(step[0]);
            if (
                operation == OP_MANAGE || operation == OP_APPROVE || operation == OP_CALL || operation == OP_CALL_IF
                    || operation == OP_CLEAR_APPROVAL
            ) break;
            if (operation == OP_READ && step.length >= 33) {
                uint256 index = uint256(step.load(1));
                if (index < builder.queryLength && keccak256(builder.queries[index]) == hash) return result(i);
            }
        }
        return readQuery(builder, balanceQuery(token, account));
    }

    function binary(Builder memory builder, uint8 operation, uint256 a, uint256 b) internal pure returns (uint256) {
        if (a <= type(uint216).max && b <= type(uint216).max) {
            if (operation == OP_ADD && a + b <= type(uint216).max) return a + b;
            if (operation == OP_SUB && a >= b) return a - b;
            if (operation == OP_SATURATING_SUB) return a > b ? a - b : 0;
            if (operation == OP_MIN) return a < b ? a : b;
            if (operation == OP_MAX) return a > b ? a : b;
        }
        if (
            (b == 0
                    && (operation == OP_ADD
                        || operation == OP_SUB
                        || operation == OP_SATURATING_SUB
                        || operation == OP_MAX)
                    || a == b
                    && (operation == OP_MIN || operation == OP_MAX)) && _resolved(builder, a)
        ) return a;
        if (a == 0 && (operation == OP_ADD || operation == OP_MAX) && _resolved(builder, b)) return b;
        return result(_reuse(builder, operation, abi.encode(a, b)));
    }

    function mulDiv(Builder memory builder, uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        // The interpreter checks the product before division; cancellation must not hide an overflow.
        if (
            a <= type(uint216).max && b <= type(uint216).max && c > 0 && c <= type(uint216).max
                && (b == 0 || a <= type(uint256).max / b)
        ) {
            uint256 value = a * b / c;
            if (value <= type(uint216).max) return value;
        }
        if (c > 0 && c <= type(uint216).max && (b == 0 && _resolved(builder, a) || a == 0 && _resolved(builder, b))) {
            return 0;
        }
        if (b == 1 && c == 1 && _resolved(builder, a)) return a;
        if (a == 1 && c == 1 && _resolved(builder, b)) return b;
        return result(_reuse(builder, OP_MUL_DIV, abi.encode(a, b, c)));
    }

    function check(Builder memory builder, uint8 comparison, uint256 a, uint256 b) internal pure {
        if (comparison != OP_EQUAL && comparison != OP_LESS_OR_EQUAL) {
            revert InvalidConfiguration();
        }
        if (
            a == b && _resolved(builder, a) || comparison == OP_LESS_OR_EQUAL
                && (a <= type(uint216).max && b <= type(uint216).max && a <= b || a == 0 && _resolved(builder, b))
        ) return;
        _reuse(builder, comparison, abi.encode(a, b));
    }

    function manage(Builder memory builder, bytes32[] memory leaves, uint256 amount) internal pure returns (uint256) {
        return manage(builder, leaves, amount, new uint256[][](leaves.length));
    }

    function manage(Builder memory builder, bytes32[] memory leaves, uint256 amount, uint256[][] memory bindings)
        internal
        pure
        returns (uint256)
    {
        if (bindings.length != leaves.length) revert InvalidConfiguration();
        instruction(builder, OP_MANAGE, abi.encode(amount, leaves, bindings));
        return builder.runtimeLength - 1;
    }

    function approve(Builder memory builder, address token, address spender, bytes32 leaf, uint256 amount)
        internal
        pure
        returns (uint256)
    {
        instruction(builder, OP_APPROVE, abi.encode(amount, token, spender, leaf));
        return builder.runtimeLength - 1;
    }

    function clearApproval(Builder memory builder, address token, address spender, bytes32 leaf, bool skipZero)
        internal
        pure
        returns (uint256)
    {
        if (!skipZero) return approve(builder, token, spender, leaf, 0);
        instruction(builder, OP_CLEAR_APPROVAL, abi.encode(token, spender, leaf));
        return builder.runtimeLength - 1;
    }

    function call(Builder memory builder, address target, bytes memory data, uint256[] memory bindings)
        internal
        pure
        returns (uint256)
    {
        return instruction(builder, OP_CALL, abi.encode(target, data, bindings));
    }

    function callIf(Builder memory builder, uint256 gate, address target, bytes memory data, uint256[] memory bindings)
        internal
        pure
        returns (uint256)
    {
        return instruction(builder, OP_CALL_IF, abi.encode(gate, target, data, bindings));
    }

    function instruction(Builder memory builder, uint8 operation, bytes memory data)
        internal
        pure
        returns (uint256 index)
    {
        if (operation > OP_CALL_IF) revert InvalidConfiguration();
        uint256 length = builder.length;
        if (length == builder.steps.length) {
            bytes[] memory extended = new bytes[](length * 2 + 1);
            bytes[] memory queries = new bytes[](extended.length);
            for (uint256 i; i < length; ++i) {
                extended[i] = builder.steps[i];
            }
            uint256 queryLength = builder.queryLength;
            for (uint256 i; i < queryLength; ++i) {
                queries[i] = builder.queries[i];
            }
            builder.steps = extended;
            builder.queries = queries;
        }
        index = builder.length++;
        builder.steps[index] = abi.encodePacked(operation, data);
        if (operation == OP_MANAGE || operation == OP_APPROVE || operation == OP_CLEAR_APPROVAL) {
            ++builder.runtimeLength;
        }
    }

    function amountBindings(uint256[][] memory offsets, uint256 amount)
        internal
        pure
        returns (uint256[][] memory bindings)
    {
        uint256 length = offsets.length;
        bindings = new uint256[][](length);
        for (uint256 i; i < length; ++i) {
            uint256 offsetsLength = offsets[i].length;
            bindings[i] = new uint256[](offsetsLength);
            for (uint256 j; j < offsetsLength; ++j) {
                bindings[i][j] = binding(offsets[i][j], amount);
            }
        }
    }

    function fund(Builder memory builder, Funding memory funding, uint256 amount)
        internal
        pure
        returns (uint256[] memory sourceCalls, uint256[] memory sourceAmounts)
    {
        bool push = funding.pushLeaf != bytes32(0);
        uint256 length = funding.sources.length + (push ? 1 : 0);
        sourceCalls = new uint256[](length);
        sourceAmounts = new uint256[](length);
        uint256 cash;
        for (uint256 i; i < length; ++i) {
            Source memory source;
            uint256 capacity;
            if (push && i == 0) {
                if (funding.skipUnusedReads) cash = balance(builder, funding.asset, funding.account);
                capacity = _pushCapacity(
                    builder, funding, funding.skipUnusedReads ? binary(builder, OP_SATURATING_SUB, amount, cash) : 1
                );
                source.leaves = new bytes32[](1);
                source.leaves[0] = funding.pushLeaf;
                source.amountOffsets = new uint256[][](1);
                source.amountOffsets[0] = new uint256[](1);
                source.amountOffsets[0][0] = 4;
            } else {
                source = funding.sources[push ? i - 1 : i];
                if (source.prepare.target == address(0)) {
                    if (source.prepare.data.length > 0) revert InvalidConfiguration();
                } else {
                    if (!funding.skipUnusedReads || i == 0) cash = balance(builder, funding.asset, funding.account);
                    callIf(
                        builder,
                        binary(builder, OP_SATURATING_SUB, amount, cash),
                        source.prepare.target,
                        source.prepare.data,
                        new uint256[](0)
                    );
                }
                if (funding.skipUnusedReads && (i == 0 || source.prepare.target != address(0))) {
                    cash = balance(builder, funding.asset, funding.account);
                }
                if (source.capacity.target == address(0)) {
                    if (i + 1 != length) revert InvalidConfiguration();
                    if (source.capacity.data.length > 0 || source.capacity.offset > 0) revert InvalidConfiguration();
                } else {
                    capacity = funding.skipUnusedReads
                        ? readIf(builder, query(source.capacity), binary(builder, OP_SATURATING_SUB, amount, cash), 0)
                        : read(builder, source.capacity);
                }
            }
            if (!funding.skipUnusedReads) cash = balance(builder, funding.asset, funding.account);
            uint256 take = binary(builder, OP_SATURATING_SUB, amount, cash);
            if (push && i == 0 || source.capacity.target != address(0)) take = binary(builder, OP_MIN, take, capacity);
            sourceAmounts[i] = uint216(take);
            sourceCalls[i] = manage(builder, source.leaves, take, amountBindings(source.amountOffsets, take));
            capacity = funding.skipUnusedReads
                ? readIf(builder, balanceQuery(funding.asset, funding.account), take, cash)
                : balance(builder, funding.asset, funding.account);
            check(builder, OP_EQUAL, binary(builder, OP_SUB, capacity, cash), take);
            cash = capacity;
        }
    }

    function _pushCapacity(Builder memory builder, Funding memory funding, uint256 gate)
        private
        pure
        returns (uint256)
    {
        uint256 released = readIf(
            builder,
            query(
                Read({target: funding.adapter, data: abi.encodeCall(IMerkleAdapter.releasedLiquidity, ()), offset: 0})
            ),
            gate,
            0
        );
        uint256 staged = readIf(
            builder,
            query(Read({target: funding.adapter, data: abi.encodeCall(IMerkleAdapter.stagedLiquidity, ()), offset: 0})),
            gate,
            0
        );
        uint256 locked = binary(builder, OP_ADD, released, staged);
        uint256 pending = readIf(
            builder,
            query(
                Read({target: funding.adapter, data: abi.encodeCall(IMerkleAdapter.pendingDeallocation, ()), offset: 0})
            ),
            gate,
            0
        );
        locked = binary(builder, OP_MAX, locked, pending);
        return binary(
            builder,
            OP_SATURATING_SUB,
            funding.skipUnusedReads
                ? readIf(builder, balanceQuery(funding.asset, funding.adapter), gate, 0)
                : balance(builder, funding.asset, funding.adapter),
            locked
        );
    }

    function finish(Builder memory builder) internal pure returns (Recipe memory recipe) {
        recipe.steps = builder.steps;
        recipe.queries = builder.queries;
        uint256 length = builder.length;
        uint256 queryLength = builder.queryLength;
        assembly ("memory-safe") {
            mstore(mload(add(recipe, 32)), length)
            mstore(mload(recipe), queryLength)
        }
    }

    function runtimeSteps(Recipe memory recipe) internal pure returns (uint256[] memory indices) {
        uint256 stepsLength = recipe.steps.length;
        indices = new uint256[](stepsLength);
        uint256 length;
        for (uint256 i; i < stepsLength; ++i) {
            uint8 operation = uint8(recipe.steps[i][0]);
            if (operation > OP_CALL_IF) revert InvalidConfiguration();
            if (operation == OP_MANAGE || operation == OP_APPROVE || operation == OP_CLEAR_APPROVAL) {
                indices[length++] = i;
            }
        }
        assembly ("memory-safe") { mstore(indices, length) }
    }

    function _read(Builder memory builder, Query memory readConfig, uint256 gate, uint256 fallbackValue, bool cached)
        private
        pure
        returns (uint256)
    {
        uint256 index;
        bytes memory encoded = abi.encode(readConfig.target, readConfig.data, readConfig.bindings, readConfig.offset);
        bytes32 hash = keccak256(encoded);
        uint256 queryLength = builder.queryLength;
        while (index < queryLength && keccak256(builder.queries[index]) != hash) ++index;
        uint256 value = result(
            cached || gate > 0 && gate <= type(uint216).max
                ? instruction(builder, cached ? OP_READ_CACHED : OP_READ, abi.encode(index))
                : instruction(builder, OP_READ_IF, abi.encode(gate, index, fallbackValue))
        );
        if (index == queryLength) {
            builder.queries[builder.queryLength++] = encoded;
        }
        return value;
    }

    // Reusing a successful calculation or check is safe across actions: inputs and earlier results are immutable.
    // Reads are deliberately excluded, even without an intervening action, since queries may depend on gasleft().
    function _reuse(Builder memory builder, uint8 operation, bytes memory data) private pure returns (uint256) {
        if (operation > OP_READ && operation <= OP_LESS_OR_EQUAL) {
            bytes32 hash = keccak256(abi.encodePacked(operation, data));
            uint256 length = builder.length;
            for (uint256 i; i < length; ++i) {
                if (keccak256(builder.steps[i]) == hash) return i;
            }
        }
        return instruction(builder, operation, data);
    }

    // Removing the first use of an input or an invalid reference could suppress its runtime bounds check.
    function _resolved(Builder memory builder, uint256 operand) private pure returns (bool) {
        if (operand <= type(uint216).max) return true;
        if (operand > type(uint224).max) return false;
        if (uint8(operand >> 216) == SRC_RESULT) {
            return uint216(operand) < builder.length
                && NUMERICAL_OPERATIONS >> uint8(builder.steps[uint216(operand)][0]) & 1 > 0;
        }
        if (uint8(operand >> 216) != SRC_INPUT) return false;
        uint256 length = builder.length;
        for (uint256 i; i < length; ++i) {
            bytes memory step = builder.steps[i];
            uint8 operation = uint8(step[0]);
            if (operation < OP_ADD || operation > OP_LESS_OR_EQUAL) continue;
            uint256 operands = operation == OP_MUL_DIV ? 3 : 2;
            if (step.length < 1 + 32 * operands) continue;
            // Arithmetic and checks always evaluate every operand. A valid index also proves all lower indices exist.
            for (uint256 j; j < operands; ++j) {
                uint256 previous = uint256(step.load(1 + 32 * j));
                if (uint8(previous >> 216) == SRC_INPUT && uint216(previous) >= uint216(operand)) return true;
            }
        }
        return false;
    }
}
