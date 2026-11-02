// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IChainlinkWorkflowRegistry
 * @notice Interface for the used entry points of Chainlink's on-chain WorkflowRegistry 2.0.0.
 * @dev https://github.com/smartcontractkit/chainlink-evm/blob/2a2b38e8b74479054db92ab911521d60278c3d78/contracts/cre/src/v2/WorkflowRegistry.sol
 */
interface IChainlinkWorkflowRegistry {
    /* STRUCTS */

    /**
     * @notice Workflow execution status in the upstream registry.
     */
    enum WorkflowStatus {
        ACTIVE,
        PAUSED
    }

    /**
     * @notice Registered workflow metadata, including its assigned DON family.
     * @param workflowId Globally unique workflow identifier.
     * @param owner Address that registered the workflow.
     * @param createdAt Timestamp when the registration was created.
     * @param status Current workflow execution status.
     * @param workflowName Name identifying the workflow within its owner's registrations.
     * @param binaryUrl URL of the compiled workflow binary.
     * @param configUrl URL of the workflow configuration.
     * @param tag Tag distinguishing registrations with the same owner and name.
     * @param attributes Additional workflow metadata.
     * @param donFamily DON family assigned to the workflow.
     */
    struct WorkflowMetadataView {
        bytes32 workflowId;
        address owner;
        uint64 createdAt;
        WorkflowStatus status;
        string workflowName;
        string binaryUrl;
        string configUrl;
        string tag;
        bytes attributes;
        string donFamily;
    }

    /* FUNCTIONS */

    /**
     * @notice Returns workflow metadata for the owner, name and tag, or empty fields if no registration exists.
     * @param owner Address that registered the workflow.
     * @param workflowName Case-sensitive workflow name.
     * @param tag Tag identifying the registration.
     */
    function getWorkflow(address owner, string calldata workflowName, string calldata tag)
        external
        view
        returns (WorkflowMetadataView memory);

    /**
     * @notice Creates or updates a workflow registered by the caller under the supplied name and tag.
     * @dev The caller must be linked and the workflow ID must be nonzero and unused.
     * Updating an existing registration preserves its status and DON family.
     * @param workflowName Name identifying the workflow within the caller's registrations.
     * @param tag Tag distinguishing registrations with the same owner and name.
     * @param workflowId New globally unique workflow identifier.
     * @param status Initial status, or the existing status when updating a registration.
     * @param donFamily Assigned DON family, which must match when updating a registration.
     * @param binaryUrl Required URL of the compiled workflow binary.
     * @param configUrl Optional URL of the workflow configuration.
     * @param attributes Optional additional workflow metadata.
     * @param keepAlive Whether to keep other workflows with the same owner and name active when creating a registration.
     */
    function upsertWorkflow(
        string calldata workflowName,
        string calldata tag,
        bytes32 workflowId,
        WorkflowStatus status,
        string calldata donFamily,
        string calldata binaryUrl,
        string calldata configUrl,
        bytes calldata attributes,
        bool keepAlive
    ) external;

    /**
     * @notice Deletes a workflow owned by the linked caller.
     * @param workflowId Identifier of the registration to delete.
     */
    function deleteWorkflow(bytes32 workflowId) external;

    /**
     * @notice Links the caller as a workflow owner using a proof signed by an allowed upstream signer.
     * @dev Rejects expired or reused proofs and callers that are already linked.
     * @param validityTimestamp Latest timestamp at which the proof is valid.
     * @param proof Unique ownership proof.
     * @param signature Signature binding the caller, proof and validity timestamp.
     */
    function linkOwner(uint256 validityTimestamp, bytes32 proof, bytes calldata signature) external;
}
