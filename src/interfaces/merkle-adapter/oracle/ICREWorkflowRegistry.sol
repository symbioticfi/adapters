// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IChainlinkWorkflowRegistry} from "./IChainlinkWorkflowRegistry.sol";

/**
 * @title ICREWorkflowRegistry
 * @notice Interface for CRE workflow registration proposed by Symbiotic and accepted by each Oracle's owner.
 * @dev Symbiotic proposes through the registry owner; the curator accepts through the Oracle owner.
 * Both owner addresses can rotate independently without changing accepted workflows or pending proposals.
 */
interface ICREWorkflowRegistry {
    /* ERRORS */

    /**
     * @notice Raised when the caller is not the Oracle's current owner.
     */
    error InvalidCaller();

    /**
     * @notice Raised when the workflow ID is zero or the proposal does not match.
     */
    error InvalidWorkflow();

    /* STRUCTS */

    /**
     * @notice Chainlink registration data committed by the provider's proposal.
     * @param tag Tag selecting an existing registration or an unused replacement slot.
     * @param status Initial execution status, or the existing status when reusing a tag.
     * @param donFamily DON family that executes the workflow.
     * @param binaryUrl URL of the compiled workflow binary.
     * @param configUrl URL of the workflow configuration.
     * @param attributes Additional Chainlink registration attributes.
     */
    struct WorkflowParams {
        string tag;
        IChainlinkWorkflowRegistry.WorkflowStatus status;
        string donFamily;
        string binaryUrl;
        string configUrl;
        bytes attributes;
    }

    /* EVENTS */

    /**
     * @notice Emitted when the registry owner proposes or cancels a workflow for an Oracle.
     * @param oracle Oracle whose workflow is proposed.
     * @param workflowId Proposed workflow ID, or zero when the proposal is cancelled.
     * @param params Registration data committed by the proposal, or default fields on cancellation.
     */
    event ProposeWorkflow(address indexed oracle, bytes32 indexed workflowId, WorkflowParams params);

    /**
     * @notice Emitted when the Oracle owner accepts and registers the proposed workflow.
     * @param oracle Oracle whose workflow is accepted.
     * @param workflowId Registered workflow ID.
     */
    event AcceptWorkflow(address indexed oracle, bytes32 indexed workflowId);

    /* FUNCTIONS */

    /**
     * @notice Returns the Chainlink WorkflowRegistry 2.0.0 on the same chain as the Oracles.
     */
    function CHAINLINK_WORKFLOW_REGISTRY() external view returns (address);

    /**
     * @notice Returns the accepted workflow ID for an oracle, or zero before its first acceptance.
     */
    function workflowId(address oracle) external view returns (bytes32);

    /**
     * @notice Returns the pending workflow ID, or zero if no proposal is pending.
     */
    function proposedWorkflowId(address oracle) external view returns (bytes32);

    /**
     * @notice Returns the complete pending registration data, or default fields if no proposal is pending.
     */
    function proposedWorkflowParams(address oracle)
        external
        view
        returns (
            string memory tag,
            IChainlinkWorkflowRegistry.WorkflowStatus status,
            string memory donFamily,
            string memory binaryUrl,
            string memory configUrl,
            bytes memory attributes
        );

    /**
     * @notice Proposes an exact ID and registration data; only the registry owner may call this.
     * @dev Stores the full ID and parameters. A zero ID clears both without changing the active workflow.
     * @param oracle Oracle whose workflow is proposed.
     * @param newWorkflowId Proposed workflow ID, or zero to cancel the pending proposal.
     * @param newParams Registration data committed by the proposal.
     */
    function proposeWorkflow(address oracle, bytes32 newWorkflowId, WorkflowParams calldata newParams) external;

    /**
     * @notice Registers the exact proposal; only the Oracle's current owner may call this.
     * @dev Upserts the workflow using the Oracle's lowercase, 0x-prefixed address as its name,
     * the proposed tag and status, and stores the accepted ID for the oracle to read during delivery.
     * The supplied ID and all parameters must match the stored proposal. Acceptance clears both stored values.
     * Reusing a tag requires a fresh ID, the same DON and status. An unused tag creates a replacement
     * and pauses previous active registrations for this Oracle. ACTIVE replacements require upstream quota.
     * Use an unused tag and ID to change a registration's status or DON.
     * Chainlink sees this registry as the workflow owner.
     * A registration failure preserves the old registration, accepted ID and proposal.
     * Registry ownership transfers remain available and grant no Oracle-owner acceptance authority.
     * @param oracle Oracle whose current owner accepts the proposal.
     * @param newWorkflowId Proposed workflow ID to register and accept.
     * @param newParams Registration data matching the stored proposal.
     */
    function acceptWorkflow(address oracle, bytes32 newWorkflowId, WorkflowParams calldata newParams) external;

    /**
     * @notice Links this registry to the CRE organization using a Chainlink-signed proof; only the registry owner.
     * @dev Chainlink allows one active link per owner and rejects reused proofs. After an upstream unlink,
     * which deletes every registration, the owner can relink with a fresh proof and accept workflows again.
     */
    function linkOwner(uint48 validityTimestamp, bytes32 proof, bytes calldata signature) external;
}
