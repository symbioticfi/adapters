// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChainActionBase} from "./BaseChainActionBase.s.sol";
import {BaseSafePayloads} from "../../../base-chain/BaseSafePayloads.sol";

import {Logs} from "../../../utils/Logs.sol";

/// @title SetThreeFMinYieldOnBaseBase
/// @notice Base script sending a portal message that sets the Base Safe policy's minimum 3F yield.
contract SetThreeFMinYieldOnBaseBaseScript is BaseChainActionBase {
    /**
     * @notice Sends `setMinYieldPerRequest(underlyingAsset, minimum)` to the Safe's ThreeFPolicy.
     * @dev `minimum` is the yield-to-principal ratio in the policy's YIELD_PRECISION units.
     */
    function runBase(string memory manifest, string memory proofs, address underlyingAsset, uint256 minimum)
        public
        virtual
        returns (bytes memory data)
    {
        BaseSafePayloads.Deployment memory deployment = _deployment(manifest);
        data = _manage(
            deployment, proofs, _single(BaseSafePayloads.setMinYieldPerRequest(deployment, underlyingAsset, minimum))
        );
        Logs.log(
            string.concat(
                "Set 3F min yield on Base\n    policy:",
                vm.toString(deployment.policy),
                "\n    underlyingAsset:",
                vm.toString(underlyingAsset),
                "\n    minimum:",
                vm.toString(minimum)
            )
        );
    }
}
