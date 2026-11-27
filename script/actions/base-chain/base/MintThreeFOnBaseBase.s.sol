// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChainActionBase} from "./BaseChainActionBase.s.sol";
import {BaseSafePayloads} from "../../../base-chain/BaseSafePayloads.sol";

import {Logs} from "../../../utils/Logs.sol";

/// @title MintThreeFOnBaseBase
/// @notice Base script sending a portal message that runs the 3F mint recipe in the Base Safe.
contract MintThreeFOnBaseBaseScript is BaseChainActionBase {
    /**
     * @notice Sends the 3F mint recipe for one request to the Base Safe.
     * @dev 3F must have authorized the Safe on `request` first. The recipe reads the principal and yield from
     * `mintAuthorization(safe)` when it runs on Base, and reverts if the principal exceeds `maxAssets`. Set
     * `maxAssets` to the principal of the accepted offer. The Safe's ThreeFPolicy must have a budget for the
     * request's underlying asset.
     */
    function runBase(string memory manifest, string memory proofs, address request, uint256 maxAssets)
        public
        virtual
        returns (bytes memory data)
    {
        BaseSafePayloads.Deployment memory deployment = _deployment(manifest);
        data = _manage(deployment, proofs, _single(BaseSafePayloads.mintThreeF(deployment, request, maxAssets)));
        Logs.log(
            string.concat(
                "Mint 3F on Base\n    safe:",
                vm.toString(deployment.safe),
                "\n    request:",
                vm.toString(request),
                "\n    maxAssets:",
                vm.toString(maxAssets)
            )
        );
    }
}
