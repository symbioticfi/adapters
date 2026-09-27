// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Recipes} from "../Recipes.sol";

import {MerkleAdapterVerifier} from "../libraries/MerkleAdapterVerifier.sol";

import {IMerkleAccount} from "../../../interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeExecutor} from "../../../interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {OP_APPROVE, OP_MANAGE} from "../../../interfaces/merkle-adapter/IRecipes.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Multicallable} from "@symbioticfi/core/src/contracts/common/Multicallable.sol";

/// @title RecipeExecutor
/// @notice Contract for curator-committed approved actions with dependent amounts and conditions.
contract RecipeExecutor is Recipes, Multicallable, Ownable, ReentrancyGuardTransient, IRecipeExecutor {
    using SafeCast for uint256;

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
        recipeBlock = block.number.toUint48();
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
        return _execute(queries, steps, inputs, runtime);
    }

    /* INTERNAL FUNCTIONS */

    function _run(bytes[] calldata queries, bytes[] calldata steps, bytes[] calldata runtime, Execution memory state)
        internal
        override
        returns (uint256)
    {
        uint8 operation = uint8(steps[state.index][0]);
        IMerkleAccount.Action[] memory actions;
        if (operation == OP_MANAGE) {
            bytes32[] memory leaves;
            uint256[][] memory bindings;
            {
                bytes calldata payload = runtime[state.runtimeIndex++];
                uint256 gate;
                (gate, leaves, bindings) = abi.decode(steps[state.index][1:], (uint256, bytes32[], uint256[][]));
                if (_value(gate, steps, state) == 0) return 0;
                actions = abi.decode(payload, (IMerkleAccount.Action[]));
            }
            uint256 actionsLength = actions.length;
            if (actionsLength != leaves.length || actionsLength != bindings.length) revert InvalidRuntime();
            for (uint256 i; i < actionsLength; ++i) {
                _bind(actions[i].data, bindings[i], steps, state);
                _checkAction(actions[i], leaves[i]);
            }
        } else if (operation == OP_APPROVE) {
            (uint256 amount, address token, address spender, bytes32 leaf) =
                abi.decode(steps[state.index][1:], (uint256, address, address, bytes32));
            amount = _value(amount, steps, state);
            (bytes memory mask, bytes32[] memory proof) = abi.decode(runtime[state.runtimeIndex++], (bytes, bytes32[]));
            uint256 length = amount == 0 || IERC20(token).allowance(account, spender) == 0 ? 1 : 2;
            actions = new IMerkleAccount.Action[](length);
            for (uint256 i; i < length; ++i) {
                IMerkleAccount.Action memory action = actions[i];
                action.target = token;
                action.data = abi.encodeCall(IERC20.approve, (spender, length == 1 || i > 0 ? amount : 0));
                action.dataMask = mask;
                action.proof = proof;
                _checkAction(action, leaf);
            }
        } else {
            return super._run(queries, steps, runtime, state);
        }
        bytes[] memory responses = IMerkleAccount(account).manage(actions);
        if (operation == OP_APPROVE) {
            uint256 responsesLength = responses.length;
            for (uint256 i; i < responsesLength; ++i) {
                if (responses[i].length > 0 && !abi.decode(responses[i], (bool))) revert ApprovalFailed();
            }
        }
        return 0;
    }

    function _checkAction(IMerkleAccount.Action memory action, bytes32 leaf) internal pure {
        if (
            action.value > 0
                || MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask) != leaf
        ) revert InvalidAction();
    }
}
