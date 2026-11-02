// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {ActivityPhaseScript} from "./ActivityContext.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title ActivityManifestScript
/// @notice Loads verified deployment identities and records a single activity's simulated outcome for receipt verification.
abstract contract ActivityManifestScript is ActivityPhaseScript {
    using Strings for uint256;

    error InvalidActivity();

    function _manifest() internal view returns (string memory json, string memory market, address owner, uint256 seed) {
        json = vm.readFile(vm.envString("TESTNET_MANIFEST"));
        uint256 index = vm.envUint("TESTNET_ACTIVITY_MARKET");
        if (
            vm.parseJsonUint(json, ".schemaVersion") != 1 || vm.parseJsonUint(json, ".chainId") != block.chainid
                || (block.chainid != 31_337 && block.chainid != 11_155_111) || index >= 7
        ) revert InvalidActivity();
        market = string.concat(".markets[", index.toString(), "]");
        owner = vm.parseJsonAddress(json, ".owner");
        if (owner == address(0) || vm.parseJsonAddress(json, string.concat(market, ".vault")).code.length == 0) {
            revert InvalidActivity();
        }
        seed = vm.envUint("TESTNET_ACTIVITY_SEED");
    }

    function _address(string memory json, string memory market, string memory key) internal pure returns (address) {
        return vm.parseJsonAddress(json, string.concat(market, ".", key));
    }

    function _result(bool executed, uint256 settled, uint256 cursor, string memory reason) internal {
        vm.serializeJson("activity-result", "{}");
        vm.serializeUint("activity-result", "chainId", block.chainid);
        vm.serializeUint("activity-result", "seed", vm.envUint("TESTNET_ACTIVITY_SEED"));
        vm.serializeBool("activity-result", "executed", executed);
        vm.serializeUint("activity-result", "settled", settled);
        vm.serializeUint("activity-result", "nextCursor", cursor);
        string memory json = vm.serializeString("activity-result", "waiting", reason);
        vm.writeJson(json, vm.envString("TESTNET_ACTIVITY_RESULT"));
    }

    function _broadcast() internal view virtual returns (bool) {
        return true;
    }
}
