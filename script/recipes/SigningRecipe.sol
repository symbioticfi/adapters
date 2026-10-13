// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {OP_LESS_OR_EQUAL, OP_SUB} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

/**
 * @title SigningRecipe
 * @notice Library for compiling oracle-priced native signing authorizations with bounded amounts and lifetime.
 * @dev Inputs are amount, minimum output, deadline and optional nonce. Only the executor receives the sign leaf role.
 * Configure the actual economic word offsets for the protocol, an oracle that rejects stale prices, and a clock
 * returning block.timestamp. Price is output raw units per input raw unit, scaled by priceDenominator.
 */
library SigningRecipe {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    error InvalidConfiguration();

    struct Config {
        address account;
        bytes signData;
        ExecutingRecipe.Read price;
        ExecutingRecipe.Read clock;
        uint256 minAmount;
        uint256 maxAmount;
        uint256 priceDenominator;
        uint256 slippageBps;
        uint256 maxDuration;
        uint256 amountOffset;
        uint256 outputOffset;
        uint256 deadlineOffset;
        // Four bytes for CoW validTo, or 32 for Liquid Lane's deadline.
        uint8 deadlineBytes;
        // Zero for no nonce input. Otherwise this word is bound to input 3.
        uint256 nonceOffset;
    }

    /**
     * @notice Compiles bounds, oracle reads and bindings, and returns the exact required sign authorization.
     * @dev All other calldata bytes, including the domain, pair, recipient, fee and hash plan, remain fixed.
     */
    function build(Config memory config)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory recipe, IMerkleAccount.Action memory authorization)
    {
        if (
            config.account == address(0) || config.price.target == address(0) || config.clock.target == address(0)
                || config.minAmount == 0 || config.minAmount > config.maxAmount || config.priceDenominator == 0
                || config.slippageBps >= 10_000 || config.maxDuration == 0
                || (config.deadlineBytes != 4 && config.deadlineBytes != 32)
                || bytes4(config.signData) != IMerkleAccount.sign.selector
        ) revert InvalidConfiguration();
        (bytes32 domain, bytes memory buffer, IMerkleAccount.Hash[] memory plan) =
            abi.decode(Bytes.slice(config.signData, 4), (bytes32, bytes, IMerkleAccount.Hash[]));
        if (keccak256(config.signData) != keccak256(abi.encodeCall(IMerkleAccount.sign, (domain, buffer, plan)))) {
            revert InvalidConfiguration();
        }
        authorization = IMerkleAccount.Action({
            target: config.account,
            value: 0,
            data: config.signData,
            dataMask: new bytes(config.signData.length),
            proof: new bytes32[](0)
        });
        uint256[] memory offsets = new uint256[](config.nonceOffset == 0 ? 3 : 4);
        offsets[0] = config.amountOffset;
        offsets[1] = config.outputOffset;
        offsets[2] = config.deadlineOffset;
        if (offsets.length == 4) offsets[3] = config.nonceOffset;
        for (uint256 i; i < offsets.length; ++i) {
            // Canonical sign calldata puts buffer contents at byte 132; no header or plan can be masked.
            if (offsets[i] < 132 || (offsets[i] - 132) % 32 > 0 || offsets[i] + 32 > 132 + buffer.length) {
                revert InvalidConfiguration();
            }
            for (uint256 j; j < i; ++j) {
                if (offsets[i] == offsets[j]) revert InvalidConfiguration();
            }
            for (uint256 j = i == 2 ? 32 - config.deadlineBytes : 0; j < 32; ++j) {
                authorization.dataMask[offsets[i] + j] = 0xff;
            }
        }

        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(16);
        uint256 amount = builder.input(0);
        uint256 output = builder.input(1);
        uint256 deadline = builder.input(2);
        builder.check(OP_LESS_OR_EQUAL, builder.literal(config.minAmount), amount);
        builder.check(OP_LESS_OR_EQUAL, amount, builder.literal(config.maxAmount));
        uint256 price = builder.read(config.price);
        uint256 quote = builder.mulDiv(amount, price, builder.literal(config.priceDenominator));
        uint256 minimum = builder.binary(
            OP_SUB, quote, builder.mulDiv(quote, builder.literal(config.slippageBps), builder.literal(10_000))
        );
        builder.check(OP_LESS_OR_EQUAL, builder.literal(1), minimum);
        builder.check(OP_LESS_OR_EQUAL, minimum, output);
        uint256 timestamp = builder.read(config.clock);
        builder.check(OP_LESS_OR_EQUAL, timestamp, deadline);
        builder.check(
            OP_LESS_OR_EQUAL, builder.binary(OP_SUB, deadline, timestamp), builder.literal(config.maxDuration)
        );
        if (config.deadlineBytes == 4) builder.check(OP_LESS_OR_EQUAL, deadline, builder.literal(type(uint32).max));
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = MerkleAdapterVerifier.leaf(authorization.target, 0, authorization.data, authorization.dataMask);
        uint256[][] memory bindings = new uint256[][](1);
        bindings[0] = new uint256[](offsets.length);
        for (uint256 i; i < offsets.length; ++i) {
            uint256 binding = ExecutingRecipe.binding(offsets[i], builder.input(i));
            uint256 j = i;
            // The interpreter requires increasing calldata offsets; keep each input attached to its word.
            for (; j > 0 && bindings[0][j - 1] > binding; --j) {
                bindings[0][j] = bindings[0][j - 1];
            }
            bindings[0][j] = binding;
        }
        builder.manage(leaves, builder.literal(1), bindings);
        return (builder.finish(), authorization);
    }
}
