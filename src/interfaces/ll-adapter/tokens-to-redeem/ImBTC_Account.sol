// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMidasTokenAccount} from "../midas/IMidasTokenAccount.sol";

/**
 * @title ImBTC_Account
 * @notice Interface and deployment constants for mBTC_Account.
 */
abstract contract ImBTC_Account is IMidasTokenAccount {
    /* CONSTANTS */

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 1 days;

    /**
     * @dev Tbtc.
     */
    address internal constant TBTC = 0x18084fbA666a33d37592fA2633fD49a74DD93a88;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x007115416AB6c266329a03B09a8aa39aC2eF7d9d;

    /**
     * @dev Redemption vault address.
     */
    address internal constant REDEMPTION_VAULT_ADDRESS = 0x30d9D1e76869516AEa980390494AaEd45C3EfC1a;
}
