// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAppAdapter} from "../../../../../src/interfaces/IAppAdapter.sol";
import {Logs} from "../../../../utils/Logs.sol";
import {ScriptBase} from "../../../../utils/ScriptBase.s.sol";

contract RewardBaseScript is ScriptBase {
    function runBase(address adapter, address token, uint256 amount)
        public
        virtual
        returns (bytes memory data, address target)
    {
        target = adapter;
        data = abi.encodeCall(IAppAdapter.reward, (token, amount));
        sendTransaction(target, data);

        Logs.log(
            string.concat(
                "Reward adapter",
                "\n    adapter:",
                vm.toString(adapter),
                "\n    token:",
                vm.toString(token),
                "\n    amount:",
                vm.toString(amount)
            )
        );
        Logs.logSimulationLink(target, data);
    }
}
