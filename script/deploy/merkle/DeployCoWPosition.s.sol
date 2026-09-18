// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Script} from "forge-std/Script.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {CoWPositionExecutor} from "src/contracts/periphery/CoWPositionExecutor.sol";
import {AaveHealthFactor} from "src/contracts/merkle_adapter/borrow_capability/AaveHealthFactor.sol";
import {MorphoBlueHealthFactor} from "src/contracts/merkle_adapter/borrow_capability/MorphoBlueHealthFactor.sol";

/// @notice Deploy shared infrastructure. Each curator creates its own executor through the factory.
/// @dev Use --account and --sender; the script neither handles keys nor authorizes strategy leaves.
contract DeployCoWPositionScript is Script {
    function run()
        external
        returns (ImmutableFactory factory, AaveHealthFactor aaveHealthFactor, MorphoBlueHealthFactor morphoHealthFactor)
    {
        vm.startBroadcast();
        factory = new ImmutableFactory(type(CoWPositionExecutor).creationCode);
        aaveHealthFactor = new AaveHealthFactor();
        morphoHealthFactor = new MorphoBlueHealthFactor();
        vm.stopBroadcast();
    }
}
