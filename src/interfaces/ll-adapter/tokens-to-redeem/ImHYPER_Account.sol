// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMidasTokenAccount} from "../midas/IMidasTokenAccount.sol";

/**
 * @title ImHYPER_Account
 * @notice Interface and deployment constants for mHYPER_Account.
 */
abstract contract ImHYPER_Account is IMidasTokenAccount {
    /* CONSTANTS */

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 6 hours;

    /**
     * @dev Mainnet usdc.
     */
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x9b5528528656DBC094765E2abB79F293c21191B9;

    /**
     * @dev Redemption vault address.
     */
    address internal constant REDEMPTION_VAULT_ADDRESS = 0x6Be2f55816efd0d91f52720f096006d63c366e98;
}
