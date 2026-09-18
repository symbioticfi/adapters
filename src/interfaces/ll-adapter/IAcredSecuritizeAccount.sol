// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISecuritizeAccount} from "./securitize/ISecuritizeAccount.sol";

/**
 * @title IAcredSecuritizeAccount
 * @notice Interface and deployment constants for AcredSecuritizeAccount.
 */
abstract contract IAcredSecuritizeAccount is ISecuritizeAccount {
    /* CONSTANTS */

    /**
     * @dev 2026-05-01 00:00:00 UTC, the day after the 2026 Q1 repurchase request deadline.
     */
    uint48 internal constant CUTOFF_0 = 1_777_593_600;

    /**
     * @dev 2026-08-01 00:00:00 UTC, the day after the 2026 Q2 repurchase request deadline.
     */
    uint48 internal constant CUTOFF_1 = 1_785_542_400;

    /**
     * @dev 2026-10-31 00:00:00 UTC, the day after the 2026 Q3 repurchase request deadline.
     */
    uint48 internal constant CUTOFF_2 = 1_793_404_800;

    /**
     * @dev 2027-01-30 00:00:00 UTC, the day after the 2026 Q4 repurchase request deadline.
     */
    uint48 internal constant CUTOFF_3 = 1_801_267_200;
}
