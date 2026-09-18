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
     * @notice Returns Aave borrowing capacity using the adapter's current minimum for healthFactorId.
     * @dev The execution plan must bind the id to the exact approved health query for this pool and account.
     * Unset minimums return zero. Positive minima below 1e18 use the protocol solvency boundary.
     */
    function borrowCapability(address account, address pool, address asset, bytes32 healthFactorId)
        external
        view
        returns (uint256);

    /**
     * @notice Returns Aave withdrawal capacity using the adapter's current minimum for healthFactorId.
     * @dev The execution plan must bind the id to the exact approved health query for this pool and account.
     * Unset minimums return zero. Positive minima below 1e18 use the protocol solvency boundary.
     */
    function withdrawCapability(address account, address pool, address asset, bytes32 healthFactorId)
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
     * @notice Returns Morpho Blue borrow capacity using the adapter's current minimum for healthFactorId.
     * @dev The execution plan must bind this id to the exact approved health query for this market and account.
     * Unset minimums return zero. Positive minima below 1e18 use the protocol's solvency boundary.
     */
    function morphoBorrowCapability(address account, address morpho, bytes32 marketId, bytes32 healthFactorId)
        external
        view
        returns (uint256);

    /**
     * @notice Returns conservative Euler borrow capacity for an enabled sole-controller position without custom hooks.
     */
    function eulerBorrow(address vault, address account) external view returns (uint256);
}
