// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ExecutingRecipe
 * @notice Library for compiling approved actions, reads and conditions into one committed recipe.
 * @dev Action methods return runtime-payload indices; values reference instruction indices.
 */
library ExecutingRecipe {
    error InvalidConfiguration();

    // Script-only containers; the executor ABI accepts arrays and native query tuples.
    struct Recipe {
        bytes[] queries;
        IRecipeExecutor.Step[] steps;
    }

    struct Query {
        address target;
        bytes data;
        IRecipeExecutor.Binding[] bindings;
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
        bytes32 releaseLeaf;
        address asset;
        Source[] sources;
    }

    struct Builder {
        IRecipeExecutor.Step[] steps;
        bytes[] queries;
        uint256 length;
        uint256 queryLength;
        uint256 runtimeLength;
    }

    function start(uint256 capacity) internal pure returns (Builder memory builder) {
        builder.steps = new IRecipeExecutor.Step[](capacity);
        builder.queries = new bytes[](capacity);
    }

    function literal(Builder memory, uint256 value) internal pure returns (IRecipeExecutor.Value memory) {
        return IRecipeExecutor.Value({source: IRecipeExecutor.Source.Literal, value: value});
    }

    function input(Builder memory, uint256 index) internal pure returns (IRecipeExecutor.Value memory) {
        return IRecipeExecutor.Value({source: IRecipeExecutor.Source.Input, value: index});
    }

    function result(uint256 index) internal pure returns (IRecipeExecutor.Value memory) {
        return IRecipeExecutor.Value({source: IRecipeExecutor.Source.Result, value: index});
    }

    function query(Read memory readConfig) internal pure returns (Query memory) {
        return Query({
            target: readConfig.target,
            data: readConfig.data,
            bindings: new IRecipeExecutor.Binding[](0),
            offset: readConfig.offset
        });
    }

    function balanceQuery(address token, address account) internal pure returns (Query memory) {
        return query(Read({target: token, data: abi.encodeCall(IERC20.balanceOf, (account)), offset: 0}));
    }

    function read(Builder memory builder, Read memory readConfig) internal pure returns (IRecipeExecutor.Value memory) {
        return readQuery(builder, query(readConfig));
    }

    function readQuery(Builder memory builder, Query memory readConfig)
        internal
        pure
        returns (IRecipeExecutor.Value memory)
    {
        uint256 index;
        bytes memory encoded = abi.encode(readConfig.target, readConfig.data, readConfig.bindings, readConfig.offset);
        bytes32 hash = keccak256(encoded);
        while (index < builder.queryLength && keccak256(builder.queries[index]) != hash) ++index;
        IRecipeExecutor.Value memory value =
            result(instruction(builder, IRecipeExecutor.Operation.Read, abi.encode(index)));
        if (index == builder.queryLength) {
            builder.queries[builder.queryLength++] = encoded;
        }
        return value;
    }

    function balance(Builder memory builder, address token, address account)
        internal
        pure
        returns (IRecipeExecutor.Value memory)
    {
        return readQuery(builder, balanceQuery(token, account));
    }

    function binary(
        Builder memory builder,
        IRecipeExecutor.Operation operation,
        IRecipeExecutor.Value memory a,
        IRecipeExecutor.Value memory b
    ) internal pure returns (IRecipeExecutor.Value memory) {
        return result(instruction(builder, operation, abi.encode(a, b)));
    }

    function mulDiv(
        Builder memory builder,
        IRecipeExecutor.Value memory a,
        IRecipeExecutor.Value memory b,
        IRecipeExecutor.Value memory c
    ) internal pure returns (IRecipeExecutor.Value memory) {
        return result(instruction(builder, IRecipeExecutor.Operation.MulDiv, abi.encode(a, b, c)));
    }

    function check(
        Builder memory builder,
        IRecipeExecutor.Operation comparison,
        IRecipeExecutor.Value memory a,
        IRecipeExecutor.Value memory b
    ) internal pure {
        if (comparison != IRecipeExecutor.Operation.Equal && comparison != IRecipeExecutor.Operation.LessOrEqual) revert InvalidConfiguration();
        instruction(builder, comparison, abi.encode(a, b));
    }

    function manage(Builder memory builder, bytes32[] memory leaves, IRecipeExecutor.Value memory amount)
        internal
        pure
        returns (uint256)
    {
        return manage(builder, leaves, amount, new IRecipeExecutor.Binding[][](leaves.length));
    }

    function manage(
        Builder memory builder,
        bytes32[] memory leaves,
        IRecipeExecutor.Value memory amount,
        IRecipeExecutor.Binding[][] memory bindings
    ) internal pure returns (uint256) {
        if (bindings.length != leaves.length) revert InvalidConfiguration();
        instruction(builder, IRecipeExecutor.Operation.Manage, abi.encode(amount, leaves, bindings));
        return builder.runtimeLength++;
    }

    function approve(
        Builder memory builder,
        address token,
        address spender,
        bytes32 leaf,
        IRecipeExecutor.Value memory amount
    ) internal pure returns (uint256) {
        instruction(builder, IRecipeExecutor.Operation.Approve, abi.encode(amount, token, spender, leaf));
        return builder.runtimeLength++;
    }

    function call(Builder memory builder, address target, bytes memory data, IRecipeExecutor.Binding[] memory bindings)
        internal
        pure
        returns (uint256)
    {
        return instruction(builder, IRecipeExecutor.Operation.Call, abi.encode(target, data, bindings));
    }

    function instruction(Builder memory builder, IRecipeExecutor.Operation operation, bytes memory data)
        internal
        pure
        returns (uint256 index)
    {
        if (builder.length == builder.steps.length) {
            IRecipeExecutor.Step[] memory extended = new IRecipeExecutor.Step[](builder.length * 2 + 1);
            bytes[] memory queries = new bytes[](extended.length);
            for (uint256 i; i < builder.length; ++i) {
                extended[i] = builder.steps[i];
            }
            for (uint256 i; i < builder.queryLength; ++i) {
                queries[i] = builder.queries[i];
            }
            builder.steps = extended;
            builder.queries = queries;
        }
        index = builder.length++;
        builder.steps[index] = IRecipeExecutor.Step({operation: operation, data: data});
    }

    function amountBindings(uint256[][] memory offsets, IRecipeExecutor.Value memory amount)
        internal
        pure
        returns (IRecipeExecutor.Binding[][] memory bindings)
    {
        bindings = new IRecipeExecutor.Binding[][](offsets.length);
        for (uint256 i; i < offsets.length; ++i) {
            bindings[i] = new IRecipeExecutor.Binding[](offsets[i].length);
            for (uint256 j; j < offsets[i].length; ++j) {
                bindings[i][j] = IRecipeExecutor.Binding({offset: offsets[i][j], value: amount});
            }
        }
    }

    function fund(Builder memory builder, Funding memory funding, IRecipeExecutor.Value memory amount)
        internal
        pure
        returns (uint256[] memory sourceCalls, uint256[] memory sourceAmounts)
    {
        Read memory reserve =
            Read({target: funding.adapter, data: abi.encodeCall(IMerkleAdapter.reservedAssets, ()), offset: 0});
        bool release = funding.releaseLeaf != bytes32(0);
        uint256 length = funding.sources.length + (release ? 1 : 0);
        sourceCalls = new uint256[](length);
        sourceAmounts = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            Source memory source;
            IRecipeExecutor.Value memory capacity;
            if (release && i == 0) {
                capacity = balance(builder, funding.asset, funding.adapter);
                capacity = binary(builder, IRecipeExecutor.Operation.SaturatingSub, capacity, read(builder, reserve));
                source.leaves = new bytes32[](1);
                source.leaves[0] = funding.releaseLeaf;
                source.amountOffsets = new uint256[][](1);
                source.amountOffsets[0] = new uint256[](1);
                source.amountOffsets[0][0] = 4;
            } else {
                source = funding.sources[release ? i - 1 : i];
                capacity = read(builder, source.capacity);
            }
            IRecipeExecutor.Value memory cash = balance(builder, funding.asset, funding.account);
            IRecipeExecutor.Value memory take = binary(builder, IRecipeExecutor.Operation.SaturatingSub, amount, cash);
            take = binary(builder, IRecipeExecutor.Operation.Min, take, capacity);
            sourceAmounts[i] = take.value;
            sourceCalls[i] = manage(builder, source.leaves, take, amountBindings(source.amountOffsets, take));
            capacity = balance(builder, funding.asset, funding.account);
            capacity = binary(builder, IRecipeExecutor.Operation.Sub, capacity, cash);
            check(builder, IRecipeExecutor.Operation.Equal, capacity, take);
        }
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
        indices = new uint256[](recipe.steps.length);
        uint256 length;
        for (uint256 i; i < recipe.steps.length; ++i) {
            if (
                recipe.steps[i].operation == IRecipeExecutor.Operation.Manage
                    || recipe.steps[i].operation == IRecipeExecutor.Operation.Approve
            ) indices[length++] = i;
        }
        assembly ("memory-safe") { mstore(indices, length) }
    }
}
