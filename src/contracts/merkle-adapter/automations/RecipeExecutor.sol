// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Recipes} from "../Recipes.sol";

import {MerkleAdapterVerifier} from "../libraries/MerkleAdapterVerifier.sol";

import {IMerkleAccount} from "../../../interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeExecutor} from "../../../interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {OP_APPROVE, OP_CLEAR_APPROVAL, OP_MANAGE} from "../../../interfaces/merkle-adapter/IRecipes.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {Multicallable} from "@symbioticfi/core/src/contracts/common/Multicallable.sol";

/// @title RecipeExecutor
/// @notice Contract for curator-committed approved actions with dependent amounts and conditions.
contract RecipeExecutor is Recipes, Multicallable, Ownable, ReentrancyGuardTransient, IRecipeExecutor {
    /* IMMUTABLES */

    /// @inheritdoc IRecipeExecutor
    address public immutable account;

    /* STATE VARIABLES */

    /// @inheritdoc IRecipeExecutor
    address public caller;

    /// @inheritdoc IRecipeExecutor
    uint48 public recipeBlock;

    /// @inheritdoc IRecipeExecutor
    bytes32 public recipeHash;

    /* CONSTRUCTOR */

    constructor(address newOwner, address newAccount) Ownable(newOwner) {
        account = newAccount;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IRecipeExecutor
    function setCaller(address newCaller) public nonReentrant onlyOwner {
        caller = newCaller;
        emit SetCaller(newCaller);
    }

    /// @inheritdoc IRecipeExecutor
    function setRecipe(bytes[] calldata newQueries, bytes[] calldata newSteps) public nonReentrant onlyOwner {
        recipeHash = keccak256(abi.encode(newQueries, newSteps));
        recipeBlock = uint48(block.number);
        emit SetRecipe(recipeHash, newQueries, newSteps);
    }

    /// @inheritdoc IRecipeExecutor
    function execute(
        bytes[] calldata queries,
        bytes[] calldata steps,
        uint256[] calldata inputs,
        bytes[] calldata runtime
    ) public nonReentrant returns (uint256[] memory) {
        if (caller != msg.sender) revert InvalidCaller();
        if (recipeHash != keccak256(abi.encode(queries, steps))) revert InvalidRecipe();

        uint256 runtimeIndex;
        uint256 stepsLength = steps.length;
        State memory state;
        state.values = new uint256[](stepsLength);
        for (; state.index < stepsLength; ++state.index) {
            (uint8 operation, bytes calldata operationData) = _step(steps[state.index]);
            if (operation == OP_MANAGE) {
                bytes calldata payload = runtime[runtimeIndex++];
                (uint256 gate, bytes32[] memory leaves, uint256[][] memory bindings) =
                    abi.decode(operationData, (uint256, bytes32[], uint256[][]));
                if (_value(gate, steps, inputs, state) == 0) continue;
                IMerkleAccount.Action[] memory actions = abi.decode(payload, (IMerkleAccount.Action[]));
                uint256 actionsLength = actions.length;
                if (actionsLength != leaves.length || actionsLength != bindings.length) revert InvalidRuntime();
                for (uint256 i; i < actionsLength; ++i) {
                    _bind(actions[i].data, bindings[i], steps, inputs, state);
                    _checkAction(actions[i], leaves[i]);
                }
                IMerkleAccount(account).manage(actions);
            } else if (operation == OP_APPROVE || operation == OP_CLEAR_APPROVAL) {
                uint256 amount;
                address token;
                address spender;
                bytes32 leaf;
                if (operation == OP_APPROVE) {
                    (amount, token, spender, leaf) = abi.decode(operationData, (uint256, address, address, bytes32));
                    amount = _value(amount, steps, inputs, state);
                } else {
                    (token, spender, leaf) = abi.decode(operationData, (address, address, bytes32));
                }
                bytes calldata payload = runtime[runtimeIndex++];
                if (operation == OP_CLEAR_APPROVAL && IERC20(token).allowance(account, spender) == 0) continue;
                (bytes memory mask, bytes32[] memory proof) = abi.decode(payload, (bytes, bytes32[]));
                uint256 length = amount == 0 || IERC20(token).allowance(account, spender) == 0 ? 1 : 2;
                IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](length);
                for (uint256 i; i < length; ++i) {
                    IMerkleAccount.Action memory action = actions[i];
                    action.target = token;
                    action.data = abi.encodeCall(IERC20.approve, (spender, length == 1 || i > 0 ? amount : 0));
                    action.dataMask = mask;
                    action.proof = proof;
                    _checkAction(action, leaf);
                }
                bytes[] memory responses = IMerkleAccount(account).manage(actions);
                uint256 responsesLength = responses.length;
                for (uint256 i; i < responsesLength; ++i) {
                    if (responses[i].length > 0 && !abi.decode(responses[i], (bool))) revert ApprovalFailed();
                }
            } else {
                state.values[state.index] = _run(queries, steps, inputs, state);
            }
        }
        if (runtimeIndex != runtime.length) revert InvalidRuntime();
        return state.values;
    }

    /* INTERNAL FUNCTIONS */

    function _checkAction(IMerkleAccount.Action memory action, bytes32 leaf) internal pure {
        if (
            action.value > 0
                || MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask) != leaf
        ) revert InvalidAction();
    }
}
