// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";
import {ThreeFGuardedMint} from "./ThreeFGuardedMint.sol";

import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/automations/policies/IThreeFPolicy.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFRequestFactory} from "src/interfaces/3f-adapter/IThreeFRequestFactory.sol";
import {IThreeFVaultController} from "src/interfaces/3f-adapter/IThreeFVaultController.sol";

/**
 * @title ThreeFExecuting
 * @notice Library for native 3F funding and minting entirely through RecipeExecutor.
 * @dev With guardedMint, the account consumes the policy inside ThreeFGuardedMint. Otherwise the executor
 * consumes it through a committed Call and verifies the native mint's factory, principal, yield and cash
 * movements in the recipe. Set the policy's sole consumer to the account or executor respectively.
 * Direct mint and funding leaf roles must be restricted to the executor to enforce its recipe's policy.
 */
library ThreeFExecuting {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    struct Config {
        ExecutingRecipe.Funding funding;
        address request;
        address requestsFactory;
        address policy;
        bytes32 approvalLeaf;
        bytes32 mintLeaf;
        uint256 maxPrincipal;
        bool guardedMint;
    }

    // Calls and approvals index runtime payloads; numeric Values index instructions.
    struct Layout {
        uint256[] sourceCalls;
        uint256[] sourceAmounts;
        IRecipeExecutor.Value principal;
        IRecipeExecutor.Value authorizedYield;
        // Only direct mode uses this instruction index; Call has no runtime payload.
        uint256 consume;
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
        ExecutingRecipe.Read memory authorization = ExecutingRecipe.Read({
            target: config.request,
            data: abi.encodeCall(IThreeFPushRequest.mintAuthorization, (config.funding.account)),
            offset: 0
        });
        layout.principal = builder.read(authorization);
        authorization.offset = 32;
        layout.authorizedYield = builder.read(authorization);
        builder.check(IRecipeExecutor.Operation.LessOrEqual, builder.literal(1), layout.principal);
        builder.check(IRecipeExecutor.Operation.LessOrEqual, layout.principal, builder.literal(config.maxPrincipal));
        (layout.sourceCalls, layout.sourceAmounts) = builder.fund(config.funding, layout.principal);
        layout.approve = builder.approve(config.funding.asset, config.request, config.approvalLeaf, layout.principal);
        builder.check(IRecipeExecutor.Operation.Equal, layout.authorizedYield, builder.read(authorization));
        authorization.offset = 0;
        builder.check(IRecipeExecutor.Operation.Equal, layout.principal, builder.read(authorization));
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = config.mintLeaf;
        if (config.guardedMint) {
            layout.operation = builder.manage(leaves, layout.principal, _bindings(config, layout));
        } else {
            builder.check(
                IRecipeExecutor.Operation.Equal,
                builder.read(
                    ExecutingRecipe.Read({
                        target: config.requestsFactory,
                        data: abi.encodeCall(IThreeFRequestFactory.isRequest, (config.request)),
                        offset: 0
                    })
                ),
                builder.literal(1)
            );
            IRecipeExecutor.Value[3] memory beforeValues = _balances(builder, config);
            IRecipeExecutor.Binding[][] memory bindings = new IRecipeExecutor.Binding[][](1);
            bindings[0] = new IRecipeExecutor.Binding[](2);
            bindings[0][0] = IRecipeExecutor.Binding({offset: 36, value: layout.principal});
            bindings[0][1] = IRecipeExecutor.Binding({offset: 68, value: layout.authorizedYield});
            layout.consume = builder.call(
                config.policy, abi.encodeCall(IThreeFPolicy.consume, (config.funding.asset, 0, 0)), bindings[0]
            );
            bindings[0][0].offset = 4;
            bindings[0][1].offset = 36;
            layout.operation = builder.manage(leaves, layout.principal, bindings);
            IRecipeExecutor.Value[3] memory afterValues = _balances(builder, config);
            for (uint256 i; i < 3; ++i) {
                builder.check(
                    IRecipeExecutor.Operation.Equal,
                    builder.binary(
                        IRecipeExecutor.Operation.Sub,
                        i == 2 ? beforeValues[i] : afterValues[i],
                        i == 2 ? afterValues[i] : beforeValues[i]
                    ),
                    i == 1 ? layout.authorizedYield : layout.principal
                );
            }
        }
        layout.clearApproval =
            builder.approve(config.funding.asset, config.request, config.approvalLeaf, builder.literal(0));
        recipe = builder.finish();
    }

    function _balances(ExecutingRecipe.Builder memory builder, Config memory config)
        private
        pure
        returns (IRecipeExecutor.Value[3] memory values)
    {
        for (uint256 i; i < 2; ++i) {
            values[i] = builder.read(
                ExecutingRecipe.Read({
                    target: config.request,
                    data: abi.encodeCall(IThreeFVaultController.balancesOf, (config.funding.account)),
                    offset: i * 32
                })
            );
        }
        values[2] = builder.balance(config.funding.asset, config.funding.account);
    }

    /// @dev Feeds the live authorization into the guarded leaf's four variable words, in ascending order.
    function _bindings(Config memory config, Layout memory layout)
        private
        pure
        returns (IRecipeExecutor.Binding[][] memory bindings)
    {
        ThreeFGuardedMint.Leaf memory leaf = ThreeFGuardedMint.build(
            ThreeFGuardedMint.Config({
                account: config.funding.account,
                asset: config.funding.asset,
                policy: config.policy,
                request: config.request,
                requestsFactory: config.requestsFactory
            })
        );
        bindings = new IRecipeExecutor.Binding[][](1);
        bindings[0] = new IRecipeExecutor.Binding[](4);
        bindings[0][0] = IRecipeExecutor.Binding({offset: leaf.consumeAssets, value: layout.principal});
        bindings[0][1] = IRecipeExecutor.Binding({offset: leaf.consumeYield, value: layout.authorizedYield});
        bindings[0][2] = IRecipeExecutor.Binding({offset: leaf.mintPrincipal, value: layout.principal});
        bindings[0][3] = IRecipeExecutor.Binding({offset: leaf.mintYield, value: layout.authorizedYield});
    }
}
