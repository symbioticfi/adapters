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
 * Zero-claimable groups skip actions; all required queries still execute. All-empty runs can succeed without work.
 * Output checks measure only newly received tokens; old balances, remaining pending requests and debt do not prevent a claim.
 */
library ClaimRecipe {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    error InvalidConfiguration();

    struct Output {
        address token;
        ExecutingRecipe.Read balance;
        ExecutingRecipe.Read minimum;
        uint256 minNumerator;
        uint256 denominator;
    }

    struct Claim {
        ExecutingRecipe.Query claimable;
        ExecutingRecipe.Read selectedId;
        uint256[] claimableIdOffsets;
        uint256[][] idOffsets;
        // Zero uses readiness as a gate; a positive cap also requires an exact selected claimable debit.
        uint256 maxAmount;
        bytes32[] leaves;
        uint256[][] amountOffsets;
        Output[] outputs;
    }

    /**
     * @notice Builds a standalone claim recipe that skips operations still awaiting settlement.
     * @dev A manual all-empty invocation can succeed without work. A keeper must classify successful
     * simulation before deciding whether to submit. Required reads and per-group economic checks remain enforced.
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
        claimCalls = new uint256[](claims.length);
        for (uint256 i; i < claims.length; ++i) {
            Claim memory claim = claims[i];
            if (claim.claimable.target == address(0) || claim.leaves.length == 0 || claim.outputs.length == 0) {
                revert InvalidConfiguration();
            }
            uint256 id = claim.selectedId.target != address(0) ? builder.read(claim.selectedId) : builder.literal(0);
            if (
                claim.selectedId.target == address(0)
                    && (claim.claimableIdOffsets.length > 0 || claim.idOffsets.length > 0)
            ) revert InvalidConfiguration();
            ExecutingRecipe.Query memory readiness =
                ExecutingRecipe.bindQuery(claim.claimable, claim.claimableIdOffsets, id);
            uint256 claimable = builder.readQuery(readiness);
            uint256 amount =
                claim.maxAmount > 0 ? builder.binary(OP_MIN, claimable, builder.literal(claim.maxAmount)) : claimable;
            uint256[] memory balances = new uint256[](claim.outputs.length);
            uint256[] memory minimums = new uint256[](claim.outputs.length);
            bool positiveMinimum;
            for (uint256 j; j < claim.outputs.length; ++j) {
                if (
                    claim.outputs[j].denominator == 0
                        || (claim.outputs[j].token == address(0)) == (claim.outputs[j].balance.target == address(0))
                ) {
                    revert InvalidConfiguration();
                }
                if (
                    claim.outputs[j].minimum.target == address(0)
                        && claim.outputs[j].minNumerator >= claim.outputs[j].denominator
                ) positiveMinimum = true;
                if (claim.outputs[j].minimum.target != address(0)) {
                    if (claim.maxAmount != 0) revert InvalidConfiguration();
                    minimums[j] = builder.readIf(ExecutingRecipe.query(claim.outputs[j].minimum), amount, 0);
                }
                balances[j] = builder.readIf(
                    claim.outputs[j].token > address(0)
                        ? ExecutingRecipe.balanceQuery(claim.outputs[j].token, account)
                        : ExecutingRecipe.query(claim.outputs[j].balance),
                    amount,
                    0
                );
            }
            claimCalls[i] = builder.manage(
                amount,
                claim.leaves,
                ExecutingRecipe.joinBindings(
                    ExecutingRecipe.amountBindings(claim.amountOffsets, amount),
                    ExecutingRecipe.amountBindings(claim.idOffsets, id)
                )
            );
            if (claim.maxAmount > 0) {
                builder.check(
                    OP_EQUAL, builder.binary(OP_SUB, claimable, builder.readIf(readiness, amount, claimable)), amount
                );
            }
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
                    claim.outputs[j].minimum.target != address(0)
                        ? minimums[j]
                        : claim.maxAmount > 0 && claim.outputs[j].minNumerator == claim.outputs[j].denominator
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
                if (!positiveMinimum) received = builder.binary(OP_MAX, received, delta);
            }
            if (!positiveMinimum) {
                builder.check(OP_LESS_OR_EQUAL, builder.binary(OP_MIN, amount, builder.literal(1)), received);
            }
        }
        recipe = builder.finish();
    }
}
