// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";
import {ThreeFGuardedMint} from "./ThreeFGuardedMint.sol";

import {OP_EQUAL, OP_LESS_OR_EQUAL} from "src/interfaces/merkle-adapter/IRecipes.sol";

/**
 * @title ThreeFExecuting
 * @notice Library for native 3F funding and minting entirely through RecipeExecutor.
 * @dev The executor reaches RecipeCapability.execute through account.manage. The account consumes
 * its policy and mints in one Merkle-committed sequence that verifies exact principal, yield and cash
 * deltas and manages its own approval. Inputs select request, principal and yield; the nested leaf checks
 * them against live authorization before consuming policy. Do not authorize
 * separate raw mint or unrestricted approval leaves, which could bypass the policy.
 */
library ThreeFExecuting {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    struct Config {
        ExecutingRecipe.Funding funding;
        address request;
        address policy;
        bytes32 approvalLeaf;
        bytes32 mintLeaf;
        uint256 maxPrincipal;
        bool skipZeroApprovals;
        bool reuseTupleReads;
    }

    // Calls and approvals index runtime payloads; packed result operands reference instructions.
    struct Layout {
        uint256[] sourceCalls;
        uint256[] sourceAmounts;
        uint256 principal;
        uint256 authorizedYield;
        uint256 approve;
        uint256 operation;
        uint256 clearApproval;
    }

    function build(Config memory config)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory recipe, Layout memory layout)
    {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(24 + config.funding.sources.length);
        layout.principal = builder.input(1);
        layout.authorizedYield = builder.input(2);
        builder.check(OP_LESS_OR_EQUAL, builder.literal(1), layout.principal);
        builder.check(OP_LESS_OR_EQUAL, layout.principal, builder.literal(config.maxPrincipal));
        (layout.sourceCalls, layout.sourceAmounts) = builder.fund(config.funding, layout.principal);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = config.mintLeaf;
        uint256[][] memory bindings = new uint256[][](1);
        ThreeFGuardedMint.Leaf memory leaf = ThreeFGuardedMint.build(
            ThreeFGuardedMint.Config({
                account: config.funding.account,
                asset: config.funding.asset,
                policy: config.policy,
                request: config.request
            }),
            config.reuseTupleReads
        );
        bindings[0] = ThreeFGuardedMint.bindings(leaf, layout.principal, layout.authorizedYield, builder.input(0));
        layout.operation = builder.manage(leaves, layout.principal, bindings);
        layout.clearApproval =
            builder.clearApproval(config.funding.asset, config.request, config.approvalLeaf, config.skipZeroApprovals);
        recipe = builder.finish();
    }
}
