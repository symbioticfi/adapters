// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IOracleRegistry
 * @notice Interface for oracle approvals scoped to a Liquid Lane action and RWA token.
 */
interface IOracleRegistry {
    /* EVENTS */

    /**
     * @notice Emitted when an oracle approval is set, replaced, or cleared.
     * @param adapter Liquid Lane action proxy address, used as address(this) during lookup.
     * @param tokenToRedeem RWA token address.
     * @param oracle Approved oracle, or zero to prevent future additions.
     */
    event SetOracle(address indexed adapter, address indexed tokenToRedeem, address indexed oracle);

    /* FUNCTIONS */

    /**
     * @notice Returns the oracle approved for an action and RWA token.
     * @param adapter Liquid Lane action proxy address.
     * @param tokenToRedeem RWA token address.
     * @return oracle Approved oracle, or zero when no oracle is approved.
     */
    function oracles(address adapter, address tokenToRedeem) external view returns (address oracle);

    /**
     * @notice Sets, replaces, or clears an approved oracle. Only the registry owner may call this.
     * @dev Existing action snapshots remain unchanged until the token is removed and added again.
     * @param adapter Liquid Lane action proxy address.
     * @param tokenToRedeem RWA token address.
     * @param newOracle Approved oracle, or zero to prevent future additions.
     */
    function setOracle(address adapter, address tokenToRedeem, address newOracle) external;
}
