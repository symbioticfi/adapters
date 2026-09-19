// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IExecutorLiquidityLens
 * @notice Interface for scalar, asset-denominated liquidity queries for Executor.Action.
 * @dev Queries are conservative capacities, not promises that a later transaction will succeed.
 */
interface IExecutorLiquidityLens {
    /* FUNCTIONS */

    /**
     * @notice Returns Aave withdrawal capacity preserving protocol solvency at a minimum health factor of 1e18.
     * @dev Unsupported eMode, isolation and siloed positions return zero. Values are underlying asset units.
     */
    function aaveWithdraw(address pool, address asset, address account) external view returns (uint256);

    /**
     * @notice Returns Aave borrowing capacity at the supplied 1e18-scaled minimum health factor.
     */
    function aaveBorrow(address pool, address asset, address account, uint256 minHealthFactor)
        external
        view
        returns (uint256);

    /**
     * @notice Returns Aave withdrawal capacity using the Merkle leaf's literal minimum health factor.
     * @dev Use the same literal floor as the accepted guarded call. Minima below 1e18 use protocol solvency.
     */
    function aaveWithdrawGuarded(address pool, address asset, address account, uint256 minHealthFactor)
        external
        view
        returns (uint256);

    /**
     * @notice Returns Morpho V2 vault withdrawal capacity through its currently configured liquidity adapter.
     */
    function morphoVaultWithdraw(address vault, address account) external view returns (uint256);

    /**
     * @notice Returns Morpho Blue borrow capacity in loan-token units at the protocol liquidation threshold.
     */
    function morphoBorrow(address morpho, bytes32 marketId, address account) external view returns (uint256);

    /**
     * @notice Returns Morpho Blue borrow capacity using the Merkle leaf's literal minimum health factor.
     * @dev Use the same literal floor as the accepted guarded call. Minima below 1e18 use protocol solvency.
     */
    function morphoBorrowGuarded(address morpho, bytes32 marketId, address account, uint256 minHealthFactor)
        external
        view
        returns (uint256);

    /**
     * @notice Returns conservative Euler borrow capacity for an enabled sole-controller position without custom hooks.
     */
    function eulerBorrow(address vault, address account) external view returns (uint256);
}
