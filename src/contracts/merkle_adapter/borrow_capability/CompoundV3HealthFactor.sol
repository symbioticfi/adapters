// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {
    ICompoundV3HealthFactor
} from "../../../interfaces/merkle_adapter/borrow_capability/ICompoundV3HealthFactor.sol";
import {ICompoundV3} from "../../../interfaces/merkle_adapter/borrow_capability/ICompoundV3.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CompoundV3HealthFactor
/// @notice Contract for querying liquidation health in the Compound III market.
contract CompoundV3HealthFactor is ICompoundV3HealthFactor {
    using Math for uint256;

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ICompoundV3HealthFactor
    function getHealthFactor(address comet, address account) public view returns (uint256 healthFactor) {
        uint256 debt = ICompoundV3(comet).borrowBalanceOf(account);
        if (debt == 0) return type(uint256).max;

        debt = debt.mulDiv(
            ICompoundV3(comet).getPrice(ICompoundV3(comet).baseTokenPriceFeed()), ICompoundV3(comet).baseScale()
        );
        if (debt == 0) return type(uint256).max;

        uint256 capacity;
        uint256 numAssets = ICompoundV3(comet).numAssets();
        for (uint8 i; i < numAssets; ++i) {
            ICompoundV3.AssetInfo memory asset = ICompoundV3(comet).getAssetInfo(i);
            uint256 balance = ICompoundV3(comet).collateralBalanceOf(account, asset.asset);
            if (balance != 0) {
                capacity += balance.mulDiv(ICompoundV3(comet).getPrice(asset.priceFeed), asset.scale)
                    .mulDiv(asset.liquidateCollateralFactor, 1e18);
            }
        }
        return capacity.mulDiv(1e18, debt);
    }
}
