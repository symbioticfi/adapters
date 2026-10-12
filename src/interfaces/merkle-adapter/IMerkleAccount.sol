// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";
import {IMulticallable} from "@symbioticfi/core/src/interfaces/common/IMulticallable.sol";

/**
 * @title IMerkleAccount
 * @notice Interface for migratable strategy custody, Merkle authorization and execution.
 */
interface IMerkleAccount is IMigratableEntity, IAccessControlEnumerable, IMulticallable, IERC1271, IERC721Receiver {
    /* ERRORS */

    /**
     * @notice Raised when the capability is already installed on this account.
     */
    error CapabilityAlreadyAdded();

    /**
     * @notice Raised when the capability is not installed on this account.
     */
    error CapabilityNotAdded();

    /**
     * @notice Raised when the registry has not approved this exact capability for this account.
     */
    error CapabilityNotWhitelisted();

    /**
     * @notice Raised when the adapter is not registered in the Merkle adapter factory.
     */
    error InvalidAdapter();

    /**
     * @notice Raised when a signature approval is not a self-call.
     */
    error InvalidCaller();

    /**
     * @notice Raised when calldata and its mask have different lengths.
     */
    error InvalidDataMaskLength();

    /**
     * @notice Raised when a hash plan is empty, its buffer is shorter than one word, or a step
     * reads or writes outside the buffer.
     */
    error InvalidHashPlan();

    /**
     * @notice Raised when an action is not included in the active Merkle tree.
     */
    error InvalidMerkleProof();

    /**
     * @notice Raised when the root does not match the root registry's value for this account.
     */
    error InvalidRoot();

    /**
     * @notice Raised when a selector is already assigned to an installed capability.
     */
    error SelectorAlreadyUsed();

    /**
     * @notice Raised when no capability handles the calldata, including incomplete function selectors.
     */
    error UnknownSelector();

    /* STRUCTS */

    /**
     * @notice Parameters for initializing the strategy account.
     * @dev Wrapped as abi.encode(adapter, abi.encode(InitParams)) by the adapter.
     * The adapter must be registered in MERKLE_ADAPTER_FACTORY.
     * @param defaultAdminRoleHolder Initial holder of DEFAULT_ADMIN_ROLE.
     */
    struct InitParams {
        address defaultAdminRoleHolder;
    }

    /**
     * @notice A call whose derived Merkle leaf is also its required access-control role.
     * @dev The leaf commits `dataMask` together with the masked calldata, so a caller cannot loosen the mask.
     * It also commits a bytes1 value byte: 0x00 for zero native-currency value, 0xff for any nonzero value.
     * Nonzero amounts share a leaf and role.
     * @param target Address called after the batch passes preflight.
     * @param value Caller-supplied native-currency value sent unchanged with the call.
     * @param data Calldata supplied to `target`.
     * @param dataMask Bitmask with 0 for fixed bits and 1 for variable bits; the leaf commits `data & ~dataMask`.
     * @param proof Merkle proof for the derived action leaf.
     */
    struct Action {
        address target;
        uint96 value;
        bytes data;
        bytes dataMask;
        bytes32[] proof;
    }

    /**
     * @notice One hashing step over the fixed-size buffer.
     * @dev Steps run in order over the same buffer, which never changes length, so every offset
     * refers to the original layout. A step's result overwrites the word at destination, which a
     * later step then reads as an already-hashed field. The final step's result is the struct hash.
     * @param offset Start of the range to hash.
     * @param length Byte count to hash; zero hashes an empty value.
     * @param destination Start of the word receiving the result.
     */
    struct Hash {
        uint256 offset;
        uint256 length;
        uint256 destination;
    }

    /* EVENTS */

    /**
     * @notice Emitted when the owner accepts the account's currently published root.
     * @param newRoot New active Merkle root.
     */
    event AcceptRoot(bytes32 indexed newRoot);

    /**
     * @notice Emitted when a batch of Merkle-authorized actions executes.
     * @param actions Actions that passed their proofs and roles, in execution order.
     */
    event Manage(Action[] actions);

    /**
     * @notice Emitted when the owner installs all registered selectors of an approved capability.
     * @param capability Installed implementation address.
     */
    event AddCapability(address indexed capability);

    /**
     * @notice Emitted when the owner removes all registered selectors of an installed capability.
     * @param capability Removed implementation address.
     */
    event RemoveCapability(address indexed capability);

    /**
     * @notice Emitted when the EIP-712 digest of the supplied fields is approved.
     * @dev Carries everything the digest was derived from, so an observer can recompute it without
     * guessing: the plan collapses a copy, and the buffer logged here is the one that was supplied.
     * @param digest Protocol-specific message hash.
     * @param domainSeparator EIP-712 domain separator the struct hash was wrapped with.
     * @param buffer Buffer as supplied, before any step overwrote a destination word.
     * @param plan Ordered hashing steps applied to the supplied buffer.
     */
    event Sign(bytes32 indexed digest, bytes32 indexed domainSeparator, bytes buffer, Hash[] plan);

    /**
     * @notice Emitted when the owner revokes a stored digest approval.
     * @param digest Revoked message hash.
     */
    event RevokeSignature(bytes32 indexed digest);

    /* FUNCTIONS */

    /**
     * @notice Returns the factory that must register the adapter before account initialization.
     * @return factory Merkle adapter factory address.
     */
    function MERKLE_ADAPTER_FACTORY() external view returns (address factory);

    /**
     * @notice Returns the registry of approved capability selectors for this account.
     * @return registry Capabilities registry address.
     */
    function CAPABILITIES_REGISTRY() external view returns (address registry);

    /**
     * @notice Returns the installed implementation for a selector, or zero if no capability is installed for it.
     * @dev Native account and proxy functions take precedence even when their selectors appear in this mapping.
     * @param selector Function selector to look up.
     * @return capability Installed implementation, which may have since been dewhitelisted.
     */
    function capabilityBySelector(bytes4 selector) external view returns (address capability);

    /**
     * @notice Returns all installed capability implementations, in no guaranteed order.
     * @return capabilities Installed implementation addresses.
     */
    function getCapabilities() external view returns (address[] memory capabilities);

    /**
     * @notice Returns a selector copied when a capability was installed.
     * @dev Registry edits do not change this list or the installed routes.
     * @param capability Installed implementation address.
     * @param index Selector index; reverts when out of bounds.
     * @return selector Installed selector at the requested index.
     */
    function capabilitySelectors(address capability, uint256 index) external view returns (bytes4 selector);

    /**
     * @notice Installs the currently whitelisted selectors of a capability for this account.
     * @dev Only the owner may call. Reverts atomically if any selector is assigned to another installed capability.
     * Native account and proxy functions retain precedence over registered capability selectors. Capabilities execute
     * through delegatecall in account storage and must be written for this execution context.
     * @param capability Exact registered implementation address.
     */
    function addCapability(address capability) external;

    /**
     * @notice Removes all locally stored selectors of an installed capability.
     * @dev Only the owner may call. Removal needs no registry call and does not execute
     * capability code, clear its storage, cancel orders, or revoke external token approvals.
     * @param capability Installed implementation to remove.
     */
    function removeCapability(address capability) external;

    /**
     * @notice Returns the protocol registry that publishes candidate Merkle roots.
     * @return registry Root registry address.
     */
    function ROOT_REGISTRY() external view returns (address registry);

    /**
     * @notice Returns the active Merkle root used to authorize actions.
     * @return curRoot Active Merkle root.
     */
    function root() external view returns (bytes32 curRoot);

    /**
     * @notice Accepts the published root or disables Merkle management; only the owner may call.
     * @dev Zero does not require registry approval. Clearing the root does not revoke roles or signed orders.
     * @param newRoot Published Merkle root, or zero to disable all existing proofs.
     */
    function acceptRoot(bytes32 newRoot) external;

    /**
     * @notice Executes a batch of Merkle-authorized actions whose leaf roles are granted to the caller.
     * @dev Each role is keccak256(bytes.concat(keccak256(abi.encode(target, valueByte,
     * keccak256(dataMask), keccak256(maskedData))))), where valueByte is bytes1(0x00) when value is zero
     * and bytes1(0xff) otherwise. Grant or revoke that leaf hash through
     * AccessControlEnumerable. Both membership and every leaf role are checked before the first call.
     * Calls execute from this account, which holds only strategy assets. Reserve custody stays on the paired adapter.
     * @param actions Actions to preflight and execute atomically.
     * @return results Return data from each action in positional order.
     */
    function manage(Action[] calldata actions) external returns (bytes[] memory results);

    /**
     * @notice Returns the adapter bridging vault assets and holding reserves.
     * @return adapterAddress Adapter paired at initialization.
     */
    function adapter() external view returns (address adapterAddress);

    /**
     * @notice Returns whether a digest has an active ERC-1271 approval.
     * @param digest Protocol-specific message hash.
     * @return approved Whether the digest is approved.
     */
    function signatures(bytes32 digest) external view returns (bool approved);

    /**
     * @notice Approves an EIP-712 message through a Merkle-authorized account self-call.
     * @dev The account computes the digest; callers cannot supply an independent message hash.
     * The buffer holds abi.encode(typeHash, field1, ...) with one word reserved for every field that
     * must be hashed, and the plan collapses those fields in place. Each step hashes its range and
     * overwrites the word at its destination, so a later step reads the earlier result as an
     * already-hashed field. The buffer never changes length, so offsets stay fixed for the whole plan.
     * The final step's result is the struct hash, which means a flat structure still needs one step
     * covering the entire buffer. This exposes nested fields to Merkle verification without
     * protocol-specific hashing rules.
     * Leaves must fix the domain, type hashes, complete plan, ABI layout, buffer length and all
     * restricted fields. Only intended runtime fields may vary. Mutable prehashed fields grant
     * control over their entire contents. No validator or capability is needed.
     * ERC-1271 checks the stored digest only and ignores its signature bytes; protocols may pass empty bytes.
     * Expiry, nonce use and settlement conditions are enforced by the consuming protocol.
     * Root or role changes do not revoke saved approvals; the owner calls revokeSignature explicitly.
     * Deferred settlement can spend only account-held assets; vault reserves remain on the adapter.
     * @param domainSeparator EIP-712 domain separator committed by the permission leaf.
     * @param buffer Encoded typed-data buffer, with a reserved word for every field to be hashed.
     * @param plan Ordered hashing steps committed by the permission leaf; at least one is required.
     */
    function sign(bytes32 domainSeparator, bytes calldata buffer, Hash[] calldata plan) external;

    /**
     * @notice Revokes one digest as the account owner.
     * @dev Only the owner may call; Merkle proofs and roles do not authorize revocation.
     * Available even when the root or leaf roles have been cleared. Does not change token allowances or protocol nonces.
     * @param digest Previously approved EIP-712 message hash.
     */
    function revokeSignature(bytes32 digest) external;
}
