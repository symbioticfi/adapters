// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IEulerHealthVault
 * @notice Read interface for an Euler EVK liability vault.
 */
interface IEulerHealthVault {
    /* FUNCTIONS */

    /**
     * @notice Returns risk-adjusted collateral and accrued debt in the vault's unit of account.
     * @param account EVC account holding debt in this vault.
     * @param liquidation True selects liquidation LTVs and prices; false selects borrowing rules.
     * @return collateralValue Risk-adjusted collateral value.
     * @return liabilityValue Current debt value.
     */
    function accountLiquidity(address account, bool liquidation)
        external
        view
        returns (uint256 collateralValue, uint256 liabilityValue);
}
