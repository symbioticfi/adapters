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
        uint256 stepsLength = steps.length;
        State memory state = State({values: new uint256[](stepsLength), index: 0});
        for (; state.index < stepsLength; ++state.index) {
            state.values[state.index] = _run(queries, steps, inputs, state);
        }
        return state.values;
    }
}
