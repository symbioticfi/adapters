// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IRootRegistry
 * @notice Interface for protocol-published account Merkle roots.
 */
interface IRootRegistry {
    /* EVENTS */

    /**
     * @notice Emitted when the protocol publishes an account root.
     * @param account Adapter address.
     * @param root Published Merkle root.
     */
    event SetRoot(address indexed account, bytes32 indexed root);

    /* FUNCTIONS */

    /**
     * @notice Returns the root published for an account.
     * @param account Adapter address.
     * @return root Published Merkle root.
     */
    function roots(address account) external view returns (bytes32 root);

    /**
     * @notice Publishes a root for an account.
     * @param account Adapter address.
     * @param newRoot Merkle root.
     */
    function setRoot(address account, bytes32 newRoot) external;
}
