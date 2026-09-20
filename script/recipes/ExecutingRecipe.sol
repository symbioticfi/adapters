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
        address asset;
        Source[] sources;
    }

    struct Builder {
        IRecipeExecutor.Step[] steps;
        IRecipeExecutor.Query[] queries;
        uint256 length;
        uint256 queryLength;
        uint256 runtimeLength;
    }

    function start(uint256 capacity) internal pure returns (Builder memory builder) {
        builder.steps = new IRecipeExecutor.Step[](capacity);
        builder.queries = new IRecipeExecutor.Query[](capacity);
    }

    function literal(Builder memory, uint256 value) internal pure returns (IRecipeExecutor.Value memory) {
        return IRecipeExecutor.Value(IRecipeExecutor.Source.Literal, value);
    }

    function input(Builder memory, uint256 index) internal pure returns (IRecipeExecutor.Value memory) {
        return IRecipeExecutor.Value(IRecipeExecutor.Source.Input, index);
    }

    function result(uint256 index) internal pure returns (IRecipeExecutor.Value memory) {
        return IRecipeExecutor.Value(IRecipeExecutor.Source.Result, index);
    }

    function query(Read memory readConfig) internal pure returns (IRecipeExecutor.Query memory) {
        return
            IRecipeExecutor.Query(
                readConfig.target, readConfig.data, new IRecipeExecutor.Binding[](0), readConfig.offset
            );
    }

    function balanceQuery(address token, address account) internal pure returns (IRecipeExecutor.Query memory) {
        return query(Read(token, abi.encodeCall(IERC20.balanceOf, (account)), 0));
    }

    function read(Builder memory builder, Read memory readConfig) internal pure returns (IRecipeExecutor.Value memory) {
        return readQuery(builder, query(readConfig));
    }

    function readQuery(Builder memory builder, IRecipeExecutor.Query memory readConfig)
        internal
        pure
        returns (IRecipeExecutor.Value memory)
    {
        uint256 index;
        bytes memory encoded = abi.encode(readConfig);
        bytes32 hash = keccak256(encoded);
        while (index < builder.queryLength && keccak256(abi.encode(builder.queries[index])) != hash) ++index;
        IRecipeExecutor.Value memory value =
            result(instruction(builder, IRecipeExecutor.Operation.Read, abi.encode(index)));
        if (index == builder.queryLength) {
            builder.queries[builder.queryLength++] = abi.decode(encoded, (IRecipeExecutor.Query));
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
            IRecipeExecutor.Query[] memory queries = new IRecipeExecutor.Query[](extended.length);
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
        builder.steps[index] = IRecipeExecutor.Step(operation, data);
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
                bindings[i][j] = IRecipeExecutor.Binding(offsets[i][j], amount);
            }
        }
    }

    function fund(Builder memory builder, Funding memory funding, IRecipeExecutor.Value memory amount)
        internal
        pure
        returns (uint256[] memory sourceCalls, uint256[] memory sourceAmounts)
    {
        sourceCalls = new uint256[](funding.sources.length);
        sourceAmounts = new uint256[](funding.sources.length);
        for (uint256 i; i < funding.sources.length; ++i) {
            IRecipeExecutor.Value memory cash = balance(builder, funding.asset, funding.adapter);
            IRecipeExecutor.Value memory take;
            {
                IRecipeExecutor.Value memory target = binary(
                    builder,
                    IRecipeExecutor.Operation.Add,
                    amount,
                    read(builder, Read(funding.adapter, abi.encodeCall(IMerkleAdapter.reservedAssets, ()), 0))
                );
                take = binary(
                    builder,
                    IRecipeExecutor.Operation.Minimum,
                    binary(builder, IRecipeExecutor.Operation.SaturatingSubtract, target, cash),
                    read(builder, funding.sources[i].capacity)
                );
            }
            sourceAmounts[i] = take.value;
            sourceCalls[i] = manage(
                builder, funding.sources[i].leaves, take, amountBindings(funding.sources[i].amountOffsets, take)
            );
            check(
                builder,
                IRecipeExecutor.Operation.Equal,
                binary(
                    builder, IRecipeExecutor.Operation.Subtract, balance(builder, funding.asset, funding.adapter), cash
                ),
                take
            );
        }
    }

    function finish(Builder memory builder) internal pure returns (IRecipeExecutor.Recipe memory recipe) {
        recipe.steps = builder.steps;
        recipe.queries = builder.queries;
        uint256 length = builder.length;
        uint256 queryLength = builder.queryLength;
        assembly ("memory-safe") {
            mstore(mload(add(recipe, 32)), length)
            mstore(mload(recipe), queryLength)
        }
    }

    function runtimeSteps(IRecipeExecutor.Recipe memory recipe) internal pure returns (uint256[] memory indices) {
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
