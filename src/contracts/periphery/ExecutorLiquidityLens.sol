// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {AaveLiquidity} from "src/contracts/periphery/liquidity/AaveLiquidity.sol";
import {EulerLiquidity} from "src/contracts/periphery/liquidity/EulerLiquidity.sol";
import {MorphoLiquidity} from "src/contracts/periphery/liquidity/MorphoLiquidity.sol";

/// @title ExecutorLiquidityLens
/// @notice Permissionless, stateless scalar liquidity queries for Executor's owner-configured funding sources.
/// @dev Each query returns underlying token units for the explicitly encoded account, never msg.sender.
/// Unsupported protocol modes return zero; failed reads revert and cannot authorize any funding call.
/// Executor still enforces the actual balance delta, current Merkle proof and role on every used source.
/// Deploy through ImmutableFactory(type(ExecutorLiquidityLens).creationCode).create("").
/// @custom:security-contact https://github.com/symbioticfi/adapters/security
contract ExecutorLiquidityLens is AaveLiquidity, MorphoLiquidity, EulerLiquidity {}
