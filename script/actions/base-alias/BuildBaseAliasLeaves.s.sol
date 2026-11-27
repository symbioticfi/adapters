// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAliasActionBase} from "./base/BaseAliasActionBase.s.sol";
import {BaseAliasPayloads} from "../../base-chain/BaseAliasPayloads.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {Logs} from "../../utils/Logs.sol";

/**
 * @title BuildBaseAliasLeaves
 * @notice Script writing the seven Ethereum MerkleAccount leaves for the alias-controlled 3F flow on Base.
 * @dev Masked words do not affect each leaf. Grant the mint leaf only to the committed Ethereum RecipeExecutor, as documented in ALIAS_RUNBOOK.md.
 */
contract BuildBaseAliasLeavesScript is BaseAliasActionBase {
    /// @notice Raised when the leaves path already exists.
    error LeavesAlreadyExist();

    /**
     * @notice Writes every alias leaf with its target, calldata template, mask and hash.
     * @dev Reads BASE_ALIAS_MANIFEST and writes BASE_ALIAS_LEAVES, keyed by action name. Refuses to overwrite.
     */
    function run() public returns (bytes32[] memory leaves) {
        string memory path = vm.envString("BASE_ALIAS_LEAVES");
        if (vm.exists(path)) revert LeavesAlreadyExist();
        BaseAliasPayloads.Deployment memory deployment = _deployment(vm.envString("BASE_ALIAS_MANIFEST"));
        string[7] memory names = [
            "approveBridge",
            "bridgeToBaseManager",
            "setMaxAssetsPerDuration",
            "setMinYieldPerRequest",
            "mintThreeF",
            "redeemThreeF",
            "bridgeToEthereum"
        ];
        IMerkleAccount.Action[7] memory actions = [
            BaseAliasPayloads.approveBridge(0),
            BaseAliasPayloads.bridgeToBase(deployment, 0),
            BaseAliasPayloads.setMaxAssetsPerDuration(deployment, address(0), 0, 0),
            BaseAliasPayloads.setMinYieldPerRequest(deployment, address(0), 0),
            BaseAliasPayloads.mintThreeF(deployment, address(0), 0, 0),
            BaseAliasPayloads.redeemThreeF(deployment, address(0)),
            BaseAliasPayloads.bridgeToEthereum(deployment, 0)
        ];
        leaves = new bytes32[](names.length);
        string[] memory entries = new string[](names.length);
        for (uint256 i; i < names.length; ++i) {
            IMerkleAccount.Action memory action = actions[i];
            leaves[i] = BaseAliasPayloads.leaf(action);
            vm.serializeAddress(names[i], "target", action.target);
            vm.serializeUint(names[i], "value", action.value);
            vm.serializeBytes(names[i], "data", action.data);
            vm.serializeBytes(names[i], "dataMask", action.dataMask);
            entries[i] = vm.serializeBytes32(names[i], "leaf", leaves[i]);
            vm.serializeString("leaves", names[i], "");
            Logs.log(string.concat(names[i], ": ", vm.toString(leaves[i])));
        }
        vm.serializeAddress("leaves", "alias", BaseAliasPayloads.aliasOf(deployment));
        vm.serializeAddress("leaves", "manager", deployment.manager);
        vm.writeJson(vm.serializeAddress("leaves", "account", deployment.ethereumAccount), path);
        for (uint256 i; i < names.length; ++i) {
            vm.writeJson(entries[i], path, string.concat(".", names[i]));
        }
    }
}
