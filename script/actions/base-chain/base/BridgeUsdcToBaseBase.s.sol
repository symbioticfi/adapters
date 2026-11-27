// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChainActionBase} from "./BaseChainActionBase.s.sol";
import {BaseSafePayloads} from "../../../base-chain/BaseSafePayloads.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {Logs} from "../../../utils/Logs.sol";

/// @title BridgeUsdcToBaseBase
/// @notice Base script burning Ethereum MerkleAccount USDC through CCTP to the Base Safe.
contract BridgeUsdcToBaseBaseScript is BaseChainActionBase {
    /**
     * @notice Approves the TokenMessenger and burns `amount` USDC to the Base Safe in one `manage` call.
     * @dev Uses the `approveBridge` and `bridgeToBase` leaves. After Circle attests the burn, relay it on Base with
     * `ReceiveCctpMessage`.
     */
    function runBase(string memory manifest, string memory proofs, uint256 amount)
        public
        virtual
        returns (bytes memory data)
    {
        BaseSafePayloads.Deployment memory deployment = _deployment(manifest);
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](2);
        actions[0] = BaseSafePayloads.approveBridge(amount);
        actions[1] = BaseSafePayloads.bridgeToBase(deployment, amount);
        data = _manage(deployment, proofs, actions);
        Logs.log(
            string.concat(
                "Bridge USDC to Base\n    safe:", vm.toString(deployment.safe), "\n    amount:", vm.toString(amount)
            )
        );
    }
}
