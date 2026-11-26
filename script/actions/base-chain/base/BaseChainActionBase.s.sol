// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChain} from "../../../base-chain/BaseChain.sol";
import {BaseSafePayloads} from "../../../base-chain/BaseSafePayloads.sol";
import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {Logs} from "../../../utils/Logs.sol";
import {ScriptBase} from "../../../utils/ScriptBase.s.sol";

/**
 * @title BaseChainActionBase
 * @notice Base script for Ethereum MerkleAccount actions that fund and operate the Base Safe.
 * @dev Reads the Base manifest written by `DeployBaseSafe` and a proofs file mapping each leaf to its proof in the
 * MerkleAccount's accepted root. The proofs file is a JSON object keyed by leaf hash:
 * `{"0x<leaf>": ["0x<sibling>", ...]}`. The sender must hold the role of every leaf it uses.
 */
abstract contract BaseChainActionBase is ScriptBase {
    using stdJson for string;

    /* ERRORS */

    /// @notice Raised when the script runs on a chain other than Ethereum.
    error InvalidChain();

    /// @notice Raised when the manifest is not a Base Safe deployment.
    error InvalidManifest();

    /* INTERNAL FUNCTIONS */

    /**
     * @notice Returns the deployed addresses recorded in a Base manifest.
     * @dev Checks that the manifest records the Base chain ID before any payload pins its addresses.
     */
    function _deployment(string memory manifestPath)
        internal
        view
        returns (BaseSafePayloads.Deployment memory deployment)
    {
        string memory json = vm.readFile(manifestPath);
        if (json.readUint(".chainId") != BaseChain.BASE_CHAIN_ID) revert InvalidManifest();
        deployment = BaseSafePayloads.Deployment({
            ethereumAccount: json.readAddress(".ethereumAccount"),
            safe: json.readAddress(".safe"),
            recipeCapability: json.readAddress(".recipeCapability"),
            policy: json.readAddress(".threeF.policy")
        });
    }

    /**
     * @notice Attaches each action's proof and sends one `manage` call to the Ethereum MerkleAccount.
     * @dev Derives each leaf with ActionMasker, the hash the MerkleAccount verifies, and looks it up in the
     * proofs file. Logs every leaf so a missing proof can be traced to the leaf builder output.
     */
    function _manage(
        BaseSafePayloads.Deployment memory deployment,
        string memory proofsPath,
        IMerkleAccount.Action[] memory actions
    ) internal returns (bytes memory data) {
        if (block.chainid != BaseChain.ETHEREUM_CHAIN_ID) revert InvalidChain();
        string memory proofs = vm.readFile(proofsPath);
        for (uint256 i; i < actions.length; ++i) {
            bytes32 leaf = ActionMasker.mask(actions[i].target, actions[i].value, actions[i].data, actions[i].dataMask);
            Logs.log(string.concat("leaf ", vm.toString(i), ": ", vm.toString(leaf)));
            actions[i].proof = proofs.readBytes32Array(string.concat(".", vm.toString(leaf)));
        }
        data = abi.encodeCall(IMerkleAccount.manage, (actions));
        sendTransaction(deployment.ethereumAccount, data);
        Logs.logSimulationLink(deployment.ethereumAccount, data);
    }

    /// @notice Wraps one action in an array for `_manage`.
    function _single(IMerkleAccount.Action memory action)
        internal
        pure
        returns (IMerkleAccount.Action[] memory actions)
    {
        actions = new IMerkleAccount.Action[](1);
        actions[0] = action;
    }
}
