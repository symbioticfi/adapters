// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChainActionBase} from "./BaseChainActionBase.s.sol";
import {BaseSafePayloads} from "../../../base-chain/BaseSafePayloads.sol";

import {Logs} from "../../../utils/Logs.sol";

/// @title BridgeUsdcToEthereumBase
/// @notice Base script sending a portal message that burns Base Safe USDC through CCTP to the Ethereum MerkleAccount.
contract BridgeUsdcToEthereumBaseScript is BaseChainActionBase {
    /**
     * @notice Sends the `bridgeToEthereum` recipe to the Base Safe.
     * @dev The Safe approves and burns `amount` USDC once the deposit lands on Base. After Circle attests the burn,
     * relay it on Ethereum with `ReceiveCctpMessage`.
     */
    function runBase(string memory manifest, string memory proofs, uint256 amount)
        public
        virtual
        returns (bytes memory data)
    {
        BaseSafePayloads.Deployment memory deployment = _deployment(manifest);
        data = _manage(deployment, proofs, _single(BaseSafePayloads.bridgeToEthereum(deployment, amount)));
        Logs.log(
            string.concat(
                "Bridge USDC to Ethereum\n    safe:",
                vm.toString(deployment.safe),
                "\n    recipient:",
                vm.toString(deployment.ethereumAccount),
                "\n    amount:",
                vm.toString(amount)
            )
        );
    }
}
