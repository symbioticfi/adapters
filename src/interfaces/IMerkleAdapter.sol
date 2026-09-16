// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAdapter} from "./IAdapter.sol";

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

/// @dev Value sentinel committed to a wildcard-value leaf and mask for an action's low 95-bit call value.
uint96 constant ANY_VALUE = (1 << 95) - 1;

/// @dev Flag selecting the wildcard value sentinel for an action leaf.
uint96 constant ANY_VALUE_FLAG = 1 << 95;

interface IMerkleAdapter is IAdapter, IAccessControlEnumerable {
    /// @notice Reverts when the capability is already installed on this adapter.
    error CapabilityAlreadyAdded();

    /// @notice Reverts when the capability is not installed on this adapter.
    error CapabilityNotAdded();

    /// @notice Reverts when the registry has not approved this exact capability for this adapter.
    error CapabilityNotWhitelisted();

    /// @notice Reverts when the capability registry is not a deployed contract.
    error InvalidCapabilitiesRegistry();

    /// @notice Reverts when calldata and its mask have different lengths.
    error InvalidDataMaskLength();

    /// @notice Reverts when an action is not included in the active Merkle tree.
    /// @param actionIndex Index of the invalid action in the submitted batch.
    error InvalidMerkleProof(uint256 actionIndex);

    /// @notice Reverts when the root does not match the root registry's value for this adapter.
    error InvalidRoot();

    /// @notice Reverts when a managed call consumes reserved idle assets.
    error InsufficientIdleAssets();

    /// @notice Reverts when a capability selector conflicts with the adapter, its proxy, or another capability.
    /// @param selector Function selector that is already occupied.
    error SelectorAlreadyUsed(bytes4 selector);

    /// @notice Reverts when no capability handles the calldata, including incomplete function selectors.
    /// @param selector Unhandled function selector.
    error UnknownSelector(bytes4 selector);

    /// @notice Adapter-specific initialization parameters.
    /// @param defaultAdminRoleHolder Initial holder of `DEFAULT_ADMIN_ROLE`.
    struct InitParams {
        address defaultAdminRoleHolder;
    }

    /// @notice A call whose derived Merkle leaf is also its required access-control role.
    /// @dev `flagsAndValue` packs the authorization flag and call value. Bit 95 makes the value a wildcard in
    ///      the leaf, and the low 95 bits are sent with the call. Exact `(1 << 95) - 1` leaf constraints are
    ///      reserved because they are indistinguishable from the value wildcard. The leaf commits `dataMask`
    ///      together with the masked calldata, so a caller cannot loosen the mask and compensate in `data`.
    /// @param target Address called after the batch passes preflight.
    /// @param flagsAndValue Packed value-wildcard flag and low-95-bit native-currency call value.
    /// @param data Calldata supplied to `target`.
    /// @param dataMask Bitmask applied to `data` before the masked result is committed to the leaf.
    /// @param proof Merkle proof for the derived action leaf.
    struct Action {
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

    /// @notice Emitted when the owner installs all registered selectors of an approved capability.
    /// @param capability Installed implementation address.
    event AddCapability(address indexed capability);

    /// @notice Emitted when the owner removes all registered selectors of an installed capability.
    /// @param capability Removed implementation address.
    event RemoveCapability(address indexed capability);

    /// @notice Returns the fixed curator registry of accepted protocol proposals and immutable selector lists.
    /// @return registry Curator's capabilities registry address.
    function CAPABILITIES_REGISTRY() external view returns (address registry);

    /// @notice Returns the installed implementation for a selector, or zero if no capability is installed for it.
    /// @dev Native adapter and proxy functions are reserved and do not appear in this mapping.
    /// @param selector Function selector to look up.
    /// @return capability Installed implementation, which may have since been dewhitelisted.
    function capabilityForSelector(bytes4 selector) external view returns (address capability);

    /// @notice Returns whether an exact capability implementation is installed.
    /// @dev Installed functions remain active after registry dewhitelisting until the owner removes them.
    /// @param capability Implementation address to look up.
    /// @return installed Whether the implementation is installed.
    function isCapability(address capability) external view returns (bool installed);

    /// @notice Returns all installed capability implementations, in no guaranteed order.
    /// @return capabilities Installed implementation addresses.
    function getCapabilities() external view returns (address[] memory capabilities);

    /// @notice Installs all registry-defined selectors of a capability proposed and accepted for this adapter.
    /// @dev Only the owner may call. Reverts atomically if any selector is occupied. Capabilities execute
    ///      through delegatecall in adapter storage and must be written for this execution context.
    /// @param capability Exact registered implementation address.
    function addCapability(address capability) external;

    /// @notice Removes all registry-defined selectors of an installed capability.
    /// @dev Only the owner may call. Removal remains available after dewhitelisting and does not execute
    ///      capability code, clear its storage, cancel orders, or revoke external token approvals.
    /// @param capability Installed implementation to remove.
    function removeCapability(address capability) external;

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

    /// @notice Executes a batch of Merkle-authorized actions whose leaf roles are granted to the caller.
    /// @dev Each role is keccak256(bytes.concat(keccak256(abi.encode(target, valueConstraint,
    ///      keccak256(dataMask), keccak256(maskedData))))). Grant or revoke that leaf hash through
    ///      AccessControl. Both membership and every leaf role are checked before the first call.
    /// @param actions Actions to preflight and execute atomically.
    /// @return results Return data from each action in positional order.
    function manage(Action[] calldata actions) external returns (bytes[] memory results);
}
