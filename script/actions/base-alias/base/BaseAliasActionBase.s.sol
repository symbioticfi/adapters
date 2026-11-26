// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChain} from "../../../base-chain/BaseChain.sol";
import {BaseAliasPayloads} from "../../../base-chain/BaseAliasPayloads.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {Logs} from "../../../utils/Logs.sol";
import {ScriptBase} from "../../../utils/ScriptBase.s.sol";

/**
 * @title BaseAliasActionBase
 * @notice Base script for Ethereum MerkleAccount actions that operate the MerkleAccount's alias on Base (no Safe).
 * @dev Reads the alias manifest written by `DeployBaseAliasPolicy` and a proofs file mapping each leaf to its proof
 * in the MerkleAccount's accepted root. The proofs file is a JSON object keyed by leaf hash:
 * `{"0x<leaf>": ["0x<sibling>", ...]}`. The sender must hold the role of every leaf it uses.
 */
abstract contract BaseAliasActionBase is ScriptBase {
    using stdJson for string;

    /* ERRORS */

    /// @notice Raised when the script runs on a chain other than Ethereum.
    error InvalidChain();

    /// @notice Raised when the manifest does not describe the Base alias and its Ethereum policy.
    error InvalidManifest();

    /* INTERNAL FUNCTIONS */

    /**
     * @notice Returns the deployed addresses recorded in an alias manifest.
     * @dev Checks the destination and policy chain IDs and the account's Base alias.
     */
    function _deployment(string memory manifestPath)
        internal
        view
        returns (BaseAliasPayloads.Deployment memory deployment)
    {
        string memory json = vm.readFile(manifestPath);
        deployment = BaseAliasPayloads.Deployment({
            ethereumAccount: json.readAddress(".ethereumAccount"), policy: json.readAddress(".threeF.policy")
        });
        if (
            json.readUint(".chainId") != BaseChain.BASE_CHAIN_ID
                || json.readUint(".policyChainId") != BaseChain.ETHEREUM_CHAIN_ID
                || deployment.ethereumAccount == address(0) || deployment.policy == address(0)
                || json.readAddress(".alias") != BaseAliasPayloads.aliasOf(deployment)
        ) revert InvalidManifest();
    }

    /**
     * @notice Attaches each action's proof from the proofs file.
     * @dev Derives each leaf as the MerkleAccount does and logs it, so a missing proof can be traced to the leaf
     * builder output. Reverts if the proofs file has no entry for a leaf.
     */
    function _attachProofs(string memory proofsPath, IMerkleAccount.Action[] memory actions) internal {
        string memory proofs = vm.readFile(proofsPath);
        for (uint256 i; i < actions.length; ++i) {
            bytes32 leaf = BaseAliasPayloads.leaf(actions[i]);
            Logs.log(string.concat("leaf ", vm.toString(i), ": ", vm.toString(leaf)));
            actions[i].proof = proofs.readBytes32Array(string.concat(".", vm.toString(leaf)));
        }
    }

    /**
     * @notice Attaches each action's proof and sends one `manage` call to the Ethereum MerkleAccount.
     * @dev Each portal action becomes one Base transaction from the alias, in array order.
     */
    function _manage(
        BaseAliasPayloads.Deployment memory deployment,
        string memory proofsPath,
        IMerkleAccount.Action[] memory actions
    ) internal returns (bytes memory data) {
        _requireEthereum();
        _attachProofs(proofsPath, actions);
        data = abi.encodeCall(IMerkleAccount.manage, (actions));
        sendTransaction(deployment.ethereumAccount, data);
        Logs.logSimulationLink(deployment.ethereumAccount, data);
    }

    /// @notice Reverts unless the script runs on Ethereum, where the MerkleAccount sends the portal deposits.
    function _requireEthereum() internal view {
        if (block.chainid != BaseChain.ETHEREUM_CHAIN_ID) revert InvalidChain();
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

    /// @notice Wraps two actions in an array for `_manage`, in the order Base must run them.
    function _pair(IMerkleAccount.Action memory first, IMerkleAccount.Action memory second)
        internal
        pure
        returns (IMerkleAccount.Action[] memory actions)
    {
        actions = new IMerkleAccount.Action[](2);
        actions[0] = first;
        actions[1] = second;
    }
}
