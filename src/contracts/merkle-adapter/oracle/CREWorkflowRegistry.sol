// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ICREOracle} from "../../../interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ICREWorkflowRegistry} from "../../../interfaces/merkle-adapter/oracle/ICREWorkflowRegistry.sol";
import {IChainlinkWorkflowRegistry} from "../../../interfaces/merkle-adapter/oracle/IChainlinkWorkflowRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice Non-upgradeable registry requiring Symbiotic's proposal and the curator's acceptance for CRE registration.
contract CREWorkflowRegistry is Ownable, ICREWorkflowRegistry {
    /// @inheritdoc ICREWorkflowRegistry
    address public immutable CHAINLINK_WORKFLOW_REGISTRY;

    /// @inheritdoc ICREWorkflowRegistry
    bool public initialized;

    /// @inheritdoc ICREWorkflowRegistry
    mapping(address oracle => bytes32 workflowId) public workflowIds;

    /// @inheritdoc ICREWorkflowRegistry
    mapping(address oracle => bytes32 proposalHash) public proposals;

    constructor(address newOwner, address newChainlinkWorkflowRegistry) Ownable(newOwner) {
        CHAINLINK_WORKFLOW_REGISTRY = newChainlinkWorkflowRegistry;
    }

    /// @inheritdoc ICREWorkflowRegistry
    function workflowName(address oracle) public pure returns (string memory) {
        return Strings.toHexString(oracle);
    }

    /// @inheritdoc ICREWorkflowRegistry
    function proposeWorkflow(address oracle, bytes32 newWorkflowId, WorkflowParams calldata params) public onlyOwner {
        if (ICREOracle(oracle).WORKFLOW_REGISTRY() != address(this)) revert InvalidOracle();

        proposals[oracle] = newWorkflowId == bytes32(0) ? bytes32(0) : keccak256(abi.encode(newWorkflowId, params));

        emit ProposeWorkflow(oracle, newWorkflowId, params);
    }

    /// @inheritdoc ICREWorkflowRegistry
    function acceptWorkflow(address oracle, bytes32 newWorkflowId, WorkflowParams calldata params) public {
        if (Ownable(oracle).owner() != msg.sender) revert InvalidCaller();
        if (ICREOracle(oracle).WORKFLOW_REGISTRY() != address(this)) revert InvalidOracle();
        if (newWorkflowId == bytes32(0) || proposals[oracle] != keccak256(abi.encode(newWorkflowId, params))) {
            revert InvalidWorkflow();
        }

        delete proposals[oracle];
        // Track the registration here rather than trusting an upgradeable receiver's claimed previous ID.
        bytes32 previousWorkflowId = workflowIds[oracle];
        workflowIds[oracle] = newWorkflowId;
        IChainlinkWorkflowRegistry registry = IChainlinkWorkflowRegistry(CHAINLINK_WORKFLOW_REGISTRY);
        if (previousWorkflowId != bytes32(0)) registry.deleteWorkflow(previousWorkflowId);
        registry.upsertWorkflow(
            workflowName(oracle),
            "default",
            newWorkflowId,
            IChainlinkWorkflowRegistry.WorkflowStatus.ACTIVE,
            params.donFamily,
            params.binaryUrl,
            params.configUrl,
            params.attributes,
            false
        );
        ICREOracle(oracle).setWorkflowId(newWorkflowId);

        emit AcceptWorkflow(oracle, newWorkflowId);
    }

    /// @inheritdoc ICREWorkflowRegistry
    function linkOwner(uint256 validityTimestamp, bytes32 proof, bytes calldata signature) public onlyOwner {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        IChainlinkWorkflowRegistry(CHAINLINK_WORKFLOW_REGISTRY).linkOwner(validityTimestamp, proof, signature);
    }
}
