// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {TestnetAavePool, TestnetCreditVault} from "./protocols/TestnetLending.sol";
import {TestnetAaveV4} from "./protocols/TestnetNativeLending.sol";
import {TestnetCatalog} from "./catalog/TestnetCatalog.sol";
import {TestnetMidnight} from "./protocols/upstream/TestnetMidnight.sol";
import {TestnetThreeFRequest} from "./protocols/TestnetThreeF.sol";

import {IAccount} from "src/interfaces/ll-adapter/IAccount.sol";
import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ICREWorkflowRegistry} from "src/interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {ILiquidLaneAdapter} from "src/interfaces/ILiquidLaneAdapter.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IOracle} from "src/interfaces/ll-adapter/IOracle.sol";
import {IThreeFAdapter} from "src/interfaces/IThreeFAdapter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IAdapterRegistry} from "@symbioticfi/core/src/interfaces/IAdapterRegistry.sol";

import {Script, console2} from "forge-std/Script.sol";

import {Id, IMorpho} from "morpho-blue/src/interfaces/IMorpho.sol";

/// @title ValidateRealisticTestnetScript
/// @notice Verifies the human-readable manifest against persisted accounts, workflows and funded positions.
contract ValidateRealisticTestnetScript is Script {
    using Strings for uint256;
    error InvalidDeployment();

    function run() public view {
        string memory json =
            vm.readFile(vm.envOr("TESTNET_MANIFEST", string("script/deploy/testnet/manifests/realistic.json")));
        if (vm.parseJsonUint(json, ".chainId") != block.chainid) revert InvalidDeployment();
        address owner = vm.parseJsonAddress(json, ".owner");
        address forwarder = vm.parseJsonAddress(json, ".forwarder");
        address adapterRegistry = vm.parseJsonAddress(json, ".adapterRegistry");
        address[] memory vaults = vm.parseJsonAddressArray(json, ".vaults");
        if (owner == address(0) || vaults.length != 7) revert InvalidDeployment();
        bool[] memory seen = new bool[](TestnetCatalog.count());
        uint256 count;
        for (uint256 i; i < vaults.length; ++i) {
            string memory path = string.concat(".markets[", i.toString(), "]");
            address vault = _address(json, path, "vault");
            address asset = _address(json, path, "asset");
            address adapter = _address(json, path, "merkleAdapter");
            address account = IMerkleAdapter(adapter).account();
            address request = _address(json, path, "threeFRequest");
            if (
                vault != vaults[i] || IERC4626(vault).asset() != asset || IERC20(vault).totalSupply() == 0
                    || ICREOracle(IMerkleAdapter(adapter).oracle()).FORWARDER() != forwarder
                    || ICREWorkflowRegistry(_address(json, path, "workflowRegistry"))
                            .workflowId(IMerkleAdapter(adapter).oracle()) == bytes32(0)
                    || IMerkleAccount(account).getCapabilities().length == 0
                    || !IAdapterRegistry(adapterRegistry).isWhitelisted(vault, adapter)
                    || TestnetAavePool(_address(json, path, "aavePool")).debtOf(owner) == 0
                    || TestnetCreditVault(_address(json, path, "eulerVault")).totalBorrows() == 0
                    || IERC20(asset).allowance(account, _address(json, path, "aavePool")) > 0
                    || IERC20(asset).allowance(account, request) > 0
            ) revert InvalidDeployment();
            (uint256 principal,) = TestnetThreeFRequest(request).balancesOf(account);
            if (principal == 0 || IThreeFAdapter(_address(json, path, "threeFAdapter")).requestIndex(request) == 0) {
                revert InvalidDeployment();
            }
            bytes32 blueId = vm.parseJsonBytes32(json, string.concat(path, ".morphoBlueMarketId"));
            bytes32 midnightId = vm.parseJsonBytes32(json, string.concat(path, ".morphoMidnightMarketId"));
            if (
                IMorpho(_address(json, path, "morphoBlue")).position(Id.wrap(blueId), owner).borrowShares == 0
                    || TestnetMidnight(_address(json, path, "morphoMidnight")).debt(midnightId, owner) == 0
                    || TestnetMidnight(_address(json, path, "morphoMidnight"))
                            .credit(midnightId, _address(json, path, "midnightLender")) == 0
                    || TestnetAaveV4(_address(json, path, "aaveV4")).getUserSuppliedAssets(0, owner) == 0
            ) revert InvalidDeployment();
            count += _catalog(json, path, i, owner, seen);
        }
        if (count != TestnetCatalog.count()) revert InvalidDeployment();
        console2.log("Verified funded markets", vaults.length);
        console2.log("Verified integration profiles", count);
    }

    function _catalog(string memory json, string memory path, uint256 index, address owner, bool[] memory seen)
        internal
        view
        returns (uint256)
    {
        uint256[] memory profiles = vm.parseJsonUintArray(json, string.concat(path, ".rwaProfiles"));
        address[] memory tokens = vm.parseJsonAddressArray(json, string.concat(path, ".rwaTokens"));
        address[] memory oracles = vm.parseJsonAddressArray(json, string.concat(path, ".rwaOracles"));
        address[] memory endpoints = vm.parseJsonAddressArray(json, string.concat(path, ".redemptionEndpoints"));
        if (
            profiles.length != tokens.length || profiles.length != oracles.length || profiles.length != endpoints.length
        ) revert InvalidDeployment();
        address adapter = _address(json, path, "liquidLaneAdapter");
        for (uint256 j; j < profiles.length; ++j) {
            address account = ILiquidLaneAdapter(adapter).accounts(tokens[j]);
            if (
                profiles[j] >= seen.length || seen[profiles[j]] || TestnetCatalog.profile(profiles[j]).market != index
                    || tokens[j].code.length == 0 || endpoints[j].code.length == 0 || account.code.length == 0
                    || IAccount(account).TOKEN_TO_REDEEM() != tokens[j] || IERC20(tokens[j]).balanceOf(owner) == 0
                    || IOracle(oracles[j]).getPrice() == 0
            ) revert InvalidDeployment();
            if (TestnetCatalog.profile(profiles[j]).mechanism == 6 && IAccount(account).totalAssets() == 0) {
                revert InvalidDeployment();
            }
            seen[profiles[j]] = true;
        }
        return profiles.length;
    }

    function _address(string memory json, string memory path, string memory field) internal pure returns (address) {
        return vm.parseJsonAddress(json, string.concat(path, ".", field));
    }
}
