// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {
    OP_ADD,
    OP_APPROVE,
    OP_CALL,
    OP_EQUAL,
    OP_LESS_OR_EQUAL,
    OP_MANAGE,
    OP_MAX,
    OP_MIN,
    OP_MUL_DIV,
    OP_READ,
    OP_SATURATING_SUB,
    OP_SUB,
    SRC_INPUT,
    SRC_RESULT
} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title ExecutingRecipe
 * @notice Library for compiling approved actions, reads and conditions into one committed recipe.
 * @dev Action methods return runtime-payload indices; values reference instruction indices.
 */
library ExecutingRecipe {
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

    struct Source {
        Read capacity;
        bytes32[] leaves;
        uint256[][] amountOffsets;
    }

    struct Funding {
        address adapter;
        address account;
        bytes32 pushLeaf;
        address asset;
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
        uint256 index;
        bytes memory encoded = abi.encode(readConfig.target, readConfig.data, readConfig.bindings, readConfig.offset);
        bytes32 hash = keccak256(encoded);
        uint256 queryLength = builder.queryLength;
        while (index < queryLength && keccak256(builder.queries[index]) != hash) ++index;
        uint256 value = result(instruction(builder, OP_READ, abi.encode(index)));
        if (index == queryLength) {
            builder.queries[builder.queryLength++] = encoded;
        }
        return value;
    }

    function balance(Builder memory builder, address token, address account) internal pure returns (uint256) {
        return readQuery(builder, balanceQuery(token, account));
    }

    function binary(Builder memory builder, uint8 operation, uint256 a, uint256 b) internal pure returns (uint256) {
        return result(instruction(builder, operation, abi.encode(a, b)));
    }

    function mulDiv(Builder memory builder, uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return result(instruction(builder, OP_MUL_DIV, abi.encode(a, b, c)));
    }

    function check(Builder memory builder, uint8 comparison, uint256 a, uint256 b) internal pure {
        if (comparison != OP_EQUAL && comparison != OP_LESS_OR_EQUAL) {
            revert InvalidConfiguration();
        }
        instruction(builder, comparison, abi.encode(a, b));
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
        return builder.runtimeLength++;
    }

    function approve(Builder memory builder, address token, address spender, bytes32 leaf, uint256 amount)
        internal
        pure
        returns (uint256)
    {
        instruction(builder, OP_APPROVE, abi.encode(amount, token, spender, leaf));
        return builder.runtimeLength++;
    }

    function call(Builder memory builder, address target, bytes memory data, uint256[] memory bindings)
        internal
        pure
        returns (uint256)
    {
        return instruction(builder, OP_CALL, abi.encode(target, data, bindings));
    }

    function instruction(Builder memory builder, uint8 operation, bytes memory data)
        internal
        pure
        returns (uint256 index)
    {
        if (operation > OP_CALL) revert InvalidConfiguration();
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
        for (uint256 i; i < length; ++i) {
            Source memory source;
            uint256 capacity;
            if (push && i == 0) {
                capacity = _pushCapacity(builder, funding);
                source.leaves = new bytes32[](1);
                source.leaves[0] = funding.pushLeaf;
                source.amountOffsets = new uint256[][](1);
                source.amountOffsets[0] = new uint256[](1);
                source.amountOffsets[0][0] = 4;
            } else {
                source = funding.sources[push ? i - 1 : i];
                capacity = read(builder, source.capacity);
            }
            uint256 cash = balance(builder, funding.asset, funding.account);
            uint256 take = binary(builder, OP_SATURATING_SUB, amount, cash);
            take = binary(builder, OP_MIN, take, capacity);
            sourceAmounts[i] = uint216(take);
            sourceCalls[i] = manage(builder, source.leaves, take, amountBindings(source.amountOffsets, take));
            capacity = balance(builder, funding.asset, funding.account);
            capacity = binary(builder, OP_SUB, capacity, cash);
            check(builder, OP_EQUAL, capacity, take);
        }
    }

    function _pushCapacity(Builder memory builder, Funding memory funding) private pure returns (uint256) {
        uint256 released = read(builder, Read(funding.adapter, abi.encodeCall(IMerkleAdapter.releasedLiquidity, ()), 0));
        uint256 staged = read(builder, Read(funding.adapter, abi.encodeCall(IMerkleAdapter.stagedLiquidity, ()), 0));
        uint256 locked = binary(builder, OP_ADD, released, staged);
        uint256 pending =
            read(builder, Read(funding.adapter, abi.encodeCall(IMerkleAdapter.pendingDeallocation, ()), 0));
        locked = binary(builder, OP_MAX, locked, pending);
        return binary(builder, OP_SATURATING_SUB, balance(builder, funding.asset, funding.adapter), locked);
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
            if (operation > OP_CALL) revert InvalidConfiguration();
            if (operation == OP_MANAGE || operation == OP_APPROVE) {
                indices[length++] = i;
            }
        }
        assembly ("memory-safe") { mstore(indices, length) }
    }
}
