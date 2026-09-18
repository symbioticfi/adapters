// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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
     * @notice Raised when a managed call consumes reserved idle assets.
     */
    error InsufficientIdleAssets();

    /**
     * @notice Raised when calldata and its mask have different lengths.
     */
    error InvalidDataMaskLength();

    /**
     * @notice Raised when a leaf budget repeats an asset or identifies a token without code.
     */
    error InvalidLeafAsset();

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

    /**
     * @notice Raised when no capability handles the calldata, including incomplete function selectors.
     */
    error UnknownSelector();

    /* STRUCTS */

    /**
     * @notice Adapter-specific initialization parameters.
     * @param defaultAdminRoleHolder Initial holder of `DEFAULT_ADMIN_ROLE`.
     */
    struct InitParams {
        address defaultAdminRoleHolder;
    }

    /**
     * @notice Maximum net outflow of one asset for a leaf during each fixed period.
     * @param asset Token to monitor; zero denotes native currency.
     * @param maxAssets Maximum asset base units per period; zero prohibits net outflows.
     * @param duration Nonzero period length in seconds.
     */
    struct LeafLimit {
        address asset;
        uint256 maxAssets;
        uint256 duration;
    }

    /**
     * @notice A call whose derived Merkle leaf is also its required access-control role.
     * @dev The leaf commits `dataMask` together with the masked calldata, so a caller cannot loosen the mask.
     * It also commits a bytes1 value byte: 0x00 for zero native-currency value, 0xff for any nonzero value.
     * Nonzero amounts share a leaf and role; configured native-currency budgets still apply.
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
     * @notice Emitted when the adapter creates its accounting oracle.
     * @param oracle Address of the created oracle.
     */
    event SetOracle(address indexed oracle);

    /**
     * @notice Emitted when the owner replaces a leaf's array of asset budgets.
     * @param leaf Merkle leaf and corresponding access-control role.
     * @param limits New asset budgets; an empty array removes balance monitoring for this leaf.
     */
    event SetLeafLimits(bytes32 indexed leaf, LeafLimit[] limits);

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
     * @notice Returns the fixed curator registry of accepted protocol proposals and immutable selector lists.
     * @return registry Curator's capabilities registry address.
     */
    function CAPABILITIES_REGISTRY() external view returns (address registry);

    /**
     * @notice Returns the installed implementation for a selector, or zero if no capability is installed for it.
     * @dev Native adapter and proxy functions take precedence even when their selectors appear in this mapping.
     * @param selector Function selector to look up.
     * @return capability Installed implementation, which may have since been dewhitelisted.
     */
    function capabilityForSelector(bytes4 selector) external view returns (address capability);

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
     * @notice Installs all registry-defined selectors of a capability proposed and accepted for this adapter.
     * @dev Only the owner may call. Reverts atomically if any selector is assigned to another installed capability.
     * Native adapter and proxy functions retain precedence over registered capability selectors. Capabilities execute
     * through delegatecall in adapter storage and must be written for this execution context.
     * @param capability Exact registered implementation address.
     */
    function addCapability(address capability) external;

    /**
     * @notice Removes all registry-defined selectors of an installed capability.
     * @dev Only the owner may call. Removal remains available after dewhitelisting and does not execute
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
     * @notice Accepts the root currently published for this adapter.
     * @param root Published Merkle root, or zero to disable all existing proofs.
     */
    function acceptRoot(bytes32 root) external;

    /**
     * @notice Sets the monitored assets and budgets for a leaf, callable only by the owner.
     * @dev Limits charge net balance decreases around each individual call, not deferred spending
     * from approvals or signatures. Increases do not refund usage. Reconfiguration, reordering,
     * and removing/readding an asset preserve its unexpired usage. Assets omitted from the array
     * are not monitored. A duration change carries usage into a new period starting now.
     * @param leaf Merkle leaf and corresponding role.
     * @param newLimits Array of distinct assets and their budgets.
     */
    function setLeafLimits(bytes32 leaf, LeafLimit[] calldata newLimits) external;

    /**
     * @notice Returns the configured array of asset budgets for a leaf.
     * @param leaf Merkle leaf to query.
     * @return limits Active budgets in configuration order.
     */
    function getLeafLimits(bytes32 leaf) external view returns (LeafLimit[] memory limits);

    /**
     * @notice Returns a leaf asset's saved budget and usage, including removed configurations.
     * @dev Expired usage is reset lazily. getLeafLimits identifies which assets are monitored.
     * @param leaf Merkle leaf to query.
     * @param asset Token address, or zero for native currency.
     * @return maxAssets Maximum outflow per period.
     * @return duration Period length in seconds.
     * @return periodStart Start of the last recorded period.
     * @return spent Net outflows consumed during that period.
     */
    function leafAssetLimits(bytes32 leaf, address asset)
        external
        view
        returns (uint256 maxAssets, uint256 duration, uint256 periodStart, uint256 spent);

    /**
     * @notice Executes a batch of Merkle-authorized actions whose leaf roles are granted to the caller.
     * @dev Each role is keccak256(bytes.concat(keccak256(abi.encode(target, valueByte,
     * keccak256(dataMask), keccak256(maskedData))))), where valueByte is bytes1(0x00) when value is zero
     * and bytes1(0xff) otherwise. Grant or revoke that leaf hash through
     * AccessControlEnumerable. Both membership and every leaf role are checked before the first call.
     * Configured asset budgets are checked after each call. The entire batch reverts on an exceeded
     * budget or if its final vault-asset balance cannot cover pending allocations and deallocations.
     * @param actions Actions to preflight and execute atomically.
     * @return results Return data from each action in positional order.
     */
    function manage(Action[] calldata actions) external returns (bytes[] memory results);
}
