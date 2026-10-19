// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {SettlementAccount, SettlementSubAccount} from "./common/SettlementAccount.sol";

import {ISuperstateAccount} from "../../interfaces/ll-adapter/superstate/ISuperstateAccount.sol";
import {ISuperstateToken} from "../../interfaces/ll-adapter/superstate/ISuperstateToken.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SuperstateAccount
/// @notice Account contract for Superstate off-chain settlement redemptions.
contract SuperstateAccount is SettlementAccount, ISuperstateAccount {
    /* CONSTRUCTOR */

    /// @notice Creates the Superstate account implementation.
    constructor(
        address newOracle,
        address newFactory,
        uint48 newCooldown,
        address newTokenToRedeem,
        uint48 newSettlementDuration,
        address newCowSwapSettlement
    )
        SettlementAccount(
            newOracle, newFactory, newCooldown, newTokenToRedeem, 0, newSettlementDuration, newCowSwapSettlement
        )
    {}

    /* INTERNAL FUNCTIONS */

    /// @dev Deploys a Superstate request-holder subaccount.
    function _createSubAccount() internal override returns (address subAccount) {
        return address(new SuperstateSubAccount(_asset, address(this), TOKEN_TO_REDEEM));
    }
}

/// @title SuperstateSubAccount
/// @notice Subaccount contract for one Superstate off-chain redemption.
contract SuperstateSubAccount is SettlementSubAccount {
    /* CONSTRUCTOR */

    /// @notice Creates the Superstate request-holder subaccount.
    constructor(address newAsset, address newAccount, address newTokenToRedeem)
        SettlementSubAccount(newAsset, newAccount, newTokenToRedeem)
    {}

    /* INTERNAL FUNCTIONS */

    /// @dev Burns held Superstate tokens for off-chain settlement.
    function _executeRedemption() internal override {
        ISuperstateToken(_TOKEN_TO_REDEEM).offchainRedeem(IERC20(_TOKEN_TO_REDEEM).balanceOf(address(this)));
    }
}
