// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAdapter} from "./IAdapter.sol";

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

/// @dev Role sentinel allowing anyone to execute an action.
bytes32 constant ANY_ROLE = bytes32(type(uint256).max);

/// @dev Value sentinel committed to a wildcard-value leaf and mask for an action's low 95-bit call value.
uint96 constant ANY_VALUE = (1 << 95) - 1;

/// @dev Flag selecting the wildcard value sentinel for an action leaf.
uint96 constant ANY_VALUE_FLAG = 1 << 95;

interface IMerkleAdapter is IAdapter, IAccessControlEnumerable {
    /// @notice Reverts when calldata and its mask have different lengths.
    error InvalidDataMaskLength();

    /// @notice Reverts when an action is not included in the active Merkle tree.
    /// @param actionIndex Index of the invalid action in the submitted batch.
    error InvalidMerkleProof(uint256 actionIndex);

    /// @notice Reverts when the root does not match the root registry's value for this adapter.
    error InvalidRoot();

    /// @notice Reverts when a managed call consumes reserved idle assets.
    error InsufficientIdleAssets();

    /// @notice Adapter-specific initialization parameters.
    /// @param defaultAdminRoleHolder Initial holder of `DEFAULT_ADMIN_ROLE`.
    struct InitParams {
        address defaultAdminRoleHolder;
    }

    /// @notice A Merkle-authorized call dispatched by the adapter.
    /// @dev `flagsAndValue` packs the authorization flag and call value. Bit 95 makes the value a wildcard in
    ///      the leaf, and the low 95 bits are sent with the call. Exact `(1 << 95) - 1` leaf constraints are
    ///      reserved because they are indistinguishable from the value wildcard. The leaf commits `dataMask`
    ///      together with the masked calldata, so a caller cannot loosen the mask and compensate in `data`.
    /// @param role Role required from the caller, or the all-`0xff` anyone sentinel.
    /// @param target Address called after the batch passes preflight.
    /// @param flagsAndValue Packed value-wildcard flag and low-95-bit native-currency call value.
    /// @param data Calldata supplied to `target`.
    /// @param dataMask Bitmask applied to `data` before the masked result is committed to the leaf.
    /// @param proof Merkle proof for the derived action leaf.
    struct Action {
        bytes32 role;
        address target;
        uint96 flagsAndValue;
        bytes data;
        bytes dataMask;
        bytes32[] proof;
    }

    /// @notice Emitted when the adapter creates its accounting oracle.
    /// @param oracle Address of the created oracle.
    event SetOracle(address indexed oracle);

    /// @notice Emitted when the active Merkle root is set.
    /// @param merkleRoot New active Merkle root.
    event SetMerkleRoot(bytes32 indexed merkleRoot);

    /// @notice Returns the migratable factory used to create the accounting oracle.
    /// @return factory Oracle factory address.
    function ORACLE_FACTORY() external view returns (address);

    /// @notice Returns the protocol registry that publishes candidate Merkle roots.
    /// @return registry Root registry address.
    function ROOT_REGISTRY() external view returns (address registry);

    /// @notice Returns the accounting oracle created for this adapter.
    /// @return oracle_ Accounting oracle address.
    function oracle() external view returns (address);

    /// @notice Returns the active Merkle root used to authorize actions.
    /// @return root Active Merkle root.
    function merkleRoot() external view returns (bytes32);

    function pendingAllocation(uint256 nonce) external view returns (uint256);

    function toDeallocate(uint256 nonce) external view returns (uint256);

    function lastSyncedNonce() external view returns (uint256);

    function deallocatable() external view returns (uint256);

    /// @notice Accepts the root currently published for this adapter.
    /// @param root Published Merkle root, or zero to disable all existing proofs.
    function acceptRoot(bytes32 root) external;

    /// @notice Executes a batch of role-gated, Merkle-authorized actions.
    /// @param actions Actions to preflight and execute atomically.
    /// @return results Return data from each action in positional order.
    function manage(Action[] calldata actions) external returns (bytes[] memory results);
}
