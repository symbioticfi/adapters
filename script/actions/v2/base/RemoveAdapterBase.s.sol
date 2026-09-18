// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IVaultV2} from "@symbioticfi/core/src/interfaces/vault/IVaultV2.sol";
import {IUniversalDelegator} from "@symbioticfi/core/src/interfaces/delegator/IUniversalDelegator.sol";
import {Logs} from "../../../utils/Logs.sol";
import {ScriptBase} from "../../../utils/ScriptBase.s.sol";

contract RemoveAdapterBaseScript is ScriptBase {
    function runBase(address vault, address adapter) public virtual returns (bytes memory data, address target) {
        target = IVaultV2(vault).delegator();
        data = abi.encodeCall(IUniversalDelegator.removeAdapter, (adapter));
        sendTransaction(target, data);

        Logs.log(
            string.concat("Remove adapter", "\n    vault:", vm.toString(vault), "\n    adapter:", vm.toString(adapter))
        );
        Logs.logSimulationLink(target, data);
    }
}
