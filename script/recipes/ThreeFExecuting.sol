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
 * them against live authorization before consuming policy. Alternatively, all three optional live Read
 * descriptors select the request and authorization before funding, using empty execution inputs. Do not authorize
 * separate raw mint or unrestricted approval leaves, which could bypass the policy.
 */
library ThreeFExecuting {
    using ExecutingRecipe for ExecutingRecipe.Builder;
    error InvalidConfiguration();

    struct Config {
        ExecutingRecipe.Funding funding;
        address request;
        address policy;
        address underlyingAsset;
        bytes32 mintLeaf;
        uint256 maxPrincipal;

        ExecutingRecipe.Read selectedRequest;
        ExecutingRecipe.Read authorizedPrincipal;
        ExecutingRecipe.Read authorizedYield;
    }

    // Calls and approvals index runtime payloads; packed result operands reference instructions.
    struct Layout {
        uint256[] sourceCalls;
        uint256[] sourceAmounts;
        uint256 principal;
        uint256 authorizedYield;
        uint256 request;
        uint256 operation;
    }

    function build(Config memory config)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory recipe, Layout memory layout)
    {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(24 + config.funding.sources.length);
        bool selected = config.selectedRequest.target != address(0);
        if (
            selected != (config.authorizedPrincipal.target != address(0))
                || selected != (config.authorizedYield.target != address(0))
        ) revert InvalidConfiguration();
        if (selected) {
            for (uint256 i; i < config.funding.sources.length; ++i) {
                // OP_CALL has no runtime gate; native idle execution must perform no preparation.
                if (config.funding.sources[i].prepare.target != address(0)) revert InvalidConfiguration();
            }
        }
        layout.request = selected ? builder.read(config.selectedRequest) : builder.input(0);
        layout.principal = selected ? builder.read(config.authorizedPrincipal) : builder.input(1);
        layout.authorizedYield = selected ? builder.read(config.authorizedYield) : builder.input(2);
        if (!selected) builder.check(OP_LESS_OR_EQUAL, builder.literal(1), layout.principal);
        builder.check(OP_LESS_OR_EQUAL, layout.principal, builder.literal(config.maxPrincipal));
        (layout.sourceCalls, layout.sourceAmounts) = builder.fund(config.funding, layout.principal);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = config.mintLeaf;
        uint256[][] memory bindings = new uint256[][](1);
        ThreeFGuardedMint.Leaf memory leaf = ThreeFGuardedMint.build(
            ThreeFGuardedMint.Config({
                account: config.funding.account,
                asset: config.funding.asset,
                underlyingAsset: config.underlyingAsset,
                policy: config.policy,
                request: config.request
            })
        );
        bindings[0] = ThreeFGuardedMint.bindings(leaf, layout.principal, layout.authorizedYield, layout.request);
        layout.operation = builder.manage(leaves, layout.principal, bindings);
        recipe = builder.finish();
    }
}
