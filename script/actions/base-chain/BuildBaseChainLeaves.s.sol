// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChainActionBase} from "./base/BaseChainActionBase.s.sol";
import {BaseSafePayloads} from "../../base-chain/BaseSafePayloads.sol";
import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {Logs} from "../../utils/Logs.sol";

/**
 * @title BuildBaseChainLeaves
 * @notice Script writing the Ethereum MerkleAccount leaves that the Base Safe actions use.
 * @dev Builds each action template from the Base manifest with zero runtime values. Masked words do not affect
 * a leaf, so the action scripts derive the same leaves with real values. Add the leaves to the MerkleAccount's
 * root, accept it, grant each leaf role to its executor, and write the proofs file the action scripts read.
 * Sends nothing.
 */
contract BuildBaseChainLeavesScript is BaseChainActionBase {
    /// @notice Raised when the leaves path already exists.
    error LeavesAlreadyExist();

    /**
     * @notice Writes every Base action leaf with its target, calldata template, mask and hash.
     * @dev Reads BASE_MANIFEST and writes BASE_LEAVES, keyed by action name. Refuses to overwrite BASE_LEAVES.
     */
    function run() public returns (bytes32[] memory leaves) {
        string memory path = vm.envString("BASE_LEAVES");
        if (vm.exists(path)) revert LeavesAlreadyExist();
        BaseSafePayloads.Deployment memory deployment = _deployment(vm.envString("BASE_MANIFEST"));
        string[7] memory names = [
            "approveBridge",
            "bridgeToBase",
            "bridgeToEthereum",
            "mintThreeF",
            "redeemThreeF",
            "setMaxAssetsPerDuration",
            "setMinYieldPerRequest"
        ];
        IMerkleAccount.Action[7] memory actions = [
            BaseSafePayloads.approveBridge(0),
            BaseSafePayloads.bridgeToBase(deployment, 0),
            BaseSafePayloads.bridgeToEthereum(deployment, 0),
            BaseSafePayloads.mintThreeF(deployment, address(0), 0),
            BaseSafePayloads.redeemThreeF(deployment, address(0)),
            BaseSafePayloads.setMaxAssetsPerDuration(deployment, address(0), 0, 0),
            BaseSafePayloads.setMinYieldPerRequest(deployment, address(0), 0)
        ];
        leaves = new bytes32[](names.length);
        string[] memory entries = new string[](names.length);
        for (uint256 i; i < names.length; ++i) {
            IMerkleAccount.Action memory action = actions[i];
            leaves[i] = ActionMasker.mask(action.target, action.value, action.data, action.dataMask);
            vm.serializeAddress(names[i], "target", action.target);
            vm.serializeUint(names[i], "value", action.value);
            vm.serializeBytes(names[i], "data", action.data);
            vm.serializeBytes(names[i], "dataMask", action.dataMask);
            entries[i] = vm.serializeBytes32(names[i], "leaf", leaves[i]);
            vm.serializeString("leaves", names[i], "");
            Logs.log(string.concat(names[i], ": ", vm.toString(leaves[i])));
        }
        vm.writeJson(vm.serializeAddress("leaves", "account", deployment.ethereumAccount), path);
        for (uint256 i; i < names.length; ++i) {
            vm.writeJson(entries[i], path, string.concat(".", names[i]));
        }
    }
}
