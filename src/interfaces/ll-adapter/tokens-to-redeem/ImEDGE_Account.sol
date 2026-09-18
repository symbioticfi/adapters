// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMidasTokenAccount} from "../midas/IMidasTokenAccount.sol";

/**
 * @title ImEDGE_Account
 * @notice Interface and deployment constants for mEDGE_Account.
 */
abstract contract ImEDGE_Account is IMidasTokenAccount {
    /* CONSTANTS */

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 1 days;

    /**
     * @dev Mainnet usdc.
     */
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0xbB51E2a15A9158EBE2b0Ceb8678511e063AB7a55;

    /**
     * @dev Redemption vault address.
     */
    address internal constant REDEMPTION_VAULT_ADDRESS = 0x9B2C5E30E3B1F6369FC746A1C1E47277396aF15D;
}
