// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAliasActionBase} from "./BaseAliasActionBase.s.sol";
import {BaseAliasPayloads} from "../../../base-chain/BaseAliasPayloads.sol";

import {Logs} from "../../../utils/Logs.sol";

/// @title BridgeUsdcFromBaseAliasBase
/// @notice Base script sending two portal deposits that burn alias USDC on Base through CCTP to the MerkleAccount.
contract BridgeUsdcFromBaseAliasBaseScript is BaseAliasActionBase {
    /**
     * @notice Sends `approve(TokenMessengerV2, amount)` and `depositForBurn` from the alias in one `manage` call.
     * @dev Uses the `approveBurn` and `bridgeToEthereum` alias leaves. Base runs them as two transactions, in order.
     * After Circle attests the burn (source domain 6), relay it on Ethereum with `ReceiveCctpMessage`.
     */
    function runBase(string memory manifest, string memory proofs, uint256 amount)
        public
        virtual
        returns (bytes memory data)
    {
        BaseAliasPayloads.Deployment memory deployment = _deployment(manifest);
        data = _manage(
            deployment,
            proofs,
            _pair(BaseAliasPayloads.approveBurn(amount), BaseAliasPayloads.bridgeToEthereum(deployment, amount))
        );
        Logs.log(
            string.concat(
                "Bridge USDC from the Base alias to Ethereum\n    account:",
                vm.toString(deployment.ethereumAccount),
                "\n    amount:",
                vm.toString(amount)
            )
        );
    }
}
