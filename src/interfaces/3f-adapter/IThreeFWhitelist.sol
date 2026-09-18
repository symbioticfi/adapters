// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IThreeFWhitelist
 * @notice Interface for minimal 3F request whitelist interface.
 */
interface IThreeFWhitelist {
    /* STRUCTS */

    /**
     * @notice Request whitelist status.
     */
    enum WhitelistStatus {
        NotWhitelisted,
        Whitelisted,
        PausedNotWhitelisted,
        PausedWhitelisted
    }

    /* FUNCTIONS */

    /**
     * @notice Returns request whitelist status.
     * @param account Account to query.
     * @return status Whitelist status.
     */
    function isWhitelisted(address account) external view returns (WhitelistStatus status);
}
