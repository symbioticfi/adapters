// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.36;

import {Account} from "./Account.sol";

import {ICooldownAccount} from "../../../interfaces/ll-adapter/ICooldownAccount.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title CooldownAccount
/// @notice Base contract with cooldown-gated request submission.
abstract contract CooldownAccount is Account, ICooldownAccount {
    /* IMMUTABLES */

    /// @inheritdoc ICooldownAccount
    uint48 public immutable COOLDOWN;

    /* STATE VARIABLES */

    /// @inheritdoc ICooldownAccount
    uint48 public lastRequestTimestamp;

    /// @dev Reserved storage gap for future upgrades.
    uint256[50] private __gap;

    /* CONSTRUCTOR */

    /// @dev Creates the cooldown account implementation.
    constructor(
        address newOracle,
        address newFactory,
        uint48 newCooldown,
        address newTokenToRedeem,
        address newCowSwapSettlement
    ) Account(newOracle, newFactory, newTokenToRedeem, newCowSwapSettlement) {
        COOLDOWN = newCooldown;
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Finalizes existing requests and submits a new request when cooldown permits.
    function _sync() internal virtual override {
        _finalizeRequests();

        if (
            (owner() == msg.sender || lastRequestTimestamp == 0 || block.timestamp >= lastRequestTimestamp + COOLDOWN)
                && IERC20(TOKEN_TO_REDEEM).balanceOf(address(this)) > 0
        ) {
            if (_requestRedeem()) {
                lastRequestTimestamp = uint48(block.timestamp);
            }
        }
    }

    /// @dev Finalizes or clears completed requests.
    function _finalizeRequests() internal virtual;

    /// @dev Submits a redemption request. Returns whether a new request was created.
    function _requestRedeem() internal virtual returns (bool);
}
