// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {fxLOOP_Oracle} from "../../../../../src/contracts/merkle-adapter/connectors/oracles/tokens/fxLOOP_Oracle.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Test} from "forge-std/Test.sol";

contract FxLoopOracleMainnetTest is Test {
    function testCapturedSharePriceAndBinding() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc, 26_433_989);

        fxLOOP_Oracle oracle = new fxLOOP_Oracle();
        assertEq(oracle.VAULT(), 0x4Ef75e307f7EDbf0462C679192C1FF7E911c389a);
        assertEq(IERC4626(oracle.VAULT()).asset(), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        assertEq(oracle.getPrice(), 1_018_647_000_000_000_000);
        assertEq(oracle.getPrice(), IERC4626(oracle.VAULT()).convertToAssets(1e18) * 1e12);
        assertEq(oracle.MIN_PRICE(), 254_661_750_000_000_000);
        assertEq(oracle.MAX_PRICE(), 3_565_264_500_000_000_000);
    }
}
