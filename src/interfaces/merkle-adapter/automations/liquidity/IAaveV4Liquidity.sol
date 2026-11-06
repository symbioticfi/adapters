// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IAaveV4Liquidity
 * @notice Interface for scalar, asset-denominated Aave V4 withdrawal liquidity queries.
 * @dev Queries report liquidity bounds, not promises that a later transaction will succeed.
 */
interface IAaveV4Liquidity {
    /* FUNCTIONS */

    /**
     * @notice Returns the minimum of the account's supplied assets, Hub liquidity and the Spoke's added assets.
     * @dev Uses native Aave V4 share conversions. Does not check debt, health, reserve pause or Spoke status.
     * Intended for withdrawals without borrowing; the protocol enforces these checks during execution.
     * reserveId identifies the Spoke reserve, not the Hub asset. Values are underlying asset units.
     */
    function liquidity(address spoke, uint256 reserveId, address account) external view returns (uint256);

    /**
     * @notice Returns liquidity capped by needed, or zero without protocol reads when needed is zero.
     * @dev Uses the same supply, Hub and Spoke bounds as liquidity(spoke, reserveId, account).
     * Bind needed to the recipe's remaining funding shortfall to preserve source priority.
     * @param needed Maximum required amount in underlying asset units.
     */
    function liquidity(address spoke, uint256 reserveId, address account, uint256 needed)
        external
        view
        returns (uint256);
}
