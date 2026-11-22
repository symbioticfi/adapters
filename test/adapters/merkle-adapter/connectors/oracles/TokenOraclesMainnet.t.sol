// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "../../../../../script/deploy/oracles/TokenOracleArtifacts.sol";

import {Oracle} from "../../../../../src/contracts/merkle-adapter/connectors/oracles/Oracle.sol";

import {IOracle} from "../../../../../src/interfaces/ll-adapter/IOracle.sol";

import {Test} from "forge-std/Test.sol";

contract TokenOraclesMainnetTest is Test {
    string internal _config;

    function setUp() public {
        _config = vm.readFile("script/deploy/oracles/mainnet.json");
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc, vm.parseJsonUint(_config, ".referenceBlock"));
    }

    function testPreservesEveryDeployedOracle() public {
        uint256 count;
        for (uint256 i; i < vm.parseJsonArrayLength(_config, ".tokens"); ++i) {
            string memory row = string.concat(".tokens[", vm.toString(i), "]");
            address existing = vm.parseJsonAddress(_config, string.concat(row, ".oracle"));
            if (!_existedAtReferenceBlock(row)) continue;
            ++count;
            address oracle = _deploy(row);
            assertEq(Oracle(oracle).MIN_PRICE(), Oracle(existing).MIN_PRICE(), row);
            assertEq(Oracle(oracle).MAX_PRICE(), Oracle(existing).MAX_PRICE(), row);
            assertEq(IOracle(oracle).getPrice(), IOracle(existing).getPrice(), row);
            // Every immutable source getter exposed by the fixed wrapper must match the live oracle.
            string[4] memory getters = ["DATA_FEED()", "ASYNC_REDEEM_VAULT()", "IDLE_CDO()", "TOKEN_TO_REDEEM()"];
            for (uint256 j; j < getters.length; ++j) {
                bytes memory data = abi.encodeWithSignature(getters[j]);
                (bool success, bytes memory value) = oracle.staticcall(data);
                if (!success || value.length == 0) continue;
                (bool existingSuccess, bytes memory existingValue) = existing.staticcall(data);
                assertTrue(existingSuccess, row);
                assertEq(value, existingValue, row);
            }
        }
        assertEq(count, 15);
    }

    function testFreshOraclesUseCapturedPricesAndCoreRanges() public {
        uint256 count;
        for (uint256 i; i < vm.parseJsonArrayLength(_config, ".tokens"); ++i) {
            string memory row = string.concat(".tokens[", vm.toString(i), "]");
            if (_existedAtReferenceBlock(row)) continue;
            ++count;
            address oracle = _deploy(row);
            uint256 price = vm.parseJsonUint(_config, string.concat(row, ".referencePrice"));
            assertEq(IOracle(oracle).getPrice(), price, row);
            assertEq(
                Oracle(oracle).MIN_PRICE(),
                price * vm.parseJsonUint(_config, string.concat(row, ".minPercent")) / 100,
                row
            );
            assertEq(
                Oracle(oracle).MAX_PRICE(),
                price * vm.parseJsonUint(_config, string.concat(row, ".maxPercent")) / 100,
                row
            );
        }
        assertEq(count, 28);
    }

    function _existedAtReferenceBlock(string memory row) internal view returns (bool) {
        if (vm.parseJsonAddress(_config, string.concat(row, ".oracle")) == address(0)) return false;
        string memory key = string.concat(row, ".deploymentBlock");
        return !vm.keyExistsJson(_config, key)
            || vm.parseJsonUint(_config, key) <= vm.parseJsonUint(_config, ".referenceBlock");
    }

    function _deploy(string memory row) internal returns (address oracle) {
        string memory key = string.concat(row, ".referenceBlock");
        uint256 referenceBlock = vm.keyExistsJson(_config, key)
            ? vm.parseJsonUint(_config, key)
            : vm.parseJsonUint(_config, ".referenceBlock");
        if (block.number != referenceBlock) vm.rollFork(referenceBlock);
        string memory name = vm.parseJsonString(_config, string.concat(row, ".contract"));
        oracle = deployCode(string.concat(name, ".sol:", name));
        assertEq(Oracle(oracle).MIN_PRICE(), vm.parseJsonUint(_config, string.concat(row, ".minPrice")), row);
        assertEq(Oracle(oracle).MAX_PRICE(), vm.parseJsonUint(_config, string.concat(row, ".maxPrice")), row);
    }
}
