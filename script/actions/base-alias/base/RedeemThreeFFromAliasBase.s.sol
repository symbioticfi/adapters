// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAliasActionBase} from "./BaseAliasActionBase.s.sol";
import {BaseAliasPayloads} from "../../../base-chain/BaseAliasPayloads.sol";

import {Logs} from "../../../utils/Logs.sol";

/// @title RedeemThreeFFromAliasBase
/// @notice Base script sending a portal deposit in which the alias redeems its position in a repaid 3F request.
contract RedeemThreeFFromAliasBaseScript is BaseAliasActionBase {
    /**
     * @notice Sends `request.burnAll(alias, alias)` from the alias.
     * @dev Uses the `redeemThreeF` alias leaf. Run it when the auction is `REPAID` and `canWithdraw()` on the
     * request returns true; earlier, the Base transaction reverts and cannot be retried. Then check that
     * `balancesOf(alias)` on the request returns zero PT and zero YT.
     */
    function runBase(string memory manifest, string memory proofs, address request)
        public
        virtual
        returns (bytes memory data)
    {
        BaseAliasPayloads.Deployment memory deployment = _deployment(manifest);
        data = _manage(deployment, proofs, _single(BaseAliasPayloads.redeemThreeF(deployment, request)));
        Logs.log(
            string.concat(
                "Redeem 3F from the Base alias\n    alias:",
                vm.toString(BaseAliasPayloads.aliasOf(deployment)),
                "\n    request:",
                vm.toString(request)
            )
        );
    }
}
