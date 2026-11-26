// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChainActionBase} from "./BaseChainActionBase.s.sol";
import {BaseSafePayloads} from "../../../base-chain/BaseSafePayloads.sol";

import {Logs} from "../../../utils/Logs.sol";

/// @title SetThreeFMaxAssetsOnBaseBase
/// @notice Base script sending a portal message that sets the Base Safe policy's USDC budget for a 3F underlying.
contract SetThreeFMaxAssetsOnBaseBaseScript is BaseChainActionBase {
    /**
     * @notice Sends `setMaxAssetsPerDuration(USDC, underlyingAsset, maxAssets, duration)` to the Safe's ThreeFPolicy.
     * @dev The policy rejects 3F mints until a budget exists for the request's underlying asset.
     */
    function runBase(
        string memory manifest,
        string memory proofs,
        address underlyingAsset,
        uint256 maxAssets,
        uint48 duration
    ) public virtual returns (bytes memory data) {
        BaseSafePayloads.Deployment memory deployment = _deployment(manifest);
        data = _manage(
            deployment,
            proofs,
            _single(BaseSafePayloads.setMaxAssetsPerDuration(deployment, underlyingAsset, maxAssets, duration))
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
