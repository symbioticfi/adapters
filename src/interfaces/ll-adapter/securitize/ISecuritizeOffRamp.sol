// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ISecuritizeLiquidityProvider
 * @notice Interface for minimal interface for a Securitize off-ramp liquidity provider.
 */
interface ISecuritizeLiquidityProvider {
    /* FUNCTIONS */

    /**
     * @notice Returns the token paid by the liquidity provider.
     * @return token The liquidity-token address.
     */
    function liquidityToken() external view returns (address token);
}

/**
 * @title ISecuritizeOffRamp
 * @notice Interface for minimal interface for an atomic Securitize token off-ramp.
 */
interface ISecuritizeOffRamp {
    /* FUNCTIONS */

    /**
     * @notice Returns the token accepted for redemption.
     * @return asset The token-to-redeem address.
     */
    function assetAddress() external view returns (address asset);

    /**
     * @notice Returns the active liquidity provider.
     * @return provider The liquidity-provider address.
     */
    function liquidityProvider() external view returns (address provider);

    /**
     * @notice Returns the post-fee liquidity-token output for an input amount.
     * @param assetAmount The token-to-redeem input amount.
     * @return outputAmount The quoted liquidity-token output amount.
     */
    function calculateLiquidityTokenAmount(uint256 assetAmount) external view returns (uint256 outputAmount);

    /**
     * @notice Atomically redeems tokens for at least the requested output.
     * @param assetAmount The token-to-redeem input amount.
     * @param minOutputAmount The minimum accepted liquidity-token output.
     */
    function redeem(uint256 assetAmount, uint256 minOutputAmount) external;
}
