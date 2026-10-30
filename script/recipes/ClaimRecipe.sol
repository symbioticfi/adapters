// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

/**
 * @title ClaimRecipe
 * @notice One permissioned claim per execution. The caller discovers ready requests offchain.
 * @dev Repeat execute through RecipeExecutor.multicall for multiple requests. The account
 * validates each leaf and recipient restriction; the issuer validates claim eligibility.
 */
library ClaimRecipe {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    error InvalidConfiguration();

    struct Claim {
        bytes32[] leaves;
    }

    function build(address account, Claim[] memory claims)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory recipe, uint256[] memory claimCalls)
    {
        if (account == address(0) || claims.length != 1 || claims[0].leaves.length == 0) {
            revert InvalidConfiguration();
        }
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(1);
        claimCalls = new uint256[](1);
        claimCalls[0] = builder.manage(builder.literal(1), claims[0].leaves, new uint256[][](claims[0].leaves.length));
        recipe = builder.finish();
    }
}
