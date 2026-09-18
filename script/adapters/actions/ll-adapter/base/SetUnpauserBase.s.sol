// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILiquidLaneAdapter} from "../../../../../src/interfaces/ILiquidLaneAdapter.sol";
import {Logs} from "../../../../utils/Logs.sol";
import {ScriptBase} from "../../../../utils/ScriptBase.s.sol";

contract SetUnpauserBaseScript is ScriptBase {
    function runBase(address adapter, address unpauser) public virtual returns (bytes memory data, address target) {
        target = adapter;
        data = abi.encodeCall(ILiquidLaneAdapter.setUnpauser, (unpauser));
        sendTransaction(target, data);

        Logs.log(
            string.concat(
                "Set LiquidLane unpauser",
                "\n    adapter:",
                vm.toString(adapter),
                "\n    unpauser:",
                vm.toString(unpauser)
            )
        );
        Logs.logSimulationLink(target, data);
    }
}
