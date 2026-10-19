// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";
import {ThreeFGuardedMint} from "./ThreeFGuardedMint.sol";

import {OP_EQUAL, OP_LESS_OR_EQUAL, OP_SUB} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/automations/policies/IThreeFPolicy.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFVaultController} from "src/interfaces/3f-adapter/IThreeFVaultController.sol";

/**
 * @title ThreeFExecuting
 * @notice Library for native 3F funding and minting entirely through RecipeExecutor.
 * @dev With guardedMint, the account consumes the policy inside ThreeFGuardedMint. Otherwise the executor
 * consumes it through a committed Call. The policy validates the request and resolves its collateral
 * underlying; the recipe binds principal, yield and funding-token movements to the charge.
 * Set the policy's sole consumer to the account or executor respectively.
 * Direct mint and funding leaf roles must be restricted to the executor to enforce its recipe's policy.
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
        bool guardedMint;
        bool skipZeroApprovals;
        bool reuseTupleReads;
    }

    // Calls and approvals index runtime payloads; packed result operands reference instructions.
    struct Layout {
        uint256[] sourceCalls;
        uint256[] sourceAmounts;
        uint256 principal;
        uint256 authorizedYield;
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
        layout.principal = config.reuseTupleReads ? builder.readCached(authorization) : builder.read(authorization);
        authorization.offset = 32;
        layout.authorizedYield =
            config.reuseTupleReads ? builder.readWord(layout.principal, 32) : builder.read(authorization);
        builder.check(OP_LESS_OR_EQUAL, builder.literal(1), layout.principal);
        builder.check(OP_LESS_OR_EQUAL, layout.principal, builder.literal(config.maxPrincipal));
        (layout.sourceCalls, layout.sourceAmounts) = builder.fund(config.funding, layout.principal);
        layout.approve = builder.approve(config.funding.asset, config.request, config.approvalLeaf, layout.principal);
        uint256 refreshedYield =
            config.reuseTupleReads ? builder.readCached(authorization) : builder.read(authorization);
        builder.check(OP_EQUAL, layout.authorizedYield, refreshedYield);
        authorization.offset = 0;
        builder.check(
            OP_EQUAL,
            layout.principal,
            config.reuseTupleReads ? builder.readWord(refreshedYield, 0) : builder.read(authorization)
        );
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = config.mintLeaf;
        uint256[][] memory bindings = new uint256[][](1);
        if (config.guardedMint) {
            ThreeFGuardedMint.Leaf memory leaf = ThreeFGuardedMint.build(
                ThreeFGuardedMint.Config({
                    account: config.funding.account,
                    asset: config.funding.asset,
                    policy: config.policy,
                    request: config.request
                }),
                config.reuseTupleReads
            );
            bindings[0] = new uint256[](4);
            bindings[0][0] = ExecutingRecipe.binding(leaf.consumeAssets, layout.principal);
            bindings[0][1] = ExecutingRecipe.binding(leaf.consumeYield, layout.authorizedYield);
            bindings[0][2] = ExecutingRecipe.binding(leaf.mintPrincipal, layout.principal);
            bindings[0][3] = ExecutingRecipe.binding(leaf.mintYield, layout.authorizedYield);
            layout.operation = builder.manage(leaves, layout.principal, bindings);
        } else {
            uint256[3] memory beforeValues = _balances(builder, config);
            bindings[0] = new uint256[](2);
            bindings[0][0] = ExecutingRecipe.binding(36, layout.principal);
            bindings[0][1] = ExecutingRecipe.binding(68, layout.authorizedYield);
            layout.consume =
                builder.call(config.policy, abi.encodeCall(IThreeFPolicy.consume, (config.request, 0, 0)), bindings[0]);
            bindings[0][0] = ExecutingRecipe.binding(4, layout.principal);
            bindings[0][1] = ExecutingRecipe.binding(36, layout.authorizedYield);
            layout.operation = builder.manage(leaves, layout.principal, bindings);
            uint256[3] memory afterValues = _balances(builder, config);
            for (uint256 i; i < 3; ++i) {
                builder.check(
                    OP_EQUAL,
                    builder.binary(
                        OP_SUB, i == 2 ? beforeValues[i] : afterValues[i], i == 2 ? afterValues[i] : beforeValues[i]
                    ),
                    i == 1 ? layout.authorizedYield : layout.principal
                );
            }
        }
        layout.clearApproval =
            builder.clearApproval(config.funding.asset, config.request, config.approvalLeaf, config.skipZeroApprovals);
        recipe = builder.finish();
    }

    function _balances(ExecutingRecipe.Builder memory builder, Config memory config)
        private
        pure
        returns (uint256[3] memory values)
    {
        ExecutingRecipe.Read memory shares = ExecutingRecipe.Read({
            target: config.request,
            data: abi.encodeCall(IThreeFVaultController.balancesOf, (config.funding.account)),
            offset: 0
        });
        values[0] = config.reuseTupleReads ? builder.readCached(shares) : builder.read(shares);
        shares.offset = 32;
        values[1] = config.reuseTupleReads ? builder.readWord(values[0], 32) : builder.read(shares);
        values[2] = builder.balance(config.funding.asset, config.funding.account);
    }
}
