// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MerkleAdapterVerifier} from "../merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IExecutor} from "../../interfaces/periphery/IExecutor.sol";
import {IMerkleAdapter} from "../../interfaces/IMerkleAdapter.sol";
import {IRecipeExecutor} from "../../interfaces/periphery/IRecipeExecutor.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title RecipeExecutor
/// @notice Contract for curator-committed automation using adapter calls and measured postconditions.
contract RecipeExecutor is Ownable, ReentrancyGuardTransient, IRecipeExecutor {
    using Address for address;

    /* IMMUTABLES */

    /// @inheritdoc IRecipeExecutor
    address public immutable adapter;

    /* STATE VARIABLES */

    /// @inheritdoc IRecipeExecutor
    address public caller;

    /// @inheritdoc IRecipeExecutor
    bytes32 public recipeHash;

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
    function setRecipe(Step[] calldata recipe) public nonReentrant onlyOwner {
        recipeHash = keccak256(abi.encode(recipe));
        emit SetRecipe(recipeHash, recipe);
    }

    /// @inheritdoc IRecipeExecutor
    function execute(Step[] calldata recipe, uint256[] calldata inputs, bytes[] calldata runtime)
        public
        nonReentrant
        returns (uint256[] memory values)
    {
        if (caller != msg.sender) revert InvalidCaller();
        if (recipeHash != keccak256(abi.encode(recipe))) revert InvalidRecipe();
        if (runtime.length != recipe.length) revert InvalidRuntime();

        values = new uint256[](recipe.length);
        for (uint256 i; i < recipe.length; ++i) {
            values[i] = _step(recipe[i], inputs, runtime, values, i);
        }
        emit Execute(recipeHash);
    }

    /* INTERNAL FUNCTIONS */

    function _step(
        Step calldata step,
        uint256[] calldata inputs,
        bytes[] calldata runtime,
        uint256[] memory values,
        uint256 index
    ) internal returns (uint256) {
        Operation operation = step.operation;
        if (operation == Operation.Constant) return step.a;
        if (operation == Operation.Input) return inputs[step.a];
        if (operation == Operation.Calldata) return _word(runtime[step.a], step.b);
        if (operation == Operation.Read) {
            (address target, bytes memory query) = abi.decode(step.data, (address, bytes));
            return _word(target.functionStaticCall(query), step.a);
        }
        if (operation == Operation.Invoke) {
            (address target, bytes4 selector) = abi.decode(step.data, (address, bytes4));
            bytes calldata data = runtime[index];
            if (data.length < 4 || bytes4(data[:4]) != selector) revert InvalidCall();
            target.functionCall(data);
            return 0;
        }

        uint256 a = _value(values, step.a, index);
        if (operation == Operation.Manage) {
            if (a > 0) {
                IMerkleAdapter.Action[] memory actions = abi.decode(runtime[index], (IMerkleAdapter.Action[]));
                bytes32[] memory leaves = abi.decode(step.data, (bytes32[]));
                if (actions.length != leaves.length) revert InvalidRuntime();
                for (uint256 i; i < actions.length; ++i) {
                    _checkAction(actions[i], leaves[i]);
                }
                IMerkleAdapter(adapter).manage(actions);
            }
            return 0;
        }
        if (operation == Operation.Approve) {
            _approve(step.data, runtime[index], a);
            return 0;
        }

        uint256 b = _value(values, step.b, index);
        if (operation == Operation.Add) return a + b;
        if (operation == Operation.Subtract) return a - b;
        if (operation == Operation.Minimum) return Math.min(a, b);
        if (operation == Operation.MulDiv) return Math.mulDiv(a, b, _value(values, step.c, index));
        if (operation == Operation.Equal && a != b) revert CheckFailed();
        if (operation == Operation.LessOrEqual && a > b) revert CheckFailed();
        return 0;
    }

    function _approve(bytes calldata configuration, bytes calldata runtime, uint256 amount) internal {
        (address token, address spender, bytes32 leaf) = abi.decode(configuration, (address, address, bytes32));
        IExecutor.Permission memory permission = abi.decode(runtime, (IExecutor.Permission));
        bool reset = amount > 0 && IERC20(token).allowance(adapter, spender) > 0;
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](reset ? 2 : 1);
        for (uint256 i; i < actions.length; ++i) {
            actions[i] = IMerkleAdapter.Action(
                token,
                0,
                abi.encodeCall(IERC20.approve, (spender, reset && i == 0 ? 0 : amount)),
                permission.dataMask,
                permission.proof
            );
            _checkAction(actions[i], leaf);
        }
        bytes[] memory results = IMerkleAdapter(adapter).manage(actions);
        for (uint256 i; i < results.length; ++i) {
            if (results[i].length > 0 && !abi.decode(results[i], (bool))) revert ApprovalFailed();
        }
    }

    function _checkAction(IMerkleAdapter.Action memory action, bytes32 leaf) internal pure {
        if (
            action.value > 0
                || MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask) != leaf
        ) revert InvalidAction();
    }

    function _value(uint256[] memory values, uint256 index, uint256 current) internal pure returns (uint256) {
        if (index >= current) revert InvalidReference();
        return values[index];
    }

    function _word(bytes memory data, uint256 offset) internal pure returns (uint256 result) {
        if (data.length < 32 || offset > data.length - 32) revert InvalidWord();
        assembly ("memory-safe") {
            result := mload(add(add(data, 32), offset))
        }
    }
}
