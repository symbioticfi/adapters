// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChainActionBase} from "./base/BaseChainActionBase.s.sol";
import {BaseSafePayloads} from "../../base-chain/BaseSafePayloads.sol";
import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {Logs} from "../../utils/Logs.sol";

/**
 * @title BuildMessageLeaf
 * @notice Script writing the one-time Ethereum leaf that makes the Base Safe accept one ERC-1271 digest.
 * @dev The leaf pins the digest. Add it to the MerkleAccount's root, accept it, grant its role, then run
 * `ApproveMessageOnBase` with the same digest. Sends nothing.
 */
contract BuildMessageLeafScript is BaseChainActionBase {
    /// @notice Raised when the leaf path already exists.
    error LeafAlreadyExists();

    /**
     * @notice Writes the leaf, the Safe message hash and the signature to submit for one digest.
     * @dev Reads BASE_MANIFEST and BASE_MESSAGE_DIGEST, and writes BASE_MESSAGE_LEAF. Refuses to overwrite it.
     */
    function run() public returns (bytes32 leaf) {
        string memory path = vm.envString("BASE_MESSAGE_LEAF");
        if (vm.exists(path)) revert LeafAlreadyExists();
        BaseSafePayloads.Deployment memory deployment = _deployment(vm.envString("BASE_MANIFEST"));
        bytes32 digest = vm.envBytes32("BASE_MESSAGE_DIGEST");
        IMerkleAccount.Action memory action = BaseSafePayloads.approveMessage(deployment, digest);
        leaf = ActionMasker.mask(action.target, action.value, action.data, action.dataMask);
        vm.serializeAddress("message", "account", deployment.ethereumAccount);
        vm.serializeAddress("message", "target", action.target);
        vm.serializeUint("message", "value", action.value);
        vm.serializeBytes("message", "data", action.data);
        vm.serializeBytes("message", "dataMask", action.dataMask);
        vm.serializeBytes32("message", "digest", digest);
        vm.serializeBytes32("message", "safeMessageHash", BaseSafePayloads.safeMessageHash(deployment.safe, digest));
        vm.serializeBytes("message", "signature", BaseSafePayloads.aliasSignature(deployment));
        vm.writeJson(vm.serializeBytes32("message", "leaf", leaf), path);
        Logs.log(string.concat("approveMessage: ", vm.toString(leaf)));
    }
}
