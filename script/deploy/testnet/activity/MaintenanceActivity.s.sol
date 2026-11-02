// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {ActivityManifestScript} from "./ActivityManifest.sol";
import {RWAActivityScript} from "./RWAActivity.s.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title MaintenanceRWAActivityScript
/// @notice Selects broadcaster behavior for the parent maintenance sweep and its integration tests.
contract MaintenanceRWAActivityScript is RWAActivityScript {
    bool internal immutable _configuredBroadcast;

    constructor(bool newBroadcast) {
        _configuredBroadcast = newBroadcast;
    }

    function _broadcast() internal view override returns (bool) {
        return _configuredBroadcast;
    }
}

/// @title MaintenanceActivityScript
/// @notice Refreshes all native prices and matured redemptions before any aggregate LL or vault liquidity read.
contract MaintenanceActivityScript is ActivityManifestScript {
    using Strings for uint256;

    function run() public {
        (string memory json,,, uint256 seed) = _manifest();
        uint256[] memory cursors = vm.envUint("TESTNET_ACTIVITY_CURSORS", ",");
        uint256[] memory settlements = new uint256[](52);
        if (cursors.length != 52) revert InvalidActivity();
        address helper = address(new MaintenanceRWAActivityScript(_broadcast()));
        string memory resultPath = vm.envString("TESTNET_ACTIVITY_RESULT");
        uint256 settled;
        for (uint256 i; i < 7; ++i) {
            vm.setEnv("TESTNET_ACTIVITY_MARKET", i.toString());
            uint256[] memory profiles =
                vm.parseJsonUintArray(json, string.concat(".markets[", i.toString(), "].rwaProfiles"));
            for (uint256 j; j < profiles.length; ++j) {
                uint256 profile = profiles[j];
                vm.setEnv("TESTNET_ACTIVITY_PROFILE", profile.toString());
                vm.setEnv("TESTNET_ACTIVITY_SEED", uint256(keccak256(abi.encode(seed, profile))).toString());
                vm.setEnv("TESTNET_ACTIVITY_CURSOR", cursors[profile].toString());
                MaintenanceRWAActivityScript(helper).runMaintenance();
                string memory result = vm.readFile(resultPath);
                settlements[profile] = vm.parseJsonUint(result, ".settled");
                settled += settlements[profile];
                cursors[profile] = vm.parseJsonUint(result, ".nextCursor");
            }
        }
        vm.setEnv("TESTNET_ACTIVITY_SEED", seed.toString());
        _result(settled > 0, settled, 0, "");
        vm.serializeUint("activity-result", "settlements", settlements);
        string memory result = vm.serializeUint("activity-result", "cursors", cursors);
        vm.writeJson(result, resultPath);
    }
}
