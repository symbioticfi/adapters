// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IAdapter} from "./IAdapter.sol";

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

/**
 * @title IMerkleAdapter
 * @notice Interface for MerkleAdapter.
 */
interface IMerkleAdapter is IAdapter, IAccessControlEnumerable {
    /* ERRORS */

    /**
     * @notice Raised when the capability is already installed on this adapter.
     */
    error CapabilityAlreadyAdded();

    /**
     * @notice Raised when the capability is not installed on this adapter.
     */
    error CapabilityNotAdded();

    /**
     * @notice Raised when the registry has not approved this exact capability for this adapter.
     */
    error CapabilityNotWhitelisted();

    /**
     * @notice Raised when releasing underlying would consume reserved idle assets.
     */
    error InsufficientIdleAssets();

    /**
     * @notice Raised when funds are released by anyone other than the paired account.
     */
    error InvalidCaller();

    /**
     * @notice Raised when calldata and its mask have different lengths.
     */
    error InvalidDataMaskLength();

    /**
     * @notice Raised when an action is not included in the active Merkle tree.
     */
    error InvalidMerkleProof();

    /**
     * @notice Raised when the root does not match the root registry's value for this adapter.
     */
    error InvalidRoot();

    /**
     * @notice Raised when a selector is already assigned to an installed capability.
     */
    error SelectorAlreadyUsed();

    /* STRUCTS */

    /**
     * @notice Adapter-specific initialization parameters.
     * @param defaultAdminRoleHolder Initial holder of `DEFAULT_ADMIN_ROLE`.
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

    /* EVENTS */

    /**
     * @notice Emitted when the adapter creates its strategy account.
     * @param account Account that holds positions and executes approved calls.
     */
    event SetAccount(address indexed account);

    /**
     * @notice Emitted when underlying is released to the strategy account.
     * @param amount Underlying transferred to the account.
     */
    event Release(uint256 amount);

    /**
     * @notice Emitted when the adapter creates its accounting oracle.
     * @param oracle Address of the created oracle.
     */
    event SetOracle(address indexed oracle);

    /**
     * @notice Emitted when the active Merkle root is set.
     * @param merkleRoot New active Merkle root.
     */
    event SetMerkleRoot(bytes32 indexed merkleRoot);

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

    /* FUNCTIONS */

    /**
     * @notice Returns the account holding the strategy's positions, approvals and signatures.
     * @return account_ Paired account, permanently bound at initialization.
     */
    function account() external view returns (address account_);

    /**
     * @notice Releases unreserved underlying to the paired account.
     * @dev Only the account may call, normally through an approved manage action. The recipient is fixed.
     * Reverts atomically if the remaining balance cannot cover pending allocations and matured withdrawals.
     * @param amount Underlying to transfer to the account.
     */
    function release(uint256 amount) external;

    /**
     * @notice Returns the registry of approved capability selectors for this adapter.
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
     * @notice Returns whether an exact capability implementation is installed.
     * @dev Installed functions remain active after registry dewhitelisting until the owner removes them.
     * @param capability Implementation address to look up.
     * @return installed Whether the implementation is installed.
     */
    function isCapability(address capability) external view returns (bool installed);

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
     * @notice Returns the number of selectors installed for a capability.
     * @param capability Implementation address.
     * @return length Installed selector count, or zero when not installed.
     */
    function capabilitySelectorsLength(address capability) external view returns (uint256 length);

    /**
     * @notice Installs the currently whitelisted selectors of a capability for this adapter.
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
     * @notice Returns the migratable factory used to create the accounting oracle.
     * @return factory Oracle factory address.
     */
    function ORACLE_FACTORY() external view returns (address);

    /**
     * @notice Returns the protocol registry that publishes candidate Merkle roots.
     * @return registry Root registry address.
     */
    function ROOT_REGISTRY() external view returns (address registry);

    /**
     * @notice Returns the accounting oracle created for this adapter.
     * @return oracle_ Accounting oracle address.
     */
    function oracle() external view returns (address);

    /**
     * @notice Returns the active Merkle root used to authorize actions.
     * @return root Active Merkle root.
     */
    function merkleRoot() external view returns (bytes32);

    /**
     * @notice Returns assets awaiting oracle accounting for an epoch.
     * @param nonce Oracle epoch nonce.
     * @return amount Pending assets in vault-asset units.
     */
    function pendingAllocation(uint256 nonce) external view returns (uint256);

    /**
     * @notice Returns assets requested for release after an oracle epoch.
     * @param nonce Oracle epoch nonce.
     * @return amount Requested assets in vault-asset units.
     */
    function toDeallocate(uint256 nonce) external view returns (uint256);

    /**
     * @notice Returns the last oracle epoch incorporated into deallocation accounting.
     * @return nonce Last synchronized oracle epoch nonce.
     */
    function lastSyncedNonce() external view returns (uint256);

    /**
     * @notice Returns idle assets reserved for deallocation as of the last synchronization.
     * @return amount Reserved assets in vault-asset units.
     */
    function deallocatable() external view returns (uint256);

    /**
     * @notice Returns vault assets reserved for pending allocations and matured withdrawals.
     * @dev Includes withdrawal requests matured at the current oracle epoch even before synchronization.
     * @return amount Reserved assets in vault-asset units.
     */
    function reservedAssets() external view returns (uint256 amount);

    /**
     * @notice Returns assets reserved at an accounting epoch, including pending allocations and matured withdrawals.
     * @dev Oracle uses the next epoch to validate a report before advancing its nonce.
     * @param nonce Accounting epoch at or after lastSyncedNonce.
     * @return amount Reserved assets in vault-asset units.
     */
    function reservedAssetsAt(uint256 nonce) external view returns (uint256 amount);

    /**
     * @notice Returns withdrawals matured at an accounting epoch, including unsynchronized requests.
     * @param nonce Accounting epoch at or after lastSyncedNonce.
     * @return amount Matured withdrawals in vault-asset units.
     */
    function deallocatableAt(uint256 nonce) external view returns (uint256 amount);

    /**
     * @notice Accepts the root currently published for this adapter.
     * @param root Published Merkle root, or zero to disable all existing proofs.
     */
    function acceptRoot(bytes32 root) external;

    /**
     * @notice Executes a batch of Merkle-authorized actions whose leaf roles are granted to the caller.
     * @dev Each role is keccak256(bytes.concat(keccak256(abi.encode(target, valueByte,
     * keccak256(dataMask), keccak256(maskedData))))), where valueByte is bytes1(0x00) when value is zero
     * and bytes1(0xff) otherwise. Grant or revoke that leaf hash through
     * AccessControlEnumerable. Both membership and every leaf role are checked before the first call.
     * Calls execute from the paired account, which holds only strategy assets. Reserve custody stays on this adapter.
     * @param actions Actions to preflight and execute atomically.
     * @return results Return data from each action in positional order.
     */
    function manage(Action[] calldata actions) external returns (bytes[] memory results);
}
