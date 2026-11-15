// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {MarketParams} from "morpho-blue/src/interfaces/IMorpho.sol";

/**
 * @title IMorphoLiquidity
 * @notice Interface for scalar, asset-denominated Morpho vault and Blue withdrawal liquidity queries.
 * @dev Queries report liquidity bounds, not promises that a later transaction will succeed.
 */
interface IMorphoLiquidity {
    /* FUNCTIONS */

    /// @notice Returns Morpho V2 vault withdrawal capacity through its currently configured liquidity adapter.
    function liquidity(address vault, address account) external view returns (uint256);

    /// @notice Returns the account's Morpho Blue supply capped by market liquidity and singleton token balance.
    /// @dev Uses Morpho's accrued market balances and downward-rounded share conversion, in loan-token units.
    function liquidity(address morpho, MarketParams calldata marketParams, address account)
        external
        view
        returns (uint256);
}

/* Native Morpho Vault V2/adapter read subsets used by the copied VaultV2LiquidityLib. */
interface IVaultV2 is IERC4626 {
    function liquidityAdapter() external view returns (address);
    function liquidityData() external view returns (bytes memory);
    function canSendShares(address account) external view returns (bool);
    function canReceiveAssets(address account) external view returns (bool);
}

interface IMorphoMarketV1AdapterV2 {
    function morpho() external view returns (address);
    function supplyShares(bytes32 id) external view returns (uint256);
}

interface IMorphoVaultV1Adapter {
    function morphoVaultV1() external view returns (address);
}
