// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {VaultV2LiquidityLib} from "./VaultV2LiquidityLib.sol";

import {IMorphoLiquidity} from "../../../../interfaces/merkle-adapter/automations/liquidity/IMorphoLiquidity.sol";

/// @title MorphoLiquidity
/// @notice Scalar calculations for Morpho V2 vault withdrawal liquidity.
/// @dev Native token units, current interest and virtual shares. Withdrawal follows only the configured exit adapter.
/// Stateless and permissionless: the query returns underlying token units for the explicitly
/// encoded account, never msg.sender. Failed reads revert and cannot authorize any funding call.
/// RecipeExecutor still enforces the actual balance delta, current Merkle proof and role on every
/// used source. Deploy through ImmutableFactory(type(MorphoLiquidity).creationCode).create("").
/// @custom:security-contact https://github.com/symbioticfi/adapters/security
contract MorphoLiquidity is IMorphoLiquidity {
    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IMorphoLiquidity
    function liquidity(address vault, address account) public view returns (uint256) {
        return VaultV2LiquidityLib.maxWithdrawView(vault, account, 0);
    }
}
