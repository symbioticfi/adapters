// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ACTIVITY_TRANSACTION_GAS_LIMIT} from "./ActivityContext.sol";
import {TestnetPermissions} from "../TestnetPermissions.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";
import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {OP_MANAGE} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MerkleProgram
 * @notice Builds curator-authorized finite programs that execute protocol calls from strategy custody.
 */
library MerkleProgram {
    error InvalidProgram();

    /**
     * @notice Saved deployment authority and permissions restored after each manual strategy program.
     */
    struct Context {
        address owner;
        address account;
        address rootRegistry;
        address executor;
        IMerkleAccount.Action[] baseActions;
        bytes[] baseRecipe;
    }

    /**
     * @notice Atomic recipe and ordered groups of newly authorized account actions.
     * @dev Groups index actions and correspond to the recipe's Manage instructions in execution order.
     */
    struct Program {
        IMerkleAccount.Action[] actions;
        bytes[] queries;
        bytes[] steps;
        uint256[][] groups;
        uint256[] inputs;
    }

    function step(IMerkleAccount.Action[] memory actions, uint256[] memory indices, uint256[][] memory bindings)
        internal
        pure
        returns (bytes memory)
    {
        bytes32[] memory leaves = new bytes32[](indices.length);
        for (uint256 i; i < indices.length; ++i) {
            IMerkleAccount.Action memory action = actions[indices[i]];
            if (action.value > 0) revert InvalidProgram();
            leaves[i] = ActionMasker.mask(action.target, action.value, action.data, action.dataMask);
        }
        return bytes.concat(bytes1(OP_MANAGE), abi.encode(uint256(1), leaves, bindings));
    }

    function validateAuthority(Context memory context) internal view returns (bytes32 baseRoot) {
        if (
            context.owner == address(0) || Ownable(context.account).owner() != context.owner
                || Ownable(context.rootRegistry).owner() != context.owner
                || RecipeExecutor(context.executor).owner() != context.owner
                || RecipeExecutor(context.executor).caller() != context.owner
                || RecipeExecutor(context.executor).account() != context.account
                || IMerkleAccount(context.account).ROOT_REGISTRY() != context.rootRegistry
        ) revert InvalidProgram();
        (baseRoot,) = TestnetPermissions.authorize(context.baseActions);
    }

    function validate(Context memory context) internal view returns (bytes32 baseRoot) {
        baseRoot = validateAuthority(context);
        if (
            IMerkleAccount(context.account).root() != baseRoot
                || RootRegistry(context.rootRegistry).roots(context.account) != baseRoot
                || RecipeExecutor(context.executor).recipeHash()
                    != keccak256(abi.encode(new bytes[](0), context.baseRecipe))
        ) {
            revert InvalidProgram();
        }
    }

    /**
     * @notice Restores the manifest's root and recipe after an explicitly reconciled interrupted broadcast.
     * @dev Validates authority without assuming current root or recipe state. Does not change balances, debt,
     * approvals, signatures or outstanding requests; their reconciliation and cleanup remain manual.
     */
    function restore(Context memory context) internal returns (bytes32 baseRoot) {
        baseRoot = validateAuthority(context);
        if (RootRegistry(context.rootRegistry).roots(context.account) != baseRoot) {
            RootRegistry(context.rootRegistry).setRoot(context.account, baseRoot);
        }
        if (IMerkleAccount(context.account).root() != baseRoot) IMerkleAccount(context.account).acceptRoot(baseRoot);
        if (RecipeExecutor(context.executor).recipeHash() != keccak256(abi.encode(new bytes[](0), context.baseRecipe)))
        {
            RecipeExecutor(context.executor).setRecipe(new bytes[](0), context.baseRecipe);
        }
        validate(context);
    }

    function execute(Context memory context, Program memory program) internal returns (uint256[] memory values) {
        bytes32 baseRoot = validate(context);
        IMerkleAccount.Action[] memory combined =
            new IMerkleAccount.Action[](context.baseActions.length + program.actions.length);
        for (uint256 i; i < context.baseActions.length; ++i) {
            combined[i] = context.baseActions[i];
        }
        for (uint256 i; i < program.actions.length; ++i) {
            if (program.actions[i].value > 0) revert InvalidProgram();
            combined[context.baseActions.length + i] = program.actions[i];
        }
        (bytes32 root, bytes32[] memory leaves) = TestnetPermissions.authorize(combined);
        RootRegistry(context.rootRegistry).setRoot(context.account, root);
        IMerkleAccount(context.account).acceptRoot(root);
        for (uint256 i; i < program.actions.length; ++i) {
            program.actions[i].proof = combined[context.baseActions.length + i].proof;
            IMerkleAccount(context.account).grantRole(leaves[context.baseActions.length + i], context.executor);
        }
        bytes[] memory runtime = new bytes[](program.groups.length);
        for (uint256 i; i < program.groups.length; ++i) {
            IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](program.groups[i].length);
            for (uint256 j; j < actions.length; ++j) {
                actions[j] = program.actions[program.groups[i][j]];
            }
            runtime[i] = abi.encode(actions);
        }
        RecipeExecutor(context.executor).setRecipe(program.queries, program.steps);
        values = RecipeExecutor(context.executor).execute{gas: ACTIVITY_TRANSACTION_GAS_LIMIT}(
            program.queries, program.steps, program.inputs, runtime
        );
        RootRegistry(context.rootRegistry).setRoot(context.account, baseRoot);
        IMerkleAccount(context.account).acceptRoot(baseRoot);
        RecipeExecutor(context.executor).setRecipe(new bytes[](0), context.baseRecipe);
    }
}
