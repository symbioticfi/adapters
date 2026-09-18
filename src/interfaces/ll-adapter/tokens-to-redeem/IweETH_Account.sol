// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IEtherFiAccount} from "../etherfi/IEtherFiAccount.sol";

/**
 * @title IweETH_Account
 * @notice Interface and deployment constants for weETH_Account.
 */
abstract contract IweETH_Account is IEtherFiAccount {
    /* CONSTANTS */

    /**
     * @dev Eeth address.
     */
    address internal constant EETH_ADDRESS = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;

    /**
     * @dev Weth address.
     */
    address internal constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /**
     * @dev Token address.
     */
    address internal constant TOKEN_ADDRESS = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;

    /**
     * @dev Liquidity pool address.
     */
    address internal constant LIQUIDITY_POOL_ADDRESS = 0x308861A430be4cce5502d0A12724771Fc6DaF216;

    /**
     * @dev Redemption manager address.
     */
    address internal constant REDEMPTION_MANAGER_ADDRESS = 0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0;

    /**
     * @dev Withdraw request nft address.
     */
    address internal constant WITHDRAW_REQUEST_NFT_ADDRESS = 0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c;
}
