// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IMorphoBlue
 * @notice Read interface for Morpho Blue positions and market configuration.
 */
interface IMorphoBlue {
    /* STRUCTS */

    /**
     * @notice Immutable market parameters, in Morpho's ABI order.
     * @param loanToken Borrowed ERC-20.
     * @param collateralToken Collateral ERC-20.
     * @param oracle Collateral-to-loan-token oracle.
     * @param irm Interest rate model, or zero for an interest-free market.
     * @param lltv Liquidation loan-to-value ratio scaled by 1e18.
     */
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    /**
     * @notice Market accounting before pending interest accrual.
     * @param totalSupplyAssets Supplied assets.
     * @param totalSupplyShares Supply shares.
     * @param totalBorrowAssets Borrowed assets.
     * @param totalBorrowShares Debt shares.
     * @param lastUpdate Last interest accrual timestamp, or zero for an uncreated market.
     * @param fee Fee on accrued interest scaled by 1e18.
     */
    struct Market {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee;
    }

    /**
     * @notice Account balances in a market.
     * @param supplyShares Supply shares.
     * @param borrowShares Debt shares.
     * @param collateral Collateral assets.
     */
    struct Position {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

    /* FUNCTIONS */

    /**
     * @notice Returns the parameters of a market.
     */
    function idToMarketParams(bytes32 id) external view returns (MarketParams memory);

    /**
     * @notice Returns the stored accounting of a market.
     */
    function market(bytes32 id) external view returns (Market memory);

    /**
     * @notice Returns an account's position in a market.
     */
    function position(bytes32 id, address account) external view returns (Position memory);
}

/**
 * @title IMorphoBlueIrm
 * @notice Read interface for a Morpho Blue interest rate model.
 */
interface IMorphoBlueIrm {
    /* FUNCTIONS */

    /**
     * @notice Returns the current borrow rate per second, scaled by 1e18.
     */
    function borrowRateView(IMorphoBlue.MarketParams calldata params, IMorphoBlue.Market calldata market)
        external
        view
        returns (uint256);
}
