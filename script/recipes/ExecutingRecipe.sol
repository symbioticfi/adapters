// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ExecutingRecipe
 * @notice Library for attaching calculations and measured conditions to approved recipe actions.
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
        IRecipeExecutor.Step[] recipe;
        uint256 length;
        uint256 results;
        IRecipeExecutor.Expression[] pending;
        uint256 pendingLength;
        IRecipeExecutor.Check[] checks;
        uint256 checksLength;
    }

    function start(uint256 capacity) internal pure returns (Builder memory builder) {
        builder.recipe = new IRecipeExecutor.Step[](capacity);
        builder.pending = new IRecipeExecutor.Expression[](capacity * 4);
        builder.checks = new IRecipeExecutor.Check[](capacity * 4);
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
        return _expression(
            builder,
            IRecipeExecutor.Expression(
                IRecipeExecutor.Operation.Read,
                literal(builder, 0),
                literal(builder, 0),
                literal(builder, 0),
                abi.encode(query(readConfig))
            ),
            false
        );
    }

    function balance(Builder memory builder, address token, address account)
        internal
        pure
        returns (IRecipeExecutor.Value memory)
    {
        return read(builder, Read(token, abi.encodeCall(IERC20.balanceOf, (account)), 0));
    }

    function binary(
        Builder memory builder,
        IRecipeExecutor.Operation operation,
        IRecipeExecutor.Value memory a,
        IRecipeExecutor.Value memory b
    ) internal pure returns (IRecipeExecutor.Value memory) {
        return _expression(builder, IRecipeExecutor.Expression(operation, a, b, literal(builder, 0), ""), false);
    }

    function mulDiv(
        Builder memory builder,
        IRecipeExecutor.Value memory a,
        IRecipeExecutor.Value memory b,
        IRecipeExecutor.Value memory c
    ) internal pure returns (IRecipeExecutor.Value memory) {
        return _expression(builder, IRecipeExecutor.Expression(IRecipeExecutor.Operation.MulDiv, a, b, c, ""), false);
    }

    function check(
        Builder memory builder,
        IRecipeExecutor.Comparison comparison,
        IRecipeExecutor.Value memory a,
        IRecipeExecutor.Value memory b
    ) internal pure {
        builder.checks[builder.checksLength++] = IRecipeExecutor.Check(a, b, comparison);
    }

    function checkAfter(
        Builder memory builder,
        IRecipeExecutor.Comparison comparison,
        IRecipeExecutor.Value memory a,
        IRecipeExecutor.Value memory b
    ) internal pure {
        if (builder.pendingLength > 0) revert InvalidConfiguration();
        IRecipeExecutor.Check[] memory checks = builder.recipe[builder.length - 1].checksAfter;
        IRecipeExecutor.Check[] memory extended = new IRecipeExecutor.Check[](checks.length + 1);
        for (uint256 i; i < checks.length; ++i) {
            extended[i] = checks[i];
        }
        extended[checks.length] = IRecipeExecutor.Check(a, b, comparison);
        builder.recipe[builder.length - 1].checksAfter = extended;
    }

    function afterBinary(
        Builder memory builder,
        IRecipeExecutor.Operation operation,
        IRecipeExecutor.Value memory a,
        IRecipeExecutor.Value memory b
    ) internal pure returns (IRecipeExecutor.Value memory) {
        if (builder.pendingLength > 0) revert InvalidConfiguration();
        return _expression(builder, IRecipeExecutor.Expression(operation, a, b, literal(builder, 0), ""), true);
    }

    function observe(
        Builder memory builder,
        IRecipeExecutor.Query memory readConfig,
        IRecipeExecutor.ObservationKind kind
    ) internal pure returns (IRecipeExecutor.Value memory value) {
        if (builder.pendingLength > 0 || builder.recipe[builder.length - 1].afterExpressions.length > 0) revert InvalidConfiguration();
        IRecipeExecutor.Observation[] memory observations = builder.recipe[builder.length - 1].observations;
        IRecipeExecutor.Observation[] memory extended = new IRecipeExecutor.Observation[](observations.length + 1);
        for (uint256 i; i < observations.length; ++i) {
            extended[i] = observations[i];
        }
        extended[observations.length] = IRecipeExecutor.Observation(readConfig, kind);
        builder.recipe[builder.length - 1].observations = extended;
        value = result(builder.results++);
    }

    function manage(Builder memory builder, bytes32[] memory leaves, IRecipeExecutor.Value memory guard)
        internal
        pure
        returns (uint256)
    {
        return manage(builder, leaves, guard, new IRecipeExecutor.Binding[][](leaves.length));
    }

    function manage(
        Builder memory builder,
        bytes32[] memory leaves,
        IRecipeExecutor.Value memory guard,
        IRecipeExecutor.Binding[][] memory bindings
    ) internal pure returns (uint256) {
        if (bindings.length != leaves.length) revert InvalidConfiguration();
        return action(builder, IRecipeExecutor.Kind.Manage, guard, abi.encode(leaves, bindings));
    }

    function approve(
        Builder memory builder,
        address token,
        address spender,
        bytes32 leaf,
        IRecipeExecutor.Value memory amount
    ) internal pure returns (uint256) {
        return action(builder, IRecipeExecutor.Kind.Approve, amount, abi.encode(token, spender, leaf));
    }

    function action(
        Builder memory builder,
        IRecipeExecutor.Kind kind,
        IRecipeExecutor.Value memory amount,
        bytes memory data
    ) internal pure returns (uint256 index) {
        index = builder.length++;
        IRecipeExecutor.Step memory step;
        step.kind = kind;
        step.amount = amount;
        step.data = data;
        step.beforeExpressions = new IRecipeExecutor.Expression[](builder.pendingLength);
        for (uint256 i; i < builder.pendingLength; ++i) {
            step.beforeExpressions[i] = builder.pending[i];
        }
        step.checksBefore = new IRecipeExecutor.Check[](builder.checksLength);
        for (uint256 i; i < builder.checksLength; ++i) {
            step.checksBefore[i] = builder.checks[i];
        }
        builder.pendingLength = 0;
        builder.checksLength = 0;
        step.observations = new IRecipeExecutor.Observation[](0);
        step.afterExpressions = new IRecipeExecutor.Expression[](0);
        step.checksAfter = new IRecipeExecutor.Check[](0);
        builder.recipe[index] = step;
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
            IRecipeExecutor.Value memory target = binary(
                builder,
                IRecipeExecutor.Operation.Add,
                amount,
                read(builder, Read(funding.adapter, abi.encodeCall(IMerkleAdapter.reservedAssets, ()), 0))
            );
            IRecipeExecutor.Value memory take = binary(
                builder,
                IRecipeExecutor.Operation.Minimum,
                binary(builder, IRecipeExecutor.Operation.SaturatingSubtract, target, cash),
                read(builder, funding.sources[i].capacity)
            );
            sourceAmounts[i] = take.value;
            sourceCalls[i] = manage(
                builder, funding.sources[i].leaves, take, amountBindings(funding.sources[i].amountOffsets, take)
            );
            checkAfter(
                builder,
                IRecipeExecutor.Comparison.Equal,
                observe(
                    builder, balanceQuery(funding.asset, funding.adapter), IRecipeExecutor.ObservationKind.Increase
                ),
                take
            );
        }
    }

    function finish(Builder memory builder) internal pure returns (IRecipeExecutor.Step[] memory recipe) {
        if (builder.length == 0 && (builder.pendingLength > 0 || builder.checksLength > 0)) {
            revert InvalidConfiguration();
        }
        for (uint256 i; i < builder.pendingLength; ++i) {
            _appendAfter(builder, builder.pending[i]);
        }
        builder.pendingLength = 0;
        for (uint256 i; i < builder.checksLength; ++i) {
            checkAfter(builder, builder.checks[i].comparison, builder.checks[i].a, builder.checks[i].b);
        }
        recipe = builder.recipe;
        uint256 length = builder.length;
        assembly ("memory-safe") { mstore(recipe, length) }
    }

    function _expression(Builder memory builder, IRecipeExecutor.Expression memory expression, bool afterAction)
        private
        pure
        returns (IRecipeExecutor.Value memory value)
    {
        value = result(builder.results++);
        if (afterAction) _appendAfter(builder, expression);
        else builder.pending[builder.pendingLength++] = expression;
    }

    function _appendAfter(Builder memory builder, IRecipeExecutor.Expression memory expression) private pure {
        IRecipeExecutor.Expression[] memory expressions = builder.recipe[builder.length - 1].afterExpressions;
        IRecipeExecutor.Expression[] memory extended = new IRecipeExecutor.Expression[](expressions.length + 1);
        for (uint256 i; i < expressions.length; ++i) {
            extended[i] = expressions[i];
        }
        extended[expressions.length] = expression;
        builder.recipe[builder.length - 1].afterExpressions = extended;
    }
}
