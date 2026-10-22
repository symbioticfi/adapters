// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ExecutingRecipe} from "./ExecutingRecipe.sol";

import {
    OP_EQUAL,
    OP_LESS_OR_EQUAL,
    OP_MIN,
    OP_SATURATING_SUB,
    OP_SUB
} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title SynchronousVaultRecipe
 * @notice Runtime-sized deposits and withdrawals for reviewed synchronous ERC-4626 venues.
 * @dev Admission and ownership are supplied by the native integration profile. The leaves must pin
 * the same vault, asset, account and receiver; only the assets word at calldata offset 4 may vary.
 * Queued exits, credit accounts and vaults with reverting preview methods need their native recipes.
 */
library SynchronousVaultRecipe {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    error InvalidConfiguration();

    struct Config {
        address account;
        address asset;
        address vault;
        bytes32 approvalLeaf;
        bytes32 depositLeaf;
        bytes32 withdrawLeaf;
    }

    /**
     * @notice Deposits the smallest of live wallet funds, maxDeposit and a policy cap.
     * @dev Share output is checked against the native pre-call preview and a basis-point slippage policy.
     */
    function deposit(Config memory config, uint256 maxAssets, uint256 slippageBps)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory recipe)
    {
        if (config.approvalLeaf == bytes32(0) || config.depositLeaf == bytes32(0)) revert InvalidConfiguration();
        ExecutingRecipe.Builder memory builder = _start(config, slippageBps);
        uint256 cash = builder.balance(config.asset, config.account);
        uint256 shares = builder.balance(config.vault, config.account);
        uint256 assets = builder.binary(
            OP_MIN,
            builder.binary(OP_MIN, cash, builder.literal(maxAssets)),
            builder.read(
                ExecutingRecipe.Read({
                    target: config.vault, data: abi.encodeCall(IERC4626.maxDeposit, (config.account)), offset: 0
                })
            )
        );
        uint256 minimum = builder.mulDiv(
            _preview(builder, config.vault, abi.encodeCall(IERC4626.previewDeposit, (0)), assets),
            builder.literal(10_000 - slippageBps),
            builder.literal(10_000)
        );
        builder.approve(assets, config.asset, config.vault, config.approvalLeaf);
        _manage(builder, assets, config.depositLeaf);
        builder.check(OP_EQUAL, builder.binary(OP_SUB, cash, builder.balance(config.asset, config.account)), assets);
        uint256 received = builder.binary(OP_SUB, builder.balance(config.vault, config.account), shares);
        builder.check(OP_LESS_OR_EQUAL, minimum, received);
        builder.check(OP_LESS_OR_EQUAL, builder.binary(OP_MIN, assets, builder.literal(1)), received);
        builder.clearApproval(config.asset, config.vault, config.approvalLeaf);
        recipe = builder.finish();
    }

    /**
     * @notice Withdraws only the live shortfall, capped by maxWithdraw, without borrowing or repaying.
     * @dev requiredIdle reads the complete demand at execution; existing free funds reduce it first.
     */
    function withdraw(Config memory config, ExecutingRecipe.Read memory requiredIdle, uint256 slippageBps)
        internal
        pure
        returns (ExecutingRecipe.Recipe memory recipe)
    {
        if (config.withdrawLeaf == bytes32(0) || requiredIdle.target == address(0)) revert InvalidConfiguration();
        ExecutingRecipe.Builder memory builder = _start(config, slippageBps);
        uint256 cash = builder.balance(config.asset, config.account);
        uint256 shares = builder.balance(config.vault, config.account);
        uint256 assets = builder.binary(
            OP_MIN,
            builder.binary(OP_SATURATING_SUB, builder.read(requiredIdle), cash),
            builder.read(
                ExecutingRecipe.Read({
                    target: config.vault, data: abi.encodeCall(IERC4626.maxWithdraw, (config.account)), offset: 0
                })
            )
        );
        uint256 maximum = builder.mulDiv(
            _preview(builder, config.vault, abi.encodeCall(IERC4626.previewWithdraw, (0)), assets),
            builder.literal(10_000 + slippageBps),
            builder.literal(10_000)
        );
        _manage(builder, assets, config.withdrawLeaf);
        builder.check(OP_EQUAL, builder.binary(OP_SUB, builder.balance(config.asset, config.account), cash), assets);
        builder.check(
            OP_LESS_OR_EQUAL, builder.binary(OP_SUB, shares, builder.balance(config.vault, config.account)), maximum
        );
        recipe = builder.finish();
    }

    function _start(Config memory config, uint256 slippageBps)
        private
        pure
        returns (ExecutingRecipe.Builder memory builder)
    {
        if (
            config.account == address(0) || config.asset == address(0) || config.vault == address(0)
                || config.asset == config.vault || slippageBps > 10_000
        ) revert InvalidConfiguration();
        builder = ExecutingRecipe.start(24);
        builder.check(
            OP_EQUAL,
            builder.read(
                ExecutingRecipe.Read({target: config.vault, data: abi.encodeCall(IERC4626.asset, ()), offset: 0})
            ),
            builder.literal(uint160(config.asset))
        );
    }

    function _preview(ExecutingRecipe.Builder memory builder, address vault, bytes memory data, uint256 assets)
        private
        pure
        returns (uint256)
    {
        uint256[] memory offsets = new uint256[](1);
        offsets[0] = 4;
        return builder.readQuery(
            ExecutingRecipe.bindQuery(
                ExecutingRecipe.query(ExecutingRecipe.Read({target: vault, data: data, offset: 0})), offsets, assets
            )
        );
    }

    function _manage(ExecutingRecipe.Builder memory builder, uint256 assets, bytes32 leaf) private pure {
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = leaf;
        uint256[][] memory bindings = new uint256[][](1);
        bindings[0] = new uint256[](1);
        bindings[0][0] = ExecutingRecipe.binding(4, assets);
        builder.manage(assets, leaves, bindings);
    }
}
