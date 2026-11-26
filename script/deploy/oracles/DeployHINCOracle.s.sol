// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {HINC_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/HINC_Oracle.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

contract DeployHINCOracle is Script {
    address internal constant DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant SALT = keccak256("symbiotic.hinc-oracle.v1");

    function run() external returns (address oracle) {
        require(block.chainid == 1, "mainnet only");
        bytes memory creationCode = type(HINC_Oracle).creationCode;
        oracle = vm.computeCreate2Address(SALT, keccak256(creationCode), DEPLOYER);
        if (oracle.code.length == 0) {
            vm.broadcast();
            (bool success,) = DEPLOYER.call(abi.encodePacked(SALT, creationCode));
            require(success && oracle.code.length != 0, "oracle deployment failed");
        }
        require(HINC_Oracle(oracle).getPrice() > 0, "invalid current price");
        console2.log("HINC oracle", oracle);
    }
}
