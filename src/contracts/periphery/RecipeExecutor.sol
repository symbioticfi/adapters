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
    function setRecipe(Step[] calldata newRecipe) public nonReentrant onlyOwner {
        recipeHash = keccak256(abi.encode(newRecipe));
        emit SetRecipe(recipeHash, newRecipe);
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
            Step calldata step = recipe[i];
            Operation operation = step.operation;
            if (operation == Operation.Constant) {
                values[i] = step.a;
            } else if (operation == Operation.Input) {
                values[i] = inputs[step.a];
            } else if (operation == Operation.Calldata) {
                values[i] = _word(runtime[step.a], step.b);
            } else if (operation == Operation.Read) {
                (address target, bytes memory query) = abi.decode(step.data, (address, bytes));
                values[i] = _word(target.functionStaticCall(query), step.a);
            } else if (operation == Operation.Invoke) {
                (address target, bytes4 selector) = abi.decode(step.data, (address, bytes4));
                bytes calldata data = runtime[i];
                if (data.length < 4 || bytes4(data[:4]) != selector) revert InvalidCall();
                target.functionCall(data);
            } else {
                if (step.a >= i) revert InvalidReference();
                uint256 a = values[step.a];
                if (operation == Operation.Manage) {
                    if (a > 0) {
                        IMerkleAdapter.Action[] memory actions = abi.decode(runtime[i], (IMerkleAdapter.Action[]));
                        bytes32[] memory leaves = abi.decode(step.data, (bytes32[]));
                        if (actions.length != leaves.length) revert InvalidRuntime();
                        for (uint256 j; j < actions.length; ++j) {
                            _checkAction(actions[j], leaves[j]);
                        }
                        IMerkleAdapter(adapter).manage(actions);
                    }
                } else if (operation == Operation.Approve) {
                    (address token, address spender, bytes32 leaf) = abi.decode(step.data, (address, address, bytes32));
                    IExecutor.Permission memory permission = abi.decode(runtime[i], (IExecutor.Permission));
                    bool reset = a > 0 && IERC20(token).allowance(adapter, spender) > 0;
                    IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](reset ? 2 : 1);
                    for (uint256 j; j < actions.length; ++j) {
                        actions[j] = IMerkleAdapter.Action(
                            token,
                            0,
                            abi.encodeCall(IERC20.approve, (spender, reset && j == 0 ? 0 : a)),
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
                    if (step.b >= i || (operation == Operation.MulDiv && step.c >= i)) revert InvalidReference();
                    uint256 b = values[step.b];
                    if (operation == Operation.Equal && a != b) revert CheckFailed();
                    if (operation == Operation.LessOrEqual && a > b) revert CheckFailed();
                    if (operation == Operation.Add) values[i] = a + b;
                    else if (operation == Operation.Subtract) values[i] = a - b;
                    else if (operation == Operation.Minimum) values[i] = Math.min(a, b);
                    else if (operation == Operation.MulDiv) values[i] = Math.mulDiv(a, b, values[step.c]);
                }
            }
        }
        emit Execute(recipeHash);
    }

    /* INTERNAL FUNCTIONS */

    function _checkAction(IMerkleAdapter.Action memory action, bytes32 leaf) internal pure {
        if (
            action.value > 0
                || MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask) != leaf
        ) revert InvalidAction();
    }

    function _word(bytes memory data, uint256 offset) internal pure returns (uint256 result) {
        if (data.length < 32 || offset > data.length - 32) revert InvalidWord();
        assembly ("memory-safe") {
            result := mload(add(add(data, 32), offset))
        }
    }
}
