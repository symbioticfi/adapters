// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

/// @notice Executes a claim supplied by the executor. The native contract enforces claim validity.
library ClaimRecipe {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    error InvalidConfiguration();

    struct Claim {
        bytes32[] leaves;
    }

    function build(Claim[] memory claims)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory recipe, uint256[] memory claimCalls)
    {
        if (claims.length != 1 || claims[0].leaves.length != 1) revert InvalidConfiguration();
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(1);
        claimCalls = new uint256[](1);
        claimCalls[0] = builder.manage(builder.literal(1), claims[0].leaves, new uint256[][](1));
        recipe = builder.finish();
    }
}
