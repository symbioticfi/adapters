// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMidasTokenAccount} from "../midas/IMidasTokenAccount.sol";

/**
 * @title ImsyrupUSDp_Account
 * @notice Interface and deployment constants for msyrupUSDp_Account.
 */
abstract contract ImsyrupUSDp_Account is IMidasTokenAccount {
    /* CONSTANTS */

    /**
     * @dev Token cooldown.
     */
    uint48 internal constant TOKEN_COOLDOWN = 1 days;

    /**
     * @dev Unlike the other Midas USD vaults, this redemption vault lists only USDT as a payment
     * token, so USDC would be rejected. MidasAccount._requestRedeem falls back to
     * REDEMPTION_TOKEN when the vault has no config for the vault asset, and the USDT is
     * settled back to the vault asset through the CoW converter.
     */
    address internal constant MAINNET_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0x2fE058CcF29f123f9dd2aEC0418AA66a877d8E50;

    /**
     * @dev Redemption vault address.
     */
    address internal constant REDEMPTION_VAULT_ADDRESS = 0x71EFa7AF1686C5c04AA34a120a91cb4262679C44;
}
