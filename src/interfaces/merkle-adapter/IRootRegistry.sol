// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IRootRegistry
 * @notice Interface for protocol-published adapter Merkle roots.
 */
interface IRootRegistry {
    /* EVENTS */

    /**
     * @notice Emitted when the protocol publishes an adapter root.
     * @param adapter Adapter address.
     * @param root Published Merkle root.
     */
    event SetRoot(address indexed adapter, bytes32 indexed root);

    /* FUNCTIONS */

    /**
     * @notice Returns the root published for an adapter.
     * @param adapter Adapter address.
     * @return root Published Merkle root.
     */
    function roots(address adapter) external view returns (bytes32 root);

    /**
     * @notice Publishes a root for an adapter.
     * @param adapter Adapter address.
     * @param newRoot Merkle root.
     */
    function setRoot(address adapter, bytes32 newRoot) external;
}
