// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TokenOracleArtifacts.sol";

import {Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/Oracle.sol";

import {IOracle} from "../../../src/interfaces/ll-adapter/IOracle.sol";

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Deploys the missing mainnet token oracles and reuses existing LL oracles.
contract DeployTokenOracles is Script {
    function run() public returns (address[] memory oracles) {
        require(block.chainid == 1, "mainnet only");
        string memory config = vm.readFile("script/deploy/oracles/mainnet.json");
        uint256 count = vm.parseJsonArrayLength(config, ".tokens");
        oracles = new address[](count);
        string memory output = "tokenOracles";
        string memory result;

        vm.startBroadcast();
        for (uint256 i; i < count; ++i) {
            string memory row = string.concat(".tokens[", vm.toString(i), "]");
            string memory id = vm.parseJsonString(config, string.concat(row, ".id"));
            address oracle = vm.parseJsonAddress(config, string.concat(row, ".oracle"));
            if (oracle == address(0)) {
                string memory name = vm.parseJsonString(config, string.concat(row, ".contract"));
                bytes memory creationCode = vm.getCode(string.concat(name, ".sol:", name));
                assembly ("memory-safe") {
                    oracle := create(0, add(creationCode, 0x20), mload(creationCode))
                }
                require(oracle != address(0), "oracle deployment failed");
            }
            require(oracle.code.length > 0, "oracle not deployed");
            require(
                Oracle(oracle).MIN_PRICE() == vm.parseJsonUint(config, string.concat(row, ".minPrice")),
                "unexpected minimum"
            );
            require(
                Oracle(oracle).MAX_PRICE() == vm.parseJsonUint(config, string.concat(row, ".maxPrice")),
                "unexpected maximum"
            );
            require(IOracle(oracle).getPrice() > 0, "invalid current price");
            oracles[i] = oracle;
            result = vm.serializeAddress(output, id, oracle);
            console2.log(id, oracle);
        }
        vm.stopBroadcast();

        vm.writeJson(result, vm.envOr("TOKEN_ORACLES_OUTPUT", string("deployments/token-oracles-mainnet.json")));
    }
}
