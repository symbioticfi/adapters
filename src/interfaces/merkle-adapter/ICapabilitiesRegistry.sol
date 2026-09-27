// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ICapabilitiesRegistry
 * @notice Interface for approving capability selectors for individual accounts.
 */
interface ICapabilitiesRegistry {
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
     * @param newSignatures Complete replacement list of approved function selectors.
     */
    function whitelistCapability(address account, address capability, bytes4[] calldata newSignatures) external;

    /**
     * @notice Returns every selector currently approved for an account and capability.
     * @dev Returned whole so an installing account copies one list instead of reading it index by index.
     * @param account Intended account.
     * @param capability Direct implementation address.
     * @return approvedSelectors Approved selectors, empty when not whitelisted.
     */
    function selectors(address account, address capability) external view returns (bytes4[] memory approvedSelectors);
}
