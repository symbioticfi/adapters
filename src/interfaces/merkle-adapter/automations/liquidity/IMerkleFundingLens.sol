// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @dev Maximum number of disjoint synchronous withdrawal sources in one funding quote.
 */
uint256 constant MAX_FUNDING_SOURCES = 32;

/**
 * @title IMerkleFundingLens
 * @notice Interface for account cash and configured synchronous funding capacity.
 * @dev This is a quote helper, not an authorization check. The caller must supply reviewed,
 * disjoint sources belonging to this account and asset and executable by the selected recipe.
 * Source reads must include any recipe health floor and exclude asynchronous liquidity.
 */
interface IMerkleFundingLens {
    /* ERRORS */

    /**
     * @notice Raised when a position identity or capacity query is repeated.
     */
    error DuplicateSource();

    /**
     * @notice Raised when an account, asset or source configuration is invalid.
     */
    error InvalidSource();

    /**
     * @notice Raised when a configured capacity read fails or omits the selected word.
     */
    error SourceReadFailed();

    /* STRUCTS */

    /**
     * @notice Reviewed capacity query returning a funding-asset amount at a byte offset.
     * @param id Canonical liquidity venue/position identity; alternate queries for one source use the same id.
     * @param target Stateless liquidity helper or protocol queried by staticcall.
     * @param data Complete call data, including the account, asset and market where required.
     * @param offset Byte offset of the uint256 capacity word in the returned ABI data.
     */
    struct Source {
        bytes32 id;
        address target;
        bytes data;
        uint256 offset;
    }

    /* FUNCTIONS */

    /**
     * @notice Returns account cash plus the configured synchronous capacities, in asset base units.
     * @dev Does not include adapter cash, NAV, policy budgets or outstanding offer reservations.
     * Duplicate ids/queries are rejected; overlapping underlying liquidity must not be configured.
     * Configured failures revert instead of falling back to account cash.
     * @param account Account that owns the funding cash and positions.
     * @param asset Funding token shared by the cash and every source capacity.
     * @param sources Disjoint withdrawal-capacity queries matching the reviewed execution recipe.
     * @return assets Estimated available funding in asset base units.
     */
    function getAvailableAssets(address account, address asset, Source[] calldata sources)
        external
        view
        returns (uint256 assets);
}
