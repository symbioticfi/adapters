// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IAdapter} from "src/interfaces/IAdapter.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title ExecutingRecipe
 * @notice Library for building direct adapter execution recipes with ordered vault-asset funding.
 * @dev Source reads return available amounts in raw vault-asset units. Source leaves must pin the
 * asset, adapter recipient and every non-amount parameter. Runtime supplies current proofs and the
 * exact calculated withdrawal or borrowing amount; each source's balance delta is checked onchain.
 */
library ExecutingRecipe {
    struct Read {
        address target;
        bytes data;
        uint256 offset;
    }

    struct Source {
        Read capacity;
        bytes32[] leaves;
    }

    struct Funding {
        address adapter;
        address vault;
        address asset;
        Source[] sources;
    }

    struct Builder {
        IRecipeExecutor.Step[] recipe;
        uint256 length;
    }

    // Result indices initialized by start, not runtime amounts.
    uint256 internal constant ZERO = 0;
    uint256 internal constant ONE = 1;

    function start(uint256 capacity) internal pure returns (Builder memory builder) {
        builder.recipe = new IRecipeExecutor.Step[](capacity);
        literal(builder, 0);
        literal(builder, 1);
    }

    function literal(Builder memory builder, uint256 value) internal pure returns (uint256) {
        return _append(builder, IRecipeExecutor.Step(IRecipeExecutor.Operation.Constant, value, 0, 0, ""));
    }

    function input(Builder memory builder, uint256 index) internal pure returns (uint256) {
        return _append(builder, IRecipeExecutor.Step(IRecipeExecutor.Operation.Input, index, 0, 0, ""));
    }

    function read(Builder memory builder, Read memory query) internal pure returns (uint256) {
        return _append(
            builder,
            IRecipeExecutor.Step(
                IRecipeExecutor.Operation.Read, query.offset, 0, 0, abi.encode(query.target, query.data)
            )
        );
    }

    function balance(Builder memory builder, address token, address account) internal pure returns (uint256) {
        return read(builder, Read(token, abi.encodeCall(IERC20.balanceOf, (account)), 0));
    }

    function binary(Builder memory builder, IRecipeExecutor.Operation operation, uint256 a, uint256 b)
        internal
        pure
        returns (uint256)
    {
        return _append(builder, IRecipeExecutor.Step(operation, a, b, 0, ""));
    }

    function mulDiv(Builder memory builder, uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return _append(builder, IRecipeExecutor.Step(IRecipeExecutor.Operation.MulDiv, a, b, c, ""));
    }

    function manage(Builder memory builder, bytes32[] memory leaves, uint256 guard) internal pure returns (uint256) {
        return _append(builder, IRecipeExecutor.Step(IRecipeExecutor.Operation.Manage, guard, 0, 0, abi.encode(leaves)));
    }

    function approve(Builder memory builder, address token, address spender, bytes32 leaf, uint256 amount)
        internal
        pure
        returns (uint256)
    {
        return _append(
            builder,
            IRecipeExecutor.Step(IRecipeExecutor.Operation.Approve, amount, 0, 0, abi.encode(token, spender, leaf))
        );
    }

    /**
     * @notice Uses idle funds excluding reservations, then draws the exact shortfall from sources in order.
     * @dev Capacity reads must remain callable even when their source is not needed. A reverting source
     * aborts the transaction; this recipe does not catch failures and advance to a later source.
     */
    function fund(Builder memory builder, Funding memory funding, uint256 amount)
        internal
        pure
        returns (uint256[] memory sourceCalls, uint256[] memory sourceAmounts, uint256 finalBalance)
    {
        binary(
            builder,
            IRecipeExecutor.Operation.Equal,
            read(builder, Read(funding.adapter, abi.encodeCall(IAdapter.vault, ()), 0)),
            literal(builder, uint256(uint160(funding.vault)))
        );
        binary(
            builder,
            IRecipeExecutor.Operation.Equal,
            read(builder, Read(funding.vault, abi.encodeCall(IERC4626.asset, ()), 0)),
            literal(builder, uint256(uint160(funding.asset)))
        );
        sourceCalls = new uint256[](funding.sources.length);
        sourceAmounts = new uint256[](funding.sources.length);
        for (uint256 i; i < funding.sources.length; ++i) {
            uint256 beforeCash = balance(builder, funding.asset, funding.adapter);
            {
                uint256 target = binary(
                    builder,
                    IRecipeExecutor.Operation.Add,
                    amount,
                    read(builder, Read(funding.adapter, abi.encodeCall(IMerkleAdapter.reservedAssets, ()), 0))
                );
                uint256 shortfall = binary(
                    builder,
                    IRecipeExecutor.Operation.Subtract,
                    target,
                    binary(builder, IRecipeExecutor.Operation.Minimum, target, beforeCash)
                );
                sourceAmounts[i] = binary(
                    builder, IRecipeExecutor.Operation.Minimum, shortfall, read(builder, funding.sources[i].capacity)
                );
            }
            sourceCalls[i] = manage(builder, funding.sources[i].leaves, sourceAmounts[i]);
            binary(
                builder,
                IRecipeExecutor.Operation.Equal,
                binary(
                    builder,
                    IRecipeExecutor.Operation.Subtract,
                    balance(builder, funding.asset, funding.adapter),
                    beforeCash
                ),
                sourceAmounts[i]
            );
        }
        finalBalance = balance(builder, funding.asset, funding.adapter);
        binary(
            builder,
            IRecipeExecutor.Operation.LessOrEqual,
            binary(
                builder,
                IRecipeExecutor.Operation.Add,
                amount,
                read(builder, Read(funding.adapter, abi.encodeCall(IMerkleAdapter.reservedAssets, ()), 0))
            ),
            finalBalance
        );
    }

    function checkReserves(Builder memory builder, Funding memory funding) internal pure {
        binary(
            builder,
            IRecipeExecutor.Operation.LessOrEqual,
            read(builder, Read(funding.adapter, abi.encodeCall(IMerkleAdapter.reservedAssets, ()), 0)),
            balance(builder, funding.asset, funding.adapter)
        );
    }

    function finish(Builder memory builder) internal pure returns (IRecipeExecutor.Step[] memory recipe) {
        recipe = builder.recipe;
        uint256 length = builder.length;
        // Only unused capacity is removed; every retained instruction is initialized.
        assembly ("memory-safe") {
            mstore(recipe, length)
        }
    }

    function _append(Builder memory builder, IRecipeExecutor.Step memory step) private pure returns (uint256 index) {
        index = builder.length++;
        builder.recipe[index] = step;
    }
}
