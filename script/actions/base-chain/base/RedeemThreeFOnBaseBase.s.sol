// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChainActionBase} from "./BaseChainActionBase.s.sol";
import {BaseSafePayloads} from "../../../base-chain/BaseSafePayloads.sol";

import {Logs} from "../../../utils/Logs.sol";

/// @title RedeemThreeFOnBaseBase
/// @notice Base script sending a portal message that redeems the Base Safe's position in a repaid 3F request.
contract RedeemThreeFOnBaseBaseScript is BaseChainActionBase {
    /**
     * @notice Sends the redeem recipe for `request` to the Base Safe, which calls `burnAll(safe, safe)` on it.
     * @dev Run it when `canWithdraw()` on the request returns true. Earlier, the recipe reverts on Base. The
     * recipe also reverts for an address that 3F's RequestFactory does not know.
     */
    function runBase(string memory manifest, string memory proofs, address request)
        public
        virtual
        returns (bytes memory data)
    {
        BaseSafePayloads.Deployment memory deployment = _deployment(manifest);
        data = _manage(deployment, proofs, _single(BaseSafePayloads.redeemThreeF(deployment, request)));
        Logs.log(
            string.concat(
                "Redeem 3F on Base\n    safe:", vm.toString(deployment.safe), "\n    request:", vm.toString(request)
            )
        );
    }
}
