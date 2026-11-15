// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MorphoLiquidity} from "src/contracts/merkle-adapter/automations/liquidity/MorphoLiquidity.sol";

/// @notice Deploys the shared Vault V2 / Morpho Blue liquidity reader.
contract DeployMorphoLiquidity is Script {
    function run() external returns (MorphoLiquidity helper) {
        vm.startBroadcast();
        helper = new MorphoLiquidity();
        vm.stopBroadcast();
        console2.log("MorphoLiquidity", address(helper));
    }
}
