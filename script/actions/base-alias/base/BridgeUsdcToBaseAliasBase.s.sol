// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAliasActionBase} from "./BaseAliasActionBase.s.sol";
import {BaseAliasPayloads} from "../../../base-chain/BaseAliasPayloads.sol";

import {Logs} from "../../../utils/Logs.sol";

/// @title BridgeUsdcToBaseAliasBase
/// @notice Base script burning Ethereum MerkleAccount USDC through CCTP to the manager on Base.
contract BridgeUsdcToBaseAliasBaseScript is BaseAliasActionBase {
    /**
     * @notice Approves the TokenMessenger and burns `amount` USDC to the manager in one `manage` call.
     * @dev Uses the `approveBridge` and `bridgeToBaseManager` leaves. After Circle attests the burn, relay it on Base
     * with `ReceiveCctpMessage`.
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
            _pair(BaseAliasPayloads.approveBridge(amount), BaseAliasPayloads.bridgeToBase(deployment, amount))
        );
        Logs.log(
            string.concat(
                "Bridge USDC to the Base manager\n    manager:",
                vm.toString(deployment.manager),
                "\n    amount:",
                vm.toString(amount)
            )
        );
    }
}
