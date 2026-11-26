// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChainActionBase} from "./BaseChainActionBase.s.sol";
import {BaseSafePayloads} from "../../../base-chain/BaseSafePayloads.sol";

import {Logs} from "../../../utils/Logs.sol";

/// @title ApproveMessageOnBaseBase
/// @notice Base script sending a portal message that makes the Base Safe accept one ERC-1271 message.
contract ApproveMessageOnBaseBaseScript is BaseChainActionBase {
    /**
     * @notice Approves `digest` in the Base Safe, for example 3F's `EnrollMaker` digest.
     * @dev The root must contain the leaf that `BuildMessageLeaf` wrote for this digest. After the deposit runs on
     * Base, give the verifier the logged signature.
     */
    function runBase(string memory manifest, string memory proofs, bytes32 digest)
        public
        virtual
        returns (bytes memory data)
    {
        BaseSafePayloads.Deployment memory deployment = _deployment(manifest);
        data = _manage(deployment, proofs, _single(BaseSafePayloads.approveMessage(deployment, digest)));
        Logs.log(
            string.concat(
                "Approve message on Base\n    safe:",
                vm.toString(deployment.safe),
                "\n    digest:",
                vm.toString(digest),
                "\n    safeMessageHash:",
                vm.toString(BaseSafePayloads.safeMessageHash(deployment.safe, digest)),
                "\n    signature:",
                vm.toString(BaseSafePayloads.aliasSignature(deployment))
            )
        );
    }
}
