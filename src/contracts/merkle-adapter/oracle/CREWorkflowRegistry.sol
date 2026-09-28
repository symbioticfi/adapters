// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ICREWorkflowRegistry} from "../../../interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {IChainlinkWorkflowRegistry} from "../../../interfaces/merkle-adapter/oracle/IChainlinkWorkflowRegistry.sol";

import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title CREWorkflowRegistry
/// @notice Contract for CRE registration requiring Symbiotic's proposal and the curator's acceptance.
contract CREWorkflowRegistry is Ownable, ICREWorkflowRegistry {
    using Bytes for bytes;

    /* IMMUTABLES */

    /// @inheritdoc ICREWorkflowRegistry
    address public immutable CHAINLINK_WORKFLOW_REGISTRY;

    /* STATE VARIABLES */

    /// @inheritdoc ICREWorkflowRegistry
    mapping(address oracle => bytes32 workflowId) public workflowId;

    /// @inheritdoc ICREWorkflowRegistry
    mapping(address oracle => bytes32 workflowId) public proposedWorkflowId;

    /// @inheritdoc ICREWorkflowRegistry
    mapping(address oracle => WorkflowParams params) public proposedWorkflowParams;

    /* CONSTRUCTOR */

    constructor(address newOwner, address newChainlinkWorkflowRegistry) Ownable(newOwner) {
        CHAINLINK_WORKFLOW_REGISTRY = newChainlinkWorkflowRegistry;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ICREWorkflowRegistry
    function proposeWorkflow(address oracle, bytes32 newWorkflowId, WorkflowParams calldata newParams)
        public
        onlyOwner
    {
        proposedWorkflowId[oracle] = newWorkflowId;
        if (newWorkflowId == bytes32(0)) delete proposedWorkflowParams[oracle];
        else proposedWorkflowParams[oracle] = newParams;

        emit ProposeWorkflow(oracle, newWorkflowId, newParams);
    }

    /// @inheritdoc ICREWorkflowRegistry
    function acceptWorkflow(address oracle, bytes32 newWorkflowId, WorkflowParams calldata newParams) public {
        if (Ownable(oracle).owner() != msg.sender) revert InvalidCaller();
        if (
            newWorkflowId == bytes32(0) || proposedWorkflowId[oracle] != newWorkflowId
                || !abi.encode(proposedWorkflowParams[oracle]).equal(abi.encode(newParams))
        ) revert InvalidWorkflow();

        delete proposedWorkflowId[oracle];
        delete proposedWorkflowParams[oracle];
        IChainlinkWorkflowRegistry(CHAINLINK_WORKFLOW_REGISTRY)
            .upsertWorkflow(
                Strings.toHexString(oracle),
                "default",
                newWorkflowId,
                IChainlinkWorkflowRegistry.WorkflowStatus.ACTIVE,
                newParams.donFamily,
                newParams.binaryUrl,
                newParams.configUrl,
                newParams.attributes,
                false
            );
        workflowId[oracle] = newWorkflowId;
        emit AcceptWorkflow(oracle, newWorkflowId);
    }

    /// @inheritdoc ICREWorkflowRegistry
    function linkOwner(uint48 validityTimestamp, bytes32 proof, bytes calldata signature) public onlyOwner {
        IChainlinkWorkflowRegistry(CHAINLINK_WORKFLOW_REGISTRY).linkOwner(validityTimestamp, proof, signature);
    }
}
