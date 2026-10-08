// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {RealisticTestnetTest, RealisticDeployHarness, RealisticReportHarness} from "../RealisticTestnet.t.sol";
import {RWAActivityScript} from "script/deploy/testnet/activity/RWAActivity.s.sol";
import {ThreeFActivityScript} from "script/deploy/testnet/activity/ThreeFActivity.s.sol";
import {MaintenanceActivityScript} from "script/deploy/testnet/activity/MaintenanceActivity.s.sol";
import {TestnetThreeFRequest} from "script/deploy/testnet/protocols/TestnetThreeF.sol";

import {IThreeFAdapter} from "src/interfaces/IThreeFAdapter.sol";
import {Offer} from "src/interfaces/3f-adapter/ThreeFTypes.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract RWAActivityHarness is RWAActivityScript {
    function _broadcast() internal pure override returns (bool) {
        return false;
    }
}

contract ThreeFActivityHarness is ThreeFActivityScript {
    function _broadcast() internal pure override returns (bool) {
        return false;
    }
}

contract MaintenanceActivityHarness is MaintenanceActivityScript {
    function _broadcast() internal pure override returns (bool) {
        return false;
    }
}

/// @title ActivityIntegrationTest
/// @notice Runs repeated production LL redemptions and signed 3F lifecycles against a fully bootstrapped environment.
contract ActivityIntegrationTest is RealisticTestnetTest {
    using Strings for uint256;

    function test_All53ProfilesRunAfterMaturityAndPersistCursors() public {
        string memory path = "script/deploy/testnet/manifests/activity-integration.json";
        string memory result = "script/deploy/testnet/manifests/activity-integration-result.json";
        RealisticDeployHarness(_deploy).writeManifest(_deployed, path);
        vm.setEnv("TESTNET_MANIFEST", path);
        vm.setEnv("TESTNET_ACTIVITY_RESULT", result);
        vm.setEnv("TESTNET_ACTIVITY_SEED", "12345");
        vm.setEnv("TESTNET_ACTIVITY_CURSOR", "0");
        address runner = address(new RWAActivityHarness());
        address maintenance = address(new MaintenanceActivityHarness());
        uint256[] memory cursors = new uint256[](53);
        for (uint256 round; round < 2; ++round) {
            vm.warp(vm.getBlockTimestamp() + 7 days);
            vm.roll(vm.getBlockNumber() + 1);
            vm.setEnv("TESTNET_ACTIVITY_MARKET", "0");
            string memory encodedCursors = cursors[0].toString();
            for (uint256 i = 1; i < cursors.length; ++i) {
                encodedCursors = string.concat(encodedCursors, ",", cursors[i].toString());
            }
            vm.setEnv("TESTNET_ACTIVITY_CURSORS", encodedCursors);
            MaintenanceActivityHarness(maintenance).run();
            cursors = vm.parseJsonUintArray(vm.readFile(result), ".cursors");
            uint256[] memory navs = new uint256[](_deployed.markets.length);
            for (uint256 i; i < navs.length; ++i) {
                navs[i] = RealisticReportHarness(_report).nav(_deployed.markets[i]);
            }
            RealisticReportHarness(_report)
                .runBase(_deployed, uint48(vm.getBlockNumber() - 1), uint48(vm.getBlockTimestamp()), navs);
            uint256 visited;
            for (uint256 i; i < _deployed.markets.length; ++i) {
                vm.setEnv("TESTNET_ACTIVITY_MARKET", i.toString());
                for (uint256 j; j < _deployed.markets[i].rwas.length; ++j) {
                    vm.setEnv("TESTNET_ACTIVITY_PROFILE", _deployed.markets[i].rwas[j].profile.toString());
                    RWAActivityHarness(runner).run();
                    assertEq(vm.parseJsonUint(vm.readFile(result), ".chainId"), block.chainid);
                    ++visited;
                }
            }
            assertEq(visited, 53);
        }
        vm.removeFile(path);
        vm.removeFile(result);
    }

    function test_ThreeFFinalizesAndConsumesNewSignedFundedRequests() public {
        string memory path = "script/deploy/testnet/manifests/activity-threef.json";
        string memory result = "script/deploy/testnet/manifests/activity-threef-result.json";
        RealisticDeployHarness(_deploy).writeManifest(_deployed, path);
        vm.setEnv("TESTNET_MANIFEST", path);
        vm.setEnv("TESTNET_ACTIVITY_RESULT", result);
        vm.setEnv("TESTNET_ACTIVITY_SEED", "777");
        vm.setEnv("TESTNET_ACTIVITY_MARKET", "0");
        address runner = address(new ThreeFActivityHarness());
        ThreeFActivityHarness(runner).run();
        string memory outcome = vm.readFile(result);
        address request = vm.parseJsonAddress(outcome, ".request");
        uint256 amount = vm.parseJsonUint(outcome, ".amount");
        address adapter = _deployed.markets[0].threeFAdapter;
        assertNotEq(request, address(0));
        Offer memory offer = Offer({
            maker: adapter,
            amount: amount,
            expectedReturn: amount / 100,
            nonce: 0,
            expiration: TestnetThreeFRequest(request).maturity(),
            useCallback: true
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_key, TestnetThreeFRequest(request).offerDigest(offer));
        vm.setEnv("TESTNET_ACTIVITY_REQUEST", vm.toString(request));
        vm.setEnv("TESTNET_ACTIVITY_AMOUNT", amount.toString());
        vm.setEnv("TESTNET_ACTIVITY_SIGNATURE", vm.toString(abi.encodePacked(r, s, v)));
        ThreeFActivityHarness(runner).runConsume();
        assertEq(IThreeFAdapter(adapter).pendingAssets(request), amount);
        assertEq(IThreeFAdapter(adapter).requestsLength(), 2);
        vm.warp(TestnetThreeFRequest(request).maturity());
        vm.roll(vm.getBlockNumber() + 1);
        uint256[] memory cursors = new uint256[](53);
        string memory encodedCursors = "0";
        for (uint256 i = 1; i < cursors.length; ++i) {
            encodedCursors = string.concat(encodedCursors, ",0");
        }
        vm.setEnv("TESTNET_ACTIVITY_CURSORS", encodedCursors);
        address maintenance = address(new MaintenanceActivityHarness());
        MaintenanceActivityHarness(maintenance).run();
        vm.setEnv("TESTNET_ACTIVITY_MARKET", "0");
        uint256[] memory navs = new uint256[](_deployed.markets.length);
        for (uint256 i; i < navs.length; ++i) {
            navs[i] = RealisticReportHarness(_report).nav(_deployed.markets[i]);
        }
        RealisticReportHarness(_report)
            .runBase(_deployed, uint48(vm.getBlockNumber() - 1), uint48(vm.getBlockTimestamp()), navs);
        ThreeFActivityHarness(runner).run();
        assertEq(IThreeFAdapter(adapter).requestIndex(request), 0);
        assertGt(vm.parseJsonUint(vm.readFile(result), ".settled"), 0);
        vm.removeFile(path);
        vm.removeFile(result);
    }
}
