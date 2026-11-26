// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAliasActionBase} from "./BaseAliasActionBase.s.sol";
import {BaseAliasPayloads} from "../../../base-chain/BaseAliasPayloads.sol";

import {Logs} from "../../../utils/Logs.sol";

/// @title ResetThreeFApprovalFromAliasBase
/// @notice Base script sending one portal deposit in which the alias sets its USDC approval to a spender to zero.
contract ResetThreeFApprovalFromAliasBaseScript is BaseAliasActionBase {
    /**
     * @notice Sends USDC `approve(spender, 0)` from the alias.
     * @dev Uses the `resetThreeFApproval` leaf directly, so the sender needs the role of that leaf. The leaf pins the
     * amount to zero, so it can only remove an approval. Use it to recover when a mint left an approval open, for
     * example when the reset deposit of the mint failed. It does not charge the policy.
     */
    function runBase(string memory manifest, string memory proofs, address spender)
        public
        virtual
        returns (bytes memory data)
    {
        BaseAliasPayloads.Deployment memory deployment = _deployment(manifest);
        data = _manage(deployment, proofs, _single(BaseAliasPayloads.resetThreeFApproval(spender)));
        Logs.log(
            string.concat(
                "Reset a USDC approval of the Base alias\n    alias:",
                vm.toString(BaseAliasPayloads.aliasOf(deployment)),
                "\n    spender:",
                vm.toString(spender)
            )
        );
    }
}
