// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IOracleRegistry
 * @notice Interface for oracle approvals scoped to a Liquid Lane connector and RWA token.
 */
interface IOracleRegistry {
    /* EVENTS */

    /**
     * @notice Emitted when an oracle approval is set, replaced, or cleared.
     * @param connector Liquid Lane connector proxy address, used as address(this) during lookup.
     * @param tokenToRedeem RWA token address.
     * @param oracle Approved oracle, or zero to prevent future additions.
     */
    event SetOracle(address indexed connector, address indexed tokenToRedeem, address indexed oracle);

    /* FUNCTIONS */

    /**
     * @notice Returns the oracle approved for a connector and RWA token.
     * @param connector Liquid Lane connector proxy address.
     * @param tokenToRedeem RWA token address.
     * @return oracle Approved oracle, or zero when no oracle is approved.
     */
    function oracles(address connector, address tokenToRedeem) external view returns (address oracle);

    /**
     * @notice Sets, replaces, or clears an approved oracle. Only the registry owner may call this.
     * @dev Existing connector snapshots remain unchanged until the token is removed and added again.
     * @param connector Liquid Lane connector proxy address.
     * @param tokenToRedeem RWA token address.
     * @param newOracle Approved oracle, or zero to prevent future additions.
     */
    function setOracle(address connector, address tokenToRedeem, address newOracle) external;
}
