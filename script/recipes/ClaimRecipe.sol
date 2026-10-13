// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {OP_EQUAL, OP_LESS_OR_EQUAL, OP_MAX, OP_MIN, OP_SUB} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

/**
 * @title ClaimRecipe
 * @notice Library for claiming independently settled redemptions, withdrawals, mints and rewards.
 * @dev Requests and issuer settlement happen before execution. Each claimable query must read the amount
 * available to the MerkleAccount for the exact configured operation, in the units accepted by its claim call.
 * For asynchronous ERC-4626 use maxMint/maxWithdraw/maxRedeem rather than reverting preview methods.
 * Leaves must pin the protocol, token, recipient/controller and any request identifiers not bound by the query.
 * Query bindings can select request IDs from inputs; the action must bind or pin the same identifiers.
 * Capped claims must reduce the queried claimable amount by exactly the selected amount.
 * Zero-claimable groups skip both output reads and actions. All-empty runs revert. Output checks measure only
 * newly received tokens; old balances, remaining pending requests and debt do not prevent a successful claim.
 */
library ClaimRecipe {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    error InvalidConfiguration();

    struct Output {
        address token;
        ExecutingRecipe.Read balance;
        uint256 minNumerator;
        uint256 denominator;
    }

    struct Claim {
        ExecutingRecipe.Query claimable;
        // Zero uses readiness as a gate; a positive cap also requires an exact selected claimable debit.
        uint256 maxAmount;
        bytes32[] leaves;
        uint256[][] amountOffsets;
        Output[] outputs;
    }

    /**
     * @notice Builds a standalone claim recipe that skips operations still awaiting settlement.
     * @param account Custody account receiving all outputs.
     * @param claims Independent operations, optional raw amount caps and minimum output units per selected unit.
     * @return recipe Committed queries and steps.
     * @return claimCalls Runtime payload indices for the claim action groups.
     */
    function build(address account, Claim[] memory claims)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory recipe, uint256[] memory claimCalls)
    {
        if (account == address(0) || claims.length == 0) revert InvalidConfiguration();
        uint256 capacity = 4 + 10 * claims.length;
        for (uint256 i; i < claims.length; ++i) {
            capacity += 7 * claims[i].outputs.length;
        }
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(capacity);
        uint256 progress = builder.literal(0);
        claimCalls = new uint256[](claims.length);
        for (uint256 i; i < claims.length; ++i) {
            Claim memory claim = claims[i];
            if (claim.claimable.target == address(0) || claim.leaves.length == 0 || claim.outputs.length == 0) {
                revert InvalidConfiguration();
            }
            uint256 claimable = builder.readQuery(claim.claimable);
            uint256 amount =
                claim.maxAmount > 0 ? builder.binary(OP_MIN, claimable, builder.literal(claim.maxAmount)) : claimable;
            uint256[] memory balances = new uint256[](claim.outputs.length);
            bool positiveMinimum;
            for (uint256 j; j < claim.outputs.length; ++j) {
                if (
                    claim.outputs[j].denominator == 0
                        || (claim.outputs[j].token == address(0)) == (claim.outputs[j].balance.target == address(0))
                ) {
                    revert InvalidConfiguration();
                }
                if (claim.outputs[j].minNumerator >= claim.outputs[j].denominator) positiveMinimum = true;
                balances[j] = builder.readIf(
                    claim.outputs[j].token > address(0)
                        ? ExecutingRecipe.balanceQuery(claim.outputs[j].token, account)
                        : ExecutingRecipe.query(claim.outputs[j].balance),
                    amount,
                    0
                );
            }
            claimCalls[i] =
                builder.manage(claim.leaves, amount, ExecutingRecipe.amountBindings(claim.amountOffsets, amount));
            if (claim.maxAmount > 0) {
                builder.check(
                    OP_EQUAL,
                    builder.binary(OP_SUB, claimable, builder.readIf(claim.claimable, amount, claimable)),
                    amount
                );
            }
            bool amountWitness = positiveMinimum && claim.outputs.length > 1;
            uint256 received = builder.literal(0);
            for (uint256 j; j < claim.outputs.length; ++j) {
                uint256 delta = builder.binary(
                    OP_SUB,
                    builder.readIf(
                        claim.outputs[j].token > address(0)
                            ? ExecutingRecipe.balanceQuery(claim.outputs[j].token, account)
                            : ExecutingRecipe.query(claim.outputs[j].balance),
                        amount,
                        0
                    ),
                    balances[j]
                );
                builder.check(
                    OP_LESS_OR_EQUAL,
                    claim.maxAmount > 0 && claim.outputs[j].minNumerator == claim.outputs[j].denominator
                        && claim.outputs[j].denominator > 0 && claim.outputs[j].denominator <= type(uint216).max
                        && claim.maxAmount <= type(uint256).max / claim.outputs[j].denominator
                        ? amount
                        : builder.mulDiv(
                            amount,
                            builder.literal(claim.outputs[j].minNumerator),
                            builder.literal(claim.outputs[j].denominator)
                        ),
                    delta
                );
                if (!amountWitness) received = builder.binary(OP_MAX, received, delta);
            }
            if (!positiveMinimum) {
                builder.check(OP_LESS_OR_EQUAL, builder.binary(OP_MIN, amount, builder.literal(1)), received);
            }
            progress = builder.binary(OP_MAX, progress, amountWitness ? amount : received);
        }
        builder.check(OP_LESS_OR_EQUAL, builder.literal(1), progress);
        recipe = builder.finish();
    }
}
