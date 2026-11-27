// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAliasActionBase} from "./BaseAliasActionBase.s.sol";
import {BaseAliasPayloads} from "../../../base-chain/BaseAliasPayloads.sol";

import {Logs} from "../../../utils/Logs.sol";

/// @title SetThreeFMaxAssetsFromAliasBase
/// @notice Base script setting the Base policy's USDC budget for a Base 3F underlying.
contract SetThreeFMaxAssetsFromAliasBaseScript is BaseAliasActionBase {
    /**
     * @notice Sets `setMaxAssetsPerDuration(USDC, underlyingAsset, maxAssets, duration)` on the Base policy through the manager.
     * @dev Uses the `setMaxAssetsPerDuration` alias leaf (curator role). The policy rejects dispatches with no configured budget.
     */
    function runBase(
        string memory manifest,
        string memory proofs,
        address underlyingAsset,
        uint256 maxAssets,
        uint48 duration
    ) public virtual returns (bytes memory data) {
        BaseAliasPayloads.Deployment memory deployment = _deployment(manifest);
        data = _manage(
            deployment,
            proofs,
            _single(BaseAliasPayloads.setMaxAssetsPerDuration(deployment, underlyingAsset, maxAssets, duration))
        );
        Logs.log(
            string.concat(
                "Set 3F max assets on Base\n    policy:",
                vm.toString(deployment.policy),
                "\n    underlyingAsset:",
                vm.toString(underlyingAsset),
                "\n    maxAssets:",
                vm.toString(maxAssets),
                "\n    duration:",
                vm.toString(uint256(duration))
            )
        );
    }
}
