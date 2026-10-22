// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";
import {ThreeFGuardedMint} from "./ThreeFGuardedMint.sol";

import {OP_ADD, OP_LESS_OR_EQUAL} from "src/interfaces/merkle-adapter/IRecipes.sol";

/**
 * @title ThreeFExecuting
 * @notice Library for native 3F funding and minting entirely through RecipeExecutor.
 * @dev The executor reaches RecipeCapability.execute through account.manage. The account consumes
 * its policy and mints in one Merkle-committed sequence that verifies exact principal, yield and cash
 * deltas and manages its own approval. Inputs select request, principal and yield; the nested leaf checks
 * them against live authorization before consuming policy. Selection and offer management belong to the
 * offchain host. Do not authorize
 * separate raw mint or unrestricted approval leaves, which could bypass the policy.
 */
library ThreeFExecuting {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    struct Config {
        ExecutingRecipe.Funding funding;
        address request;
        address policy;
        address underlyingAsset;
        bytes32 mintLeaf;
        uint256 maxPrincipal;
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

    /// @notice Raised when market groups are empty, ambiguous or have different custody accounts.
    error InvalidMarkets();

    function build(Config[] memory configs)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory recipe, Layout[] memory layouts)
    {
        if (configs.length == 0 || configs.length > 32) revert InvalidMarkets();
        uint256 capacity = 32 * configs.length;
        for (uint256 i; i < configs.length; ++i) {
            Config memory config = configs[i];
            if (config.funding.account != configs[0].funding.account) revert InvalidMarkets();
            for (uint256 j; j < i; ++j) {
                if (
                    configs[j].funding.asset == config.funding.asset
                        && configs[j].underlyingAsset == config.underlyingAsset
                ) {
                    revert InvalidMarkets();
                }
            }
            for (uint256 j; j < config.funding.sources.length; ++j) {
                if (
                    config.funding.sources[j].prepare.target != address(0)
                        || config.funding.sources[j].prepare.data.length != 0
                ) revert InvalidMarkets();
            }
            capacity += 12 * config.funding.sources.length;
        }
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(capacity);
        layouts = new Layout[](configs.length);
        uint256 total;
        for (uint256 i; i < configs.length; ++i) {
            Config memory config = configs[i];
            Layout memory layout;
            layout.request = builder.input(3 * i);
            layout.principal = builder.input(3 * i + 1);
            layout.authorizedYield = builder.input(3 * i + 2);
            builder.check(OP_LESS_OR_EQUAL, layout.request, builder.literal(type(uint160).max));
            builder.check(OP_LESS_OR_EQUAL, layout.authorizedYield, builder.literal(type(uint128).max));
            builder.check(OP_LESS_OR_EQUAL, layout.principal, builder.literal(config.maxPrincipal));
            total = builder.binary(OP_ADD, total, layout.principal);
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
            layout.operation = builder.manage(layout.principal, leaves, bindings);
            layouts[i] = layout;
        }
        // Inactive groups use zero principal; an all-zero execution is never useful.
        builder.check(OP_LESS_OR_EQUAL, builder.literal(1), total);
        recipe = builder.finish();
    }
}
