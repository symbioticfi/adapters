// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./base/SetPauserBase.s.sol";

contract SetPauserScript is SetPauserBaseScript {
    address constant ADAPTER = 0x0000000000000000000000000000000000000000;
    address constant PAUSER = 0x0000000000000000000000000000000000000000;

    function run() public {
        runBase(ADAPTER, PAUSER);
    }
}
