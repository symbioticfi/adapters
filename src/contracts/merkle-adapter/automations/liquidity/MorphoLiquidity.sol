// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {VaultV2LiquidityLib} from "../libraries/VaultV2LiquidityLib.sol";

import {IExecutorLiquidityLens} from "src/interfaces/merkle-adapter/automations/IExecutorLiquidityLens.sol";

/// @title MorphoLiquidity
/// @notice Scalar calculations for Morpho V2 vault withdrawal liquidity.
/// @dev Native token units, current interest and virtual shares. Withdrawal follows only the configured exit adapter.
abstract contract MorphoLiquidity is IExecutorLiquidityLens {
    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IExecutorLiquidityLens
    function morphoVaultWithdraw(address vault, address account) public view returns (uint256) {
        return VaultV2LiquidityLib.maxWithdrawView(vault, account, 0);
    }
}
