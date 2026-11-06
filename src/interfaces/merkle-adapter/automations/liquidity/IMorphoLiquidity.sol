// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IMorphoLiquidity
 * @notice Interface for scalar, asset-denominated Morpho V2 vault withdrawal liquidity queries.
 * @dev Queries report liquidity bounds, not promises that a later transaction will succeed.
 */
interface IMorphoLiquidity {
    /* FUNCTIONS */

    /// @notice Returns Morpho V2 vault withdrawal capacity through its currently configured liquidity adapter.
    function liquidity(address vault, address account) external view returns (uint256);

    /**
     * @notice Returns liquidity capped by needed, or zero without protocol reads when needed is zero.
     * @dev Uses the same exit gates, share valuation and adapter bounds as liquidity(vault, account).
     * Bind needed to the recipe's remaining funding shortfall to preserve source priority.
     * @param needed Maximum required amount in underlying asset units.
     */
    function liquidity(address vault, address account, uint256 needed) external view returns (uint256);
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
