// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title ICapabilitiesRegistry
 * @notice Interface for approving capability selectors for individual accounts.
 */
interface ICapabilitiesRegistry {
    /* ERRORS */

    /**
     * @notice Raised when whitelisting selectors for an address without deployed code.
     */
    error InvalidCapabilityCode();

    /* EVENTS */

    /**
     * @notice Emitted when an account's approved selectors for a capability are replaced.
     * @param account Intended account.
     * @param capability Direct implementation address.
     * @param signatures Approved function selectors; an empty array revokes installation approval.
     */
    event WhitelistCapability(address indexed account, address indexed capability, bytes4[] signatures);

    /* FUNCTIONS */

    /**
     * @notice Replaces the selectors an account may install for a capability.
     * @dev Only the registry owner may call. An empty array unwhitelists the capability.
     * Installed routes remain unchanged until the account owner removes the capability.
     * Reinstallation uses the current list. Capability implementations must not be mutable proxies.
     * @param account Intended account.
     * @param capability Direct implementation address.
     * @param signatures Complete replacement list of approved function selectors.
     */
    function whitelistCapability(address account, address capability, bytes4[] calldata signatures) external;

    /**
     * @notice Returns a selector currently approved for an account and capability.
     * @param account Intended account.
     * @param capability Direct implementation address.
     * @param index Selector index; reverts when out of bounds.
     * @return selector Approved selector at the requested index.
     */
    function capabilitySelectors(address account, address capability, uint256 index)
        external
        view
        returns (bytes4 selector);

    /**
     * @notice Returns the number of selectors approved for an account and capability.
     * @param account Intended account.
     * @param capability Direct implementation address.
     * @return length Approved selector count, or zero when not whitelisted.
     */
    function capabilitySelectorsLength(address account, address capability) external view returns (uint256 length);
}
