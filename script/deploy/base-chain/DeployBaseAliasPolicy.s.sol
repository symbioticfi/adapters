// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChain} from "../../base-chain/BaseChain.sol";
import {BaseAliasThreeFPolicy} from "src/contracts/merkle-adapter/capabilities/policies/BaseAliasThreeFPolicy.sol";

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployBaseAliasPolicy
/// @notice Deploys the Ethereum policy for 3F mints by the MerkleAccount's alias on Base.
contract DeployBaseAliasPolicyScript is Script {
    /// @notice Raised when the script is run outside Ethereum or its Base portal is missing.
    error InvalidChain();

    /// @notice Raised when the configured Ethereum account has no code.
    error InvalidAccount();

    /// @notice Raised when the manifest path already exists.
    error ManifestAlreadyExists();

    /**
     * @notice Deploys the policy and writes the alias manifest.
     * @dev Reads BASE_ALIAS_MANIFEST and BASE_ETHEREUM_ACCOUNT. Run on Ethereum with the deployer account.
     * A dry run leaves the manifest unwritten. Add `--broadcast` to deploy and write it.
     */
    function run() public returns (address policy) {
        string memory manifest = vm.envString("BASE_ALIAS_MANIFEST");
        if (vm.exists(manifest)) revert ManifestAlreadyExists();
        if (block.chainid != BaseChain.ETHEREUM_CHAIN_ID || BaseChain.BASE_PORTAL.code.length == 0) {
            revert InvalidChain();
        }
        address ethereumAccount = vm.envAddress("BASE_ETHEREUM_ACCOUNT");
        if (ethereumAccount.code.length == 0) revert InvalidAccount();

        _startBroadcast();
        policy = address(new BaseAliasThreeFPolicy(ethereumAccount));
        _stopBroadcast();

        if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) {
            console2.log("Dry run: the manifest was not written. Add --broadcast to deploy and write", manifest);
            return policy;
        }
        _writeManifest(manifest, ethereumAccount, policy);
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Records the policy chain separately from the alias destination chain.
    function _writeManifest(string memory path, address ethereumAccount, address policy) internal {
        vm.serializeUint("manifest", "chainId", BaseChain.BASE_CHAIN_ID);
        vm.serializeUint("manifest", "policyChainId", BaseChain.ETHEREUM_CHAIN_ID);
        vm.serializeUint("manifest", "policyFromBlock", block.number);
        vm.serializeAddress("manifest", "ethereumAccount", ethereumAccount);
        vm.serializeString("manifest", "threeF", "");
        vm.writeJson(vm.serializeAddress("manifest", "alias", BaseChain.l2Alias(ethereumAccount)), path);

        vm.serializeAddress("threeF", "requestsFactory", BaseChain.THREE_F_REQUESTS_FACTORY);
        vm.serializeAddress("threeF", "facility", BaseChain.THREE_F_FACILITY);
        vm.writeJson(vm.serializeAddress("threeF", "policy", policy), path, ".threeF");
    }

    /// @notice Starts broadcasting from the script sender. Test harnesses override it.
    function _startBroadcast() internal virtual {
        vm.startBroadcast();
    }

    /// @notice Stops broadcasting. Test harnesses override it.
    function _stopBroadcast() internal virtual {
        vm.stopBroadcast();
    }
}
