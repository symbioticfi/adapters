// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAliasActionBase} from "./base/BaseAliasActionBase.s.sol";
import {BaseAliasPayloads} from "../../base-chain/BaseAliasPayloads.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {Logs} from "../../utils/Logs.sol";

/**
 * @title BuildBaseAliasLeaves
 * @notice Script writing the eleven Ethereum MerkleAccount leaves of the alias-only 3F flow on Base.
 * @dev Builds each action template from the alias manifest with zero runtime values. Masked words do not affect a
 * leaf, so the action scripts and `RecipeExecutor` derive the same leaves with real values. Add the leaves to the
 * MerkleAccount's root, accept it, grant each role as `ALIAS_RUNBOOK.md` section 2 shows (`consumeThreeF`,
 * `approveThreeF` and `mintThreeF` to `RecipeExecutor` only), and write the proofs file the action scripts read. Sends nothing.
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
        string[11] memory names = [
            "approveBridge",
            "bridgeToBaseAlias",
            "setMaxAssetsPerDuration",
            "setMinYieldPerRequest",
            "consumeThreeF",
            "approveThreeF",
            "mintThreeF",
            "resetThreeFApproval",
            "redeemThreeF",
            "approveBurn",
            "bridgeToEthereum"
        ];
        IMerkleAccount.Action[11] memory actions = [
            BaseAliasPayloads.approveBridge(0),
            BaseAliasPayloads.bridgeToBase(deployment, 0),
            BaseAliasPayloads.setMaxAssetsPerDuration(deployment, address(0), 0, 0),
            BaseAliasPayloads.setMinYieldPerRequest(deployment, address(0), 0),
            BaseAliasPayloads.consumeThreeF(deployment, address(0), 0, 0),
            BaseAliasPayloads.approveThreeF(address(0), 0),
            BaseAliasPayloads.mintThreeF(address(0), 0, 0),
            BaseAliasPayloads.resetThreeFApproval(address(0)),
            BaseAliasPayloads.redeemThreeF(deployment, address(0)),
            BaseAliasPayloads.approveBurn(0),
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
        vm.writeJson(vm.serializeAddress("leaves", "account", deployment.ethereumAccount), path);
        for (uint256 i; i < names.length; ++i) {
            vm.writeJson(entries[i], path, string.concat(".", names[i]));
        }
    }
}
