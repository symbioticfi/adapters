// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @notice Used entry points of Chainlink's on-chain WorkflowRegistry 2.0.0.
/// @dev https://github.com/smartcontractkit/chainlink-evm/blob/2a2b38e8b74479054db92ab911521d60278c3d78/contracts/cre/src/v2/WorkflowRegistry.sol
interface IChainlinkWorkflowRegistry {
    enum WorkflowStatus {
        ACTIVE,
        PAUSED
    }

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

    function deleteWorkflow(bytes32 workflowId) external;

    function linkOwner(uint256 validityTimestamp, bytes32 proof, bytes calldata signature) external;
}
