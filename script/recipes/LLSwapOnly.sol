// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {OP_ADD, OP_EQUAL, OP_MIN, OP_SUB} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

/**
 * @title LLSwapOnly
 * @notice Library for one committed executor covering admitted Liquid Lane acquisition assets.
 * @dev Each route owns an RWA/payment input pair. Unselected pairs are zero; exactly one pair is active.
 * Token, recipient and signed swap identity remain pinned in each permission. Issuer redemption routes
 * use LLExecuting separately so acquisition cannot silently omit a required issuer action.
 */
library LLSwapOnly {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    struct Route {
        address rwa;
        bytes32 swapLeaf;
    }

    struct Config {
        ExecutingRecipe.Funding funding;
        address connector;
        address recipient;
        bytes32 approvalLeaf;
        Route[] routes;
    }

    struct Layout {
        uint256[] sourceCalls;
        uint256[] sourceAmounts;
        uint256 approve;
        uint256[] operations;
        uint256 clearApproval;
    }

    function build(Config memory config)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory recipe, Layout memory layout)
    {
        uint256 length = config.routes.length;
        if (length == 0 || length > 64) revert ExecutingRecipe.InvalidConfiguration();
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(12 + length * 24 + config.funding.sources.length);
        uint256 active = builder.literal(0);
        uint256 payment = builder.literal(0);
        for (uint256 i; i < length; ++i) {
            if (config.routes[i].rwa == address(0) || config.routes[i].swapLeaf == bytes32(0)) {
                revert ExecutingRecipe.InvalidConfiguration();
            }
            for (uint256 j; j < i; ++j) {
                if (config.routes[j].rwa == config.routes[i].rwa) revert ExecutingRecipe.InvalidConfiguration();
            }
            uint256 gate = builder.binary(OP_MIN, builder.input(i * 2), builder.literal(1));
            active = builder.binary(OP_ADD, active, gate);
            payment = builder.binary(OP_ADD, payment, builder.input(i * 2 + 1));
        }
        builder.check(OP_EQUAL, active, builder.literal(1));
        (layout.sourceCalls, layout.sourceAmounts) = builder.fund(config.funding, payment);
        layout.approve = builder.approve(config.funding.asset, config.connector, config.approvalLeaf, payment);
        layout.operations = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            uint256 amount = builder.input(i * 2);
            uint256 paid = builder.balance(config.funding.asset, config.recipient);
            uint256 cash = builder.balance(config.funding.asset, config.funding.account);
            uint256 held = builder.balance(config.routes[i].rwa, config.funding.account);
            bytes32[] memory leaves = new bytes32[](1);
            leaves[0] = config.routes[i].swapLeaf;
            uint256[][] memory bindings = new uint256[][](1);
            bindings[0] = new uint256[](1);
            bindings[0][0] = ExecutingRecipe.binding(100, amount);
            layout.operations[i] = builder.manage(leaves, amount, bindings);
            builder.check(
                OP_EQUAL,
                builder.binary(OP_SUB, cash, builder.balance(config.funding.asset, config.funding.account)),
                builder.input(i * 2 + 1)
            );
            builder.check(
                OP_EQUAL,
                builder.binary(OP_SUB, builder.balance(config.funding.asset, config.recipient), paid),
                builder.input(i * 2 + 1)
            );
            builder.check(
                OP_EQUAL,
                builder.binary(OP_SUB, builder.balance(config.routes[i].rwa, config.funding.account), held),
                amount
            );
        }
        layout.clearApproval = builder.clearApproval(config.funding.asset, config.connector, config.approvalLeaf);
        recipe = builder.finish();
    }
}
