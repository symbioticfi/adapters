// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.36;

import {AsyncRedeemAccount} from "./common/AsyncRedeemAccount.sol";

/// @title CentrifugeAccount
/// @notice Base contract for Centrifuge ERC-7575 async redeem integrations.
abstract contract CentrifugeAccount is AsyncRedeemAccount {
    /* IMMUTABLES */

    /// @notice Centrifuge ERC-7575 vault used for async redemptions.
    address public immutable ASYNC_REDEEM_VAULT;

    /* CONSTRUCTOR */

    /// @dev Creates the Centrifuge account implementation.
    constructor(
        address newOracle,
        address newFactory,
        uint48 newCooldown,
        address newTokenToRedeem,
        address newRedemptionToken,
        address newAsyncRedeemVault,
        address newCowSwapSettlement
    )
        AsyncRedeemAccount(
            newOracle, newFactory, newCooldown, newTokenToRedeem, newRedemptionToken, newCowSwapSettlement
        )
    {
        ASYNC_REDEEM_VAULT = newAsyncRedeemVault;
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Returns the configured Centrifuge ERC-7575 vault.
    function _asyncRedeemVault() internal view virtual override returns (address) {
        return ASYNC_REDEEM_VAULT;
    }
}
