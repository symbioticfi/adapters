// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMidasAccount} from "./IMidasAccount.sol";

/**
 * @title IMidasTokenAccount
 * @notice Interface for token-specific Midas liquidity lane accounts.
 */
interface IMidasTokenAccount is IMidasAccount {}
