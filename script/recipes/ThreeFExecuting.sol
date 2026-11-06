// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";
import {ThreeFGuardedMint} from "./ThreeFGuardedMint.sol";

import {OP_LESS_OR_EQUAL} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";

import {IMulticall3} from "forge-std/interfaces/IMulticall3.sol";

/**
 * @title ThreeFExecuting
 * @notice Library for native 3F funding and minting entirely through RecipeExecutor.
 * @dev The executor reaches RecipeCapability.execute through account.manage. The account consumes
 * its policy and mints in one Merkle-committed sequence that verifies exact principal, yield and cash
 * deltas and manages its own approval. Each input selects a request; principal and yield come from its
 * live mint authorization. Selection and offer management belong to the
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
        bool resetApproval;
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
        if (configs.length == 0) revert InvalidMarkets();
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
        for (uint256 i; i < configs.length; ++i) {
            Config memory config = configs[i];
            Layout memory layout;
            layout.request = builder.input(i);
            IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](1);
            calls[0] = IMulticall3.Call3({
                target: address(0),
                allowFailure: false,
                callData: abi.encodeCall(IThreeFPushRequest.mintAuthorization, (config.funding.account))
            });
            uint256[] memory requestBinding = new uint256[](1);
            requestBinding[0] = ExecutingRecipe.binding(100, layout.request);
            // Multicall3 reads the runtime-selected request. Its one returned bytes value starts at byte 192.
            ExecutingRecipe.Query memory authorization = ExecutingRecipe.Query({
                target: 0xcA11bde05977b3631167028862bE2a173976CA11,
                data: abi.encodeCall(IMulticall3.aggregate3, (calls)),
                bindings: requestBinding,
                offset: 192
            });
            layout.principal = builder.readQuery(authorization);
            authorization.offset = 224;
            layout.authorizedYield = builder.readQuery(authorization);
            builder.check(OP_LESS_OR_EQUAL, layout.principal, builder.literal(config.maxPrincipal));
            (layout.sourceCalls, layout.sourceAmounts) = builder.fund(config.funding, layout.principal);
            bytes32[] memory leaves = new bytes32[](1);
            leaves[0] = config.mintLeaf;
            uint256[][] memory bindings = new uint256[][](1);
            ThreeFGuardedMint.Leaf memory leaf = ThreeFGuardedMint.build(
                ThreeFGuardedMint.Config({
                    account: config.funding.account,
                    asset: config.funding.asset,
                    resetApproval: config.resetApproval,
                    policy: config.policy,
                    request: config.request
                })
            );
            bindings[0] = ThreeFGuardedMint.bindings(leaf, layout.principal, layout.authorizedYield, layout.request);
            layout.operation =
                builder.manage(configs.length == 1 ? builder.literal(1) : layout.principal, leaves, bindings);
            layouts[i] = layout;
        }
        recipe = builder.finish();
    }
}
