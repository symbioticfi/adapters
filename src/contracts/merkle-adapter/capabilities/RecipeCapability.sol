// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Recipes} from "../Recipes.sol";

import {IRecipeCapability} from "../../../interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";

/// @title RecipeCapability
/// @notice Contract for stateless Merkle-committed recipes executed in the account's context.
contract RecipeCapability is Recipes, IRecipeCapability {
    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IRecipeCapability
    function execute(bytes[] calldata queries, bytes[] calldata steps, uint256[] calldata inputs)
        public
        returns (uint256[] memory)
    {
        if (address(this) != msg.sender) revert InvalidCaller();
        // Capability recipes have no account-management runtime entries.
        bytes[] calldata runtime = queries;
        assembly ("memory-safe") {
            runtime.length := 0
        }
        return _execute(queries, steps, inputs, runtime);
    }
}
