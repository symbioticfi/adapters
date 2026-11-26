// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAliasActionBase} from "./BaseAliasActionBase.s.sol";
import {BaseAliasPayloads} from "../../../base-chain/BaseAliasPayloads.sol";

import {Logs} from "../../../utils/Logs.sol";

/// @title SetThreeFMinYieldFromAliasBase
/// @notice Base script setting the Ethereum policy's minimum yield for a Base 3F underlying.
contract SetThreeFMinYieldFromAliasBaseScript is BaseAliasActionBase {
    /**
     * @notice Sets `setMinYieldPerRequest(underlyingAsset, minimum)` on the Ethereum policy.
     * @dev Uses the `setMinYieldPerRequest` alias leaf (curator role). `minimum` is yield ÷ principal × 1e8.
     */
    function runBase(string memory manifest, string memory proofs, address underlyingAsset, uint256 minimum)
        public
        virtual
        returns (bytes memory data)
    {
        BaseAliasPayloads.Deployment memory deployment = _deployment(manifest);
        data = _manage(
            deployment, proofs, _single(BaseAliasPayloads.setMinYieldPerRequest(deployment, underlyingAsset, minimum))
        );
        Logs.log(
            string.concat(
                "Set 3F min yield from the Base alias\n    policy:",
                vm.toString(deployment.policy),
                "\n    underlyingAsset:",
                vm.toString(underlyingAsset),
                "\n    minimum:",
                vm.toString(minimum)
            )
        );
    }
}
