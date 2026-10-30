// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

import {OP_ADD, OP_EQUAL, OP_MIN, OP_SATURATING_SUB, OP_SUB} from "src/interfaces/merkle-adapter/IRecipes.sol";

/**
 * @title WithdrawalsRecipe
 * @notice Library for covering a vault withdrawal queue's live demand from account cash and synchronous withdrawals.
 * @dev Demand is the queue's pending assets above the vault's free assets, the preceding adapters' total assets and
 * the following adapters' free assets, capped by this adapter's total assets, matching the delegator's sweep: it
 * first takes every adapter's free assets, then deallocates in route order. Already locked adapter liquidity
 * counts as covered. Sources withdraw in order only what account cash cannot cover, and the account then returns
 * the covered amount to the adapter, which must lock exactly that amount. A source with a debt read is skipped
 * whenever that debt is positive. The delegator's complete adapter route is checked before any amount is computed,
 * so an adapter added later makes the recipe fail rather than leave its free assets uncounted.
 */
library WithdrawalsRecipe {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    error InvalidConfiguration();

    struct Source {
        ExecutingRecipe.Read capacity;
        // Optional; any positive value makes the source unavailable.
        ExecutingRecipe.Read debt;
        bytes32[] leaves;
        uint256[][] amountOffsets;
    }

    struct Config {
        address adapter;
        address account;
        address asset;
        address vault;
        address delegator;
        address queue;
        address[] precedingAdapters;
        address[] followingAdapters;
        bytes32 returnLeaf;
        uint256[] returnAmountOffsets;
        Source[] sources;
    }

    // Calls index runtime payloads; amount references an instruction.
    struct Layout {
        uint256[] sourceCalls;
        uint256 returnStep;
        uint256 amount;
    }

    function build(Config memory config)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory recipe, Layout memory layout)
    {
        uint256 precedingLength = config.precedingAdapters.length;
        uint256 followingLength = config.followingAdapters.length;
        uint256 sourcesLength = config.sources.length;
        ExecutingRecipe.Builder memory builder =
            ExecutingRecipe.start(32 + 4 * (precedingLength + followingLength) + 8 * sourcesLength);
        builder.check(
            OP_EQUAL,
            _read(builder, config.delegator, abi.encodeWithSignature("getAdaptersLength()")),
            builder.literal(precedingLength + 1 + followingLength)
        );
        for (uint256 i; i <= precedingLength + followingLength; ++i) {
            address expected = i < precedingLength
                ? config.precedingAdapters[i]
                : i == precedingLength ? config.adapter : config.followingAdapters[i - precedingLength - 1];
            builder.check(
                OP_EQUAL,
                _read(builder, config.delegator, abi.encodeWithSignature("adapters(uint256)", i)),
                builder.literal(uint160(expected))
            );
        }

        uint256 queuePending = _read(builder, config.queue, abi.encodeWithSignature("pendingAssets()"));
        uint256 need = builder.binary(
            OP_SATURATING_SUB, queuePending, _read(builder, config.vault, abi.encodeWithSignature("freeAssets()"))
        );
        for (uint256 i; i < precedingLength; ++i) {
            need = builder.binary(
                OP_SATURATING_SUB,
                need,
                _read(builder, config.precedingAdapters[i], abi.encodeWithSignature("totalAssets()"))
            );
        }
        for (uint256 i; i < followingLength; ++i) {
            need = builder.binary(
                OP_SATURATING_SUB,
                need,
                _read(builder, config.followingAdapters[i], abi.encodeWithSignature("freeAssets()"))
            );
        }
        need = builder.binary(OP_MIN, need, _read(builder, config.adapter, abi.encodeWithSignature("totalAssets()")));
        uint256 lockedBefore = _read(builder, config.adapter, abi.encodeWithSignature("lockedLiquidity()"));
        uint256 adapterCash = builder.balance(config.asset, config.adapter);
        need = builder.binary(OP_SATURATING_SUB, need, lockedBefore);
        uint256 cash = builder.balance(config.asset, config.account);

        layout.sourceCalls = new uint256[](sourcesLength);
        for (uint256 i; i < sourcesLength; ++i) {
            Source memory source = config.sources[i];
            if (source.leaves.length != 1 || source.capacity.target == address(0)) revert InvalidConfiguration();
            uint256 available = builder.read(source.capacity);
            if (source.debt.target != address(0)) {
                available = builder.mulDiv(
                    available,
                    builder.binary(OP_SATURATING_SUB, builder.literal(1), builder.read(source.debt)),
                    builder.literal(1)
                );
            }
            uint256 amount = builder.binary(OP_MIN, builder.binary(OP_SATURATING_SUB, need, cash), available);
            layout.sourceCalls[i] =
                builder.manage(amount, source.leaves, ExecutingRecipe.amountBindings(source.amountOffsets, amount));
            uint256 cashAfter = builder.balance(config.asset, config.account);
            builder.check(OP_EQUAL, builder.binary(OP_SUB, cashAfter, cash), amount);
            cash = cashAfter;
        }

        layout.amount = builder.binary(OP_MIN, need, cash);
        {
            bytes32[] memory leaves = new bytes32[](1);
            leaves[0] = config.returnLeaf;
            uint256[][] memory offsets = new uint256[][](1);
            offsets[0] = config.returnAmountOffsets;
            layout.returnStep =
                builder.manage(layout.amount, leaves, ExecutingRecipe.amountBindings(offsets, layout.amount));
        }
        builder.check(
            OP_EQUAL, builder.balance(config.asset, config.account), builder.binary(OP_SUB, cash, layout.amount)
        );
        builder.check(
            OP_EQUAL, builder.balance(config.asset, config.adapter), builder.binary(OP_ADD, adapterCash, layout.amount)
        );
        builder.check(
            OP_EQUAL,
            _read(builder, config.adapter, abi.encodeWithSignature("lockedLiquidity()")),
            builder.binary(OP_ADD, lockedBefore, layout.amount)
        );
        builder.check(OP_EQUAL, _read(builder, config.queue, abi.encodeWithSignature("pendingAssets()")), queuePending);
        recipe = builder.finish();
    }

    function _read(ExecutingRecipe.Builder memory builder, address target, bytes memory data)
        private
        pure
        returns (uint256)
    {
        return builder.read(ExecutingRecipe.Read({target: target, data: data, offset: 0}));
    }
}
