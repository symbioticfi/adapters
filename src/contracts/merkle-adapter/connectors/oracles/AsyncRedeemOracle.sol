// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Oracle} from "./Oracle.sol";

import {IAsyncRedeemOracle} from "../../../../interfaces/merkle-adapter/connectors/oracles/IAsyncRedeemOracle.sol";
import {IAsyncRedeemVault} from "../../../../interfaces/ll-adapter/IAsyncRedeemVault.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title AsyncRedeemOracle
/// @notice Oracle contract returning an ERC-7540 async redeem vault share price in `1e18` precision.
contract AsyncRedeemOracle is Oracle, IAsyncRedeemOracle {
    /* IMMUTABLES */

    /// @inheritdoc IAsyncRedeemOracle
    address public immutable ASYNC_REDEEM_VAULT;

    /// @dev Async redeem vault share unit.
    uint256 internal immutable _SHARE_UNIT;

    /// @dev Async redeem vault asset unit.
    uint256 internal immutable _ASSET_UNIT;

    /* CONSTRUCTOR */

    /// @notice Creates the async redeem vault share-price oracle.
    constructor(uint256 newMinPrice, uint256 newMaxPrice, address newTokenToRedeem, address newAsyncRedeemVault)
        Oracle(newMinPrice, newMaxPrice)
    {
        ASYNC_REDEEM_VAULT = newAsyncRedeemVault;
        _SHARE_UNIT = 10 ** IERC20Metadata(newTokenToRedeem).decimals();
        _ASSET_UNIT = 10 ** IERC20Metadata(IAsyncRedeemVault(newAsyncRedeemVault).asset()).decimals();
    }

    /* INTERNAL FUNCTIONS */

    function _getPrice() internal view override returns (uint256) {
        return IAsyncRedeemVault(ASYNC_REDEEM_VAULT).convertToAssets(_SHARE_UNIT) * 1e18 / _ASSET_UNIT;
    }
}
