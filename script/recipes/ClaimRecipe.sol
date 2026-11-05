// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

/// @notice Executes claims selected by the executor. Native contracts enforce claim validity.
library ClaimRecipe {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    error InvalidConfiguration();

    struct Argument {
        ExecutingRecipe.Query query;
        uint256[][] offsets;
    }

    struct Claim {
        bytes32[] leaves;
        // Only reads whose results are inserted into native claim arguments.
        Argument[] arguments;
    }

    function build(Claim[] memory claims)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory recipe, uint256[] memory claimCalls)
    {
        if (claims.length != 1) revert InvalidConfiguration();
        uint256 capacity = claims.length;
        for (uint256 i; i < claims.length; ++i) {
            capacity += claims[i].arguments.length;
        }
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(capacity);
        claimCalls = new uint256[](claims.length);
        for (uint256 i; i < claims.length; ++i) {
            claimCalls[i] = group(builder, claims[i]);
        }
        recipe = builder.finish();
    }

    function group(ExecutingRecipe.Builder memory builder, Claim memory claim) internal pure returns (uint256) {
        if (claim.leaves.length == 0) revert InvalidConfiguration();
        uint256[] memory values = new uint256[](claim.arguments.length);
        for (uint256 j; j < values.length; ++j) {
            if (claim.arguments[j].offsets.length != claim.leaves.length) revert InvalidConfiguration();
            bool used;
            for (uint256 i; i < claim.leaves.length; ++i) {
                if (claim.arguments[j].offsets[i].length != 0) used = true;
            }
            if (!used) revert InvalidConfiguration();
            values[j] = builder.readQuery(claim.arguments[j].query);
        }
        uint256[][] memory bindings = new uint256[][](claim.leaves.length);
        for (uint256 i; i < bindings.length; ++i) {
            uint256 count;
            for (uint256 j; j < values.length; ++j) {
                count += claim.arguments[j].offsets[i].length;
            }
            bindings[i] = new uint256[](count);
            uint256 cursor;
            for (uint256 j; j < values.length; ++j) {
                uint256[] memory offsets = claim.arguments[j].offsets[i];
                for (uint256 k; k < offsets.length; ++k) {
                    bindings[i][cursor++] = ExecutingRecipe.binding(offsets[k], values[j]);
                }
            }
            ExecutingRecipe.sortBindings(bindings[i]);
        }
        return builder.manage(builder.literal(1), claim.leaves, bindings);
    }
}
