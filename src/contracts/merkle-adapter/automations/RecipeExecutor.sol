// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MerkleAdapterVerifier} from "../libraries/MerkleAdapterVerifier.sol";

import {IMerkleAdapter} from "../../../interfaces/IMerkleAdapter.sol";
import {IRecipeExecutor} from "../../../interfaces/merkle-adapter/automations/IRecipeExecutor.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title RecipeExecutor
/// @notice Contract for owner-configured leaf actions with dependent amounts and attached conditions.
contract RecipeExecutor is Ownable, ReentrancyGuardTransient, IRecipeExecutor {
    using Address for address;
    using Math for uint256;

    /* STRUCTS */

    struct Evaluation {
        uint256[] values;
        uint256 length;
    }

    /* IMMUTABLES */

    /// @inheritdoc IRecipeExecutor
    address public immutable adapter;

    /* STATE VARIABLES */

    /// @inheritdoc IRecipeExecutor
    address public caller;

    /// @inheritdoc IRecipeExecutor
    bytes[] public steps;

    /* CONSTRUCTOR */

    constructor(address newOwner, address newAdapter) Ownable(newOwner) {
        adapter = newAdapter;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IRecipeExecutor
    function setCaller(address newCaller) public nonReentrant onlyOwner {
        caller = newCaller;
        emit SetCaller(newCaller);
    }

    /// @inheritdoc IRecipeExecutor
    function setRecipe(Step[] calldata newRecipe) public nonReentrant onlyOwner {
        delete steps;
        for (uint256 i; i < newRecipe.length; ++i) {
            steps.push(abi.encode(newRecipe[i]));
        }
        emit SetRecipe(newRecipe);
    }

    /// @inheritdoc IRecipeExecutor
    function execute(uint256[] calldata inputs, bytes[] calldata runtime)
        public
        nonReentrant
        returns (uint256[] memory values)
    {
        if (caller != msg.sender) revert InvalidCaller();
        uint256 length = steps.length;
        if (runtime.length != length) revert InvalidRuntime();
        Step[] memory recipe = new Step[](length);
        uint256 capacity;
        for (uint256 i; i < length; ++i) {
            recipe[i] = abi.decode(steps[i], (Step));
            capacity += recipe[i].beforeExpressions.length + recipe[i].observations.length
            + recipe[i].afterExpressions.length;
        }
        Evaluation memory evaluation = Evaluation(new uint256[](capacity), 0);
        for (uint256 i; i < length; ++i) {
            _execute(recipe[i], runtime[i], inputs, evaluation);
        }
        emit Execute();
        return evaluation.values;
    }

    /* INTERNAL FUNCTIONS */

    function _execute(Step memory step, bytes calldata runtime, uint256[] calldata inputs, Evaluation memory evaluation)
        internal
    {
        _evaluate(step.beforeExpressions, inputs, evaluation);
        _check(step.checksBefore, inputs, evaluation);
        uint256[] memory beforeValues = new uint256[](step.observations.length);
        for (uint256 j; j < step.observations.length; ++j) {
            Query memory query = step.observations[j].query;
            _bind(query.data, query.bindings, inputs, evaluation);
            if (step.observations[j].kind != ObservationKind.After) beforeValues[j] = _read(query);
        }
        if (step.kind == Kind.Manage) {
            if (_value(step.amount, inputs, evaluation) > 0) {
                IMerkleAdapter.Action[] memory actions = abi.decode(runtime, (IMerkleAdapter.Action[]));
                if (!Bytes.equal(runtime, abi.encode(actions))) revert InvalidRuntime();
                (bytes32[] memory leaves, Binding[][] memory bindings) = abi.decode(step.data, (bytes32[], Binding[][]));
                if (actions.length != leaves.length) revert InvalidRuntime();
                if (actions.length != bindings.length) revert InvalidRuntime();
                for (uint256 j; j < actions.length; ++j) {
                    _bind(actions[j].data, bindings[j], inputs, evaluation);
                    _checkAction(actions[j], leaves[j]);
                }
                IMerkleAdapter(adapter).manage(actions);
            }
        } else if (step.kind == Kind.Approve) {
            uint256 amount = _value(step.amount, inputs, evaluation);
            (address token, address spender, bytes32 leaf) = abi.decode(step.data, (address, address, bytes32));
            Permission memory permission = abi.decode(runtime, (Permission));
            bool reset = amount > 0 && IERC20(token).allowance(adapter, spender) > 0;
            IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](reset ? 2 : 1);
            for (uint256 j; j < actions.length; ++j) {
                actions[j] = IMerkleAdapter.Action(
                    token,
                    0,
                    abi.encodeCall(IERC20.approve, (spender, reset && j == 0 ? 0 : amount)),
                    permission.dataMask,
                    permission.proof
                );
                _checkAction(actions[j], leaf);
            }
            bytes[] memory results = IMerkleAdapter(adapter).manage(actions);
            for (uint256 j; j < results.length; ++j) {
                if (results[j].length > 0 && !abi.decode(results[j], (bool))) revert ApprovalFailed();
            }
        } else {
            (address target, bytes4 selector, Binding[] memory bindings) =
                abi.decode(step.data, (address, bytes4, Binding[]));
            bytes memory data = runtime;
            if (data.length < 4 || bytes4(data) != selector) revert InvalidCall();
            _bind(data, bindings, inputs, evaluation);
            target.functionCall(data);
        }
        for (uint256 j; j < step.observations.length; ++j) {
            uint256 value = _read(step.observations[j].query);
            if (step.observations[j].kind == ObservationKind.Increase) value -= beforeValues[j];
            else if (step.observations[j].kind == ObservationKind.Decrease) value = beforeValues[j] - value;
            evaluation.values[evaluation.length++] = value;
        }
        _evaluate(step.afterExpressions, inputs, evaluation);
        _check(step.checksAfter, inputs, evaluation);
    }

    function _evaluate(Expression[] memory expressions, uint256[] calldata inputs, Evaluation memory evaluation)
        internal
        view
    {
        for (uint256 i; i < expressions.length; ++i) {
            Expression memory expression = expressions[i];
            uint256 value;
            if (expression.operation == Operation.Read) {
                Query memory query = abi.decode(expression.data, (Query));
                _bind(query.data, query.bindings, inputs, evaluation);
                value = _read(query);
            } else {
                uint256 a = _value(expression.a, inputs, evaluation);
                uint256 b = _value(expression.b, inputs, evaluation);
                if (expression.operation == Operation.Add) value = a + b;
                else if (expression.operation == Operation.Subtract) value = a - b;
                else if (expression.operation == Operation.SaturatingSubtract) value = a.saturatingSub(b);
                else if (expression.operation == Operation.Minimum) value = a.min(b);
                else value = a.mulDiv(b, _value(expression.c, inputs, evaluation));
            }
            evaluation.values[evaluation.length++] = value;
        }
    }

    function _read(Query memory query) internal view returns (uint256) {
        return abi.decode(
            Bytes.splice(query.target.functionStaticCall(query.data), query.offset, query.offset + 32), (uint256)
        );
    }

    function _check(Check[] memory checks, uint256[] calldata inputs, Evaluation memory evaluation) internal pure {
        for (uint256 i; i < checks.length; ++i) {
            uint256 a = _value(checks[i].a, inputs, evaluation);
            uint256 b = _value(checks[i].b, inputs, evaluation);
            if (
                checks[i].comparison == Comparison.Equal && a != b || checks[i].comparison == Comparison.GreaterOrEqual
                    && a < b || checks[i].comparison == Comparison.LessOrEqual && a > b
            ) revert CheckFailed();
        }
    }

    function _value(Value memory value, uint256[] calldata inputs, Evaluation memory evaluation)
        internal
        pure
        returns (uint256)
    {
        if (value.source == Source.Literal) return value.value;
        if (value.source == Source.Input) return inputs[value.value];
        if (value.value >= evaluation.length) revert InvalidReference();
        return evaluation.values[value.value];
    }

    function _bind(
        bytes memory data,
        Binding[] memory bindings,
        uint256[] calldata inputs,
        Evaluation memory evaluation
    ) internal pure {
        uint256 end = 4;
        for (uint256 i; i < bindings.length; ++i) {
            uint256 offset = bindings[i].offset;
            if (offset < end || offset > data.length || data.length - offset < 32) revert InvalidCall();
            end = offset + 32;
            Bytes.replace(data, offset, abi.encode(_value(bindings[i].value, inputs, evaluation)));
        }
    }

    function _checkAction(IMerkleAdapter.Action memory action, bytes32 leaf) internal pure {
        if (
            action.value > 0
                || MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask) != leaf
        ) revert InvalidAction();
    }
}
