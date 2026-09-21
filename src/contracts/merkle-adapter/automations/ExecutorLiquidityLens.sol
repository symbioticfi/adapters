// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {AaveV3Liquidity} from "src/contracts/merkle-adapter/automations/liquidity/AaveV3Liquidity.sol";
import {AaveV4Liquidity} from "src/contracts/merkle-adapter/automations/liquidity/AaveV4Liquidity.sol";
import {MorphoLiquidity} from "src/contracts/merkle-adapter/automations/liquidity/MorphoLiquidity.sol";

/// @title ExecutorLiquidityLens
/// @notice Permissionless, stateless withdrawal liquidity queries for recipe funding sources.
/// @dev Each query returns underlying token units for the explicitly encoded account, never msg.sender.
/// Each query's interface documents its limits; failed reads revert and cannot authorize any funding call.
/// RecipeExecutor still enforces the actual balance delta, current Merkle proof and role on every used source.
/// Deploy through ImmutableFactory(type(ExecutorLiquidityLens).creationCode).create("").
/// @custom:security-contact https://github.com/symbioticfi/adapters/security
contract ExecutorLiquidityLens is AaveV3Liquidity, AaveV4Liquidity, MorphoLiquidity {}
