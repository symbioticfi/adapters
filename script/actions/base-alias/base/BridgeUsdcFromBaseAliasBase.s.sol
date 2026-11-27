// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAliasActionBase} from "./BaseAliasActionBase.s.sol";
import {BaseAliasPayloads} from "../../../base-chain/BaseAliasPayloads.sol";

import {Logs} from "../../../utils/Logs.sol";

/// @title BridgeUsdcFromBaseAliasBase
/// @notice Base script sending one portal deposit that burns the manager's USDC through CCTP.
contract BridgeUsdcFromBaseAliasBaseScript is BaseAliasActionBase {
    /**
     * @notice Sends the AccessManager approval, burn and approval reset in one Base transaction.
     * @dev Uses the `bridgeToEthereum` leaf.
     * After Circle attests the burn (source domain 6), relay it on Ethereum with `ReceiveCctpMessage`.
     */
    function runBase(string memory manifest, string memory proofs, uint256 amount)
        public
        virtual
        returns (bytes memory data)
    {
        BaseAliasPayloads.Deployment memory deployment = _deployment(manifest);
        data = _manage(deployment, proofs, _single(BaseAliasPayloads.bridgeToEthereum(deployment, amount)));
        Logs.log(
            string.concat(
                "Bridge USDC from the Base manager to Ethereum\n    account:",
                vm.toString(deployment.ethereumAccount),
                "\n    amount:",
                vm.toString(amount)
            )
        );
    }
}
