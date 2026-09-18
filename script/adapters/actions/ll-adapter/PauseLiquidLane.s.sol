// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./base/PauseLiquidLaneBase.s.sol";

contract PauseLiquidLaneScript is PauseLiquidLaneBaseScript {
    address constant ADAPTER = 0x0000000000000000000000000000000000000000;

    function run() public {
        runBase(ADAPTER);
    }
}
