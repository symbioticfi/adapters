// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {
    IVaultV2,
    IMorphoMarketV1AdapterV2,
    IMorphoVaultV1Adapter
} from "../../../../interfaces/merkle-adapter/automations/liquidity/IMorphoLiquidity.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IMorpho, MarketParams, Id} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "morpho-blue/src/libraries/SharesMathLib.sol";

/// @title VaultV2LiquidityLib
/// @notice Library to compute available liquidity and max withdrawable amounts for VaultV2
/// @dev DEMO / INTEGRATION HELPER ONLY: this library is not a generic adapter router and should not be treated as a
///      canonical source of truth for all VaultV2 adapter families.
/// @dev Adapter coverage is intentionally limited to:
///      - MorphoMarketV1AdapterV2
///      - MorphoVaultV1Adapter
/// @dev Unknown adapters are conservatively ignored and contribute 0 liquidity.
/// @dev If new Morpho protocols or adapter types are added, this library must be updated to support them explicitly.
/// @dev This provides the "view" equivalent of maxWithdraw/maxRedeem that VaultV2 returns 0 for.
/// @dev Designed to help integrators who need a liquidity() view getter.
/// @dev IMPORTANT: The vault's exit() function only auto-withdraws from the single market encoded
///      in liquidityData, not from all markets in the adapter. This library mirrors that behavior.
/// @dev Adapted from morpho-snippets@2da95cc5dd5e180b745e8c2bbc047b5d97545179; see UPSTREAM.md.
library VaultV2LiquidityLib {
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    /// @notice Computes the available liquidity for instant withdrawal from a VaultV2
    /// @param vault The VaultV2 address
    /// @param ownerAssets The owner's assets; liquidity above this bound is unnecessary
    /// @return liquidity The amount of assets that can be withdrawn instantly
    function availableLiquidity(address vault, uint256 depth, uint256 ownerAssets)
        internal
        view
        returns (uint256 liquidity)
    {
        if (depth >= 4) return 0;
        address asset = IVaultV2(vault).asset();

        // Start with idle assets in the vault
        liquidity = IERC20(asset).balanceOf(vault);
        if (liquidity >= ownerAssets) return liquidity;

        // Add available liquidity from the liquidity adapter if set
        address liquidityAdapter = IVaultV2(vault).liquidityAdapter();
        if (liquidityAdapter != address(0)) {
            bytes memory liqData = IVaultV2(vault).liquidityData();
            liquidity += adapterAvailableLiquidity(liquidityAdapter, liqData, depth);
        }
    }

    /// @notice Computes the available liquidity from an adapter
    /// @dev Supports MorphoMarketV1AdapterV2 and MorphoVaultV1Adapter
    /// @dev Unknown adapter types return 0.
    /// @param adapter The adapter address
    /// @param liqData The liquidityData from the vault (encodes the single exit market)
    /// @return liquidity The amount of assets available for withdrawal
    function adapterAvailableLiquidity(address adapter, bytes memory liqData, uint256 depth)
        internal
        view
        returns (uint256 liquidity)
    {
        // Try MorphoMarketV1AdapterV2 first (direct market adapter)
        try IMorphoMarketV1AdapterV2(adapter).morpho() returns (address morpho) {
            liquidity = morphoMarketAdapterLiquidity(adapter, morpho, liqData);
        } catch {
            // Try MorphoVaultV1Adapter (V1 vault wrapper)
            try IMorphoVaultV1Adapter(adapter).morphoVaultV1() returns (address morphoVaultV1) {
                liquidity = morphoVaultV1AdapterLiquidity(adapter, morphoVaultV1, depth);
            } catch {
                // Unknown adapter type - return 0 (conservative)
                liquidity = 0;
            }
        }
    }

    /// @notice Computes available liquidity from a MorphoMarketV1AdapterV2
    /// @dev Only considers the single market encoded in liquidityData (the exit market),
    ///      not all markets the adapter has positions in.
    /// @param adapter The adapter address
    /// @param morpho The Morpho Blue address
    /// @param liqData The liquidityData encoding the single MarketParams for exit
    /// @return liquidity Available liquidity from the exit market
    function morphoMarketAdapterLiquidity(address adapter, address morpho, bytes memory liqData)
        internal
        view
        returns (uint256 liquidity)
    {
        if (liqData.length != 160) return 0;

        // Decode the single exit market from liquidityData
        MarketParams memory marketParams = abi.decode(liqData, (MarketParams));
        bytes32 marketId = Id.unwrap(marketParams.id());

        // Get adapter's supply shares in this market
        uint256 adapterSupplyShares = IMorphoMarketV1AdapterV2(adapter).supplyShares(marketId);
        return morphoMarketLiquidity(morpho, marketParams, adapterSupplyShares);
    }

    /// @notice Morpho's market liquidity calculation shared by direct accounts and Vault V2 adapters.
    /// @dev Arithmetic is unchanged from the pinned morpho-snippets implementation above.
    function morphoMarketLiquidity(address morpho, MarketParams memory marketParams, uint256 adapterSupplyShares)
        internal
        view
        returns (uint256 liquidity)
    {
        if (adapterSupplyShares == 0) return 0;

        // Get expected market balances (with accrued interest) via MorphoBalancesLib
        (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets,) =
            IMorpho(morpho).expectedMarketBalances(marketParams);

        // Adapter's supply in assets
        uint256 adapterSupplyAssets = adapterSupplyShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);

        // Market's available liquidity (supply - borrow)
        uint256 marketLiquidity = totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;

        // Cap by actual token balance held in Morpho singleton
        uint256 morphoBalance = IERC20(marketParams.loanToken).balanceOf(morpho);
        if (morphoBalance < marketLiquidity) {
            marketLiquidity = morphoBalance;
        }

        // Adapter can withdraw min(its position, market liquidity)
        liquidity = adapterSupplyAssets < marketLiquidity ? adapterSupplyAssets : marketLiquidity;
    }

    /// @notice Computes available liquidity from a MorphoVaultV1Adapter
    /// @dev The underlying vault can be either a MetaMorpho V1 or a VaultV2.
    ///      - V1: maxWithdraw works correctly (loops through markets internally).
    ///      - V2: maxWithdraw always returns 0 by design, so we compute liquidity manually.
    /// @dev When the underlying is a VaultV2, this recurses into availableLiquidity().
    ///      The integration wrapper bounds recursion to four levels and checks each nested vault's exit gates.
    /// @param adapter The adapter address
    /// @param underlyingVault The vault address wrapped by the adapter (V1 or V2)
    /// @return The available liquidity from the underlying vault
    function morphoVaultV1AdapterLiquidity(address adapter, address underlyingVault, uint256 depth)
        internal
        view
        returns (uint256)
    {
        // Detect if the underlying vault is a VaultV2 by probing a V2-specific function.
        try IVaultV2(underlyingVault).liquidityAdapter() {
            // Underlying is a VaultV2 -> maxWithdraw returns 0, so compute manually.
            return maxWithdrawView(underlyingVault, adapter, depth + 1);
        } catch {
            // Underlying is a V1 vault -> maxWithdraw loops through markets and returns correctly.
            return IERC4626(underlyingVault).maxWithdraw(adapter);
        }
    }

    /// @notice Computes the maximum amount a user can withdraw from a VaultV2
    /// @param vault The VaultV2 address
    /// @param owner The owner address
    /// @return maxAssets The maximum assets the owner can withdraw
    function maxWithdrawView(address vault, address owner, uint256 depth) internal view returns (uint256 maxAssets) {
        if (depth >= 4 || !IVaultV2(vault).canSendShares(owner) || !IVaultV2(vault).canReceiveAssets(owner)) return 0;
        uint256 shares = IVaultV2(vault).balanceOf(owner);
        if (shares == 0) return 0;

        // Convert shares to assets using the preview function
        uint256 ownerAssets = IVaultV2(vault).previewRedeem(shares);

        // Get available liquidity
        uint256 liquidity = availableLiquidity(vault, depth, ownerAssets);

        // Owner can withdraw min(their position, available liquidity)
        maxAssets = ownerAssets < liquidity ? ownerAssets : liquidity;
    }
}
