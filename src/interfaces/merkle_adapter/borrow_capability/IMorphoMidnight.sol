// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IMorphoMidnight
 * @notice Read interface for Morpho Midnight borrowing positions.
 */
interface IMorphoMidnight {
    /* STRUCTS */

    /**
     * @notice Immutable risk parameters for one collateral.
     * @param token Collateral ERC-20.
     * @param lltv Liquidation loan-to-value ratio scaled by 1e18.
     * @param liquidationCursor Liquidation incentive parameter scaled by 1e18.
     * @param oracle Collateral-to-loan-token oracle.
     */
    struct CollateralParams {
        address token;
        uint256 lltv;
        uint256 liquidationCursor;
        address oracle;
    }

    /**
     * @notice Immutable Midnight market parameters, in the protocol's ABI order.
     * @param chainId Chain on which the market was created.
     * @param midnight Midnight contract.
     * @param loanToken Borrowed ERC-20.
     * @param collateralParams Accepted collateral parameters.
     * @param maturity Debt maturity timestamp.
     * @param rcfThreshold Recovery close factor threshold.
     * @param enterGate Optional gate for increasing credit or debt.
     * @param liquidatorGate Optional gate for liquidators.
     */
    struct Market {
        uint256 chainId;
        address midnight;
        address loanToken;
        CollateralParams[] collateralParams;
        uint256 maturity;
        uint256 rcfThreshold;
        address enterGate;
        address liquidatorGate;
    }

    /* FUNCTIONS */

    /**
     * @notice Returns canonical market parameters; reverts for an untouched market.
     */
    function toMarket(bytes32 id) external view returns (Market memory);

    /**
     * @notice Returns the account's face-value debt in loan-token units.
     */
    function debt(bytes32 id, address account) external view returns (uint128);

    /**
     * @notice Returns the bitmap of activated collateral indices.
     */
    function collateralBitmap(bytes32 id, address account) external view returns (uint128);

    /**
     * @notice Returns the account's collateral balance at the supplied index.
     */
    function collateral(bytes32 id, address account, uint256 index) external view returns (uint128);
}
