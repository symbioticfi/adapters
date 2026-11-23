// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IRIS_DOMAIN_TYPEHASH, IRIS_QUOTE_TYPEHASH} from "src/interfaces/merkle-adapter/IIris.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {OP_ADD, OP_LESS_OR_EQUAL, OP_MIN, OP_SUB} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

/**
 * @title IrisSigning
 * @notice Library for compiling bounded Iris solver quotes that the account presigns for ERC-1271.
 * @dev The leaf fixes the Iris domain, Quote type hash, hash plan, solver (the account), bond model, tokens,
 * overdue terms, bond LLTV, venue and market data. Inputs are the free Quote words in calldata order:
 * borrower, receiver, collateral, debt, fixedRate, duration, bond, venueBitmap, deadline and nonce.
 * Each run raises the debt token's allowance to Iris by the bond, capped at maxPendingBond, so unfilled and
 * expired quotes share one bounded pull budget. Iris enforces deadline, nonce, venue, bond requirement and
 * borrower collateral at take. Only the executor receives the sign leaf role.
 */
library IrisSigning {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    error InvalidConfiguration();

    /* CONSTANTS */

    /// @dev sign calldata places buffer word i at 132 + 32 * i.
    uint256 internal constant QUOTE_WORDS = 20;
    uint256 internal constant DATA_HASH_WORD = 19;

    struct Config {
        address account;
        address iris;
        uint256 chainId;
        // Must return block.timestamp, such as Multicall3's getCurrentBlockTimestamp().
        ExecutingRecipe.Read clock;
        address blm;
        address collateralToken;
        address debtToken;
        uint256 overdueRate;
        uint256 overduePeriod;
        uint256 bondLltv;
        uint256 venueId;
        bytes data;
        uint256 minDebt;
        uint256 maxDebt;
        uint256 minFixedRate;
        uint256 minDuration;
        uint256 maxDuration;
        // Maximum bond per unit of debt, in WAD.
        uint256 maxBondPerDebt;
        uint256 maxLifetime;
        uint256 maxPendingBond;
    }

    /**
     * @notice Compiles the bounded quote checks and returns the sign authorization and the bond approval.
     * @return recipe Executor program.
     * @return authorization Account self-call to sign, with the free Quote words masked.
     * @return approval Debt-token approval to Iris, with the amount masked.
     */
    function build(Config memory config)
        internal
        pure
        returns (
            ExecutingRecipe.Recipe memory recipe,
            IMerkleAccount.Action memory authorization,
            IMerkleAccount.Action memory approval
        )
    {
        if (
            config.account == address(0) || config.iris == address(0) || config.chainId == 0
                || config.clock.target == address(0) || config.blm == address(0) || config.collateralToken == address(0)
                || config.debtToken == address(0) || config.minDebt == 0 || config.minDebt > config.maxDebt
                || config.minDuration > config.maxDuration || config.maxBondPerDebt == 0 || config.maxLifetime == 0
                || config.maxPendingBond == 0
        ) revert InvalidConfiguration();

        authorization = _authorization(config);
        approval = IMerkleAccount.Action({
            target: config.debtToken,
            value: 0,
            data: abi.encodeCall(IERC20.approve, (config.iris, 0)),
            dataMask: new bytes(68),
            proof: new bytes32[](0)
        });
        for (uint256 i = 36; i < 68; ++i) {
            approval.dataMask[i] = 0xff;
        }

        // Free Quote words, ascending; input i binds word freeWords[i].
        uint256[10] memory freeWords = [uint256(1), 3, 7, 8, 9, 10, 13, 15, 17, 18];
        uint256[][] memory bindings = new uint256[][](1);
        bindings[0] = new uint256[](freeWords.length);
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(24);
        for (uint256 i; i < freeWords.length; ++i) {
            uint256 offset = 132 + 32 * freeWords[i];
            for (uint256 j; j < 32; ++j) {
                authorization.dataMask[offset + j] = 0xff;
            }
            bindings[0][i] = ExecutingRecipe.binding(offset, builder.input(i));
        }

        uint256 debt = builder.input(3);
        uint256 duration = builder.input(5);
        uint256 bond = builder.input(6);
        builder.check(OP_LESS_OR_EQUAL, builder.literal(config.minDebt), debt);
        builder.check(OP_LESS_OR_EQUAL, debt, builder.literal(config.maxDebt));
        builder.check(OP_LESS_OR_EQUAL, builder.literal(config.minFixedRate), builder.input(4));
        builder.check(OP_LESS_OR_EQUAL, builder.literal(config.minDuration), duration);
        builder.check(OP_LESS_OR_EQUAL, duration, builder.literal(config.maxDuration));
        builder.check(
            OP_LESS_OR_EQUAL, bond, builder.mulDiv(debt, builder.literal(config.maxBondPerDebt), builder.literal(1e18))
        );
        // Subtraction reverts for an expired deadline.
        builder.check(
            OP_LESS_OR_EQUAL,
            builder.binary(OP_SUB, builder.input(8), builder.read(config.clock)),
            builder.literal(config.maxLifetime)
        );
        uint256 cap = builder.literal(config.maxPendingBond);
        // Capping first keeps the addition safe when a larger allowance was set outside this recipe.
        uint256 allowance = builder.read(
            ExecutingRecipe.Read({
                target: config.debtToken,
                data: abi.encodeCall(IERC20.allowance, (config.account, config.iris)),
                offset: 0
            })
        );
        uint256 pending =
            builder.binary(OP_MIN, builder.binary(OP_ADD, builder.binary(OP_MIN, allowance, cap), bond), cap);
        builder.check(OP_LESS_OR_EQUAL, bond, pending);

        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = ActionMasker.mask(authorization.target, 0, authorization.data, authorization.dataMask);
        builder.manage(builder.literal(1), leaves, bindings);
        builder.approve(
            pending,
            config.debtToken,
            config.iris,
            ActionMasker.mask(approval.target, 0, approval.data, approval.dataMask)
        );
        recipe = builder.finish();
    }

    /// @dev The buffer is the 20-word Quote struct encoding followed by the market data, which the plan hashes
    /// into word 19 before hashing the struct.
    function _authorization(Config memory config) private pure returns (IMerkleAccount.Action memory) {
        bytes memory buffer = bytes.concat(
            abi.encode(
                IRIS_QUOTE_TYPEHASH,
                address(0),
                config.account,
                address(0),
                config.blm,
                config.collateralToken,
                config.debtToken,
                uint256(0),
                uint256(0),
                uint256(0)
            ),
            abi.encode(
                uint256(0),
                config.overdueRate,
                config.overduePeriod,
                uint256(0),
                config.bondLltv,
                uint256(0),
                config.venueId,
                uint256(0),
                uint256(0),
                bytes32(0)
            ),
            config.data
        );
        IMerkleAccount.Hash[] memory plan = new IMerkleAccount.Hash[](2);
        plan[0] = IMerkleAccount.Hash({
            offset: 32 * QUOTE_WORDS, length: config.data.length, destination: 32 * DATA_HASH_WORD
        });
        plan[1] = IMerkleAccount.Hash({offset: 0, length: 32 * QUOTE_WORDS, destination: 0});
        bytes memory data = abi.encodeCall(
            IMerkleAccount.sign,
            (keccak256(abi.encode(IRIS_DOMAIN_TYPEHASH, config.chainId, config.iris)), buffer, plan)
        );
        return IMerkleAccount.Action({
            target: config.account, value: 0, data: data, dataMask: new bytes(data.length), proof: new bytes32[](0)
        });
    }
}
