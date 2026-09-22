// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @notice Symbiotic proposes through the registry owner; the curator accepts through the Oracle owner.
/// @dev Both owner addresses can rotate independently without changing accepted workflows or pending proposals.
interface ICREWorkflowRegistry {
    error AlreadyInitialized();
    error InvalidOracle();
    error InvalidCaller();
    error InvalidWorkflow();

    /// @notice Chainlink registration data committed by the provider's proposal.
    struct WorkflowParams {
        string donFamily;
        string binaryUrl;
        string configUrl;
        bytes attributes;
    }

    event ProposeWorkflow(address indexed oracle, bytes32 indexed workflowId, WorkflowParams params);
    event AcceptWorkflow(address indexed oracle, bytes32 indexed workflowId);

    /// @notice Chainlink WorkflowRegistry 2.0.0 on the same chain as the Oracles.
    function CHAINLINK_WORKFLOW_REGISTRY() external view returns (address);

    /// @notice Whether this registry has completed its one-time CRE owner linking.
    function initialized() external view returns (bool);

    /// @notice Last workflow registered for an Oracle by this registry.
    function workflowIds(address oracle) external view returns (bytes32);

    /// @notice Hash of abi.encode(workflowId, params), or zero if no proposal is pending.
    function proposals(address oracle) external view returns (bytes32 proposalHash);

    /// @notice Canonical CRE name: the Oracle's lowercase, 0x-prefixed address.
    /// @dev Each Oracle uses its own name and the fixed tag "default".
    function workflowName(address oracle) external pure returns (string memory);

    /// @notice Proposes an exact ID and registration data; callable only by the registry owner.
    /// @dev A zero ID cancels the proposal without changing the active workflow.
    function proposeWorkflow(address oracle, bytes32 workflowId, WorkflowParams calldata params) external;

    /// @notice Registers the exact proposal; callable only by the Oracle's current owner.
    /// @dev Atomically removes the old registration, registers the new ACTIVE workflow and updates the receiver.
    /// Chainlink sees this registry as the workflow owner. Any failure preserves the old registration and proposal.
    /// Registry ownership transfers remain available and grant no Oracle-owner acceptance authority.
    function acceptWorkflow(address oracle, bytes32 workflowId, WorkflowParams calldata params) external;

    /// @notice Links this registry to the CRE organization once using a Chainlink-signed proof; only registry owner.
    /// @dev A failed link can be retried. A successful link cannot be repeated, including after upstream unlinking.
    function linkOwner(uint256 validityTimestamp, bytes32 proof, bytes calldata signature) external;
}
