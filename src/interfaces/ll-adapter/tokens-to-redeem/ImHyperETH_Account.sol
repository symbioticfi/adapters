// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMidasTokenAccount} from "../midas/IMidasTokenAccount.sol";

/**
 * @title ImHyperETH_Account
 * @notice Interface and deployment constants for mHyperETH_Account.
 */
abstract contract ImHyperETH_Account is IMidasTokenAccount {
    /* CONSTANTS */

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 1 days;

    /**
     * @dev Weth.
     */
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x5a42864b14C0C8241EF5ab62Dae975b163a2E0C1;

    /**
     * @dev Redemption vault address.
     */
    address internal constant REDEMPTION_VAULT_ADDRESS = 0x15f724b35A75F0c28F352b952eA9D1b24e348c57;
}
