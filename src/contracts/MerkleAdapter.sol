// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Adapter} from "./Adapter.sol";

import {AssetRateLimits} from "./merkle-adapter/libraries/AssetRateLimits.sol";
import {MerkleAdapterVerifier} from "./merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IAdapter} from "../interfaces/IAdapter.sol";
import {IAssetRateLimits} from "../interfaces/merkle-adapter/IAssetRateLimits.sol";
import {ICapabilitiesRegistry} from "../interfaces/merkle-adapter/ICapabilitiesRegistry.sol";
import {IMerkleAdapterOracle} from "../interfaces/merkle-adapter/IMerkleAdapterOracle.sol";
import {IMerkleAdapter} from "../interfaces/IMerkleAdapter.sol";
import {IRootRegistry} from "../interfaces/merkle-adapter/IRootRegistry.sol";

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {IMigratablesFactory} from "@symbioticfi/core/src/interfaces/common/IMigratablesFactory.sol";

/// @title MerkleAdapter
/// @notice Adapter contract whose Merkle-proven call permissions each serve as an enumerable access-control role.
contract MerkleAdapter is Adapter, AccessControlEnumerableUpgradeable, IMerkleAdapter {
    using Address for address;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    using AssetRateLimits for IAssetRateLimits.AssetLimit;

    /* IMMUTABLES */

    /// @inheritdoc IMerkleAdapter
    address public immutable override ORACLE_FACTORY;

    /// @inheritdoc IMerkleAdapter
    address public immutable override ROOT_REGISTRY;

    /// @inheritdoc IMerkleAdapter
    address public immutable override CAPABILITIES_REGISTRY;

    /* STATE VARIABLES */

    /// @inheritdoc IMerkleAdapter
    address public override oracle;

    /// @inheritdoc IMerkleAdapter
    bytes32 public override merkleRoot;

    /// @inheritdoc IMerkleAdapter
    mapping(uint256 nonce => uint256 amount) public pendingAllocation;

    /// @inheritdoc IMerkleAdapter
    mapping(uint256 nonce => uint256 amount) public toDeallocate;

    /// @inheritdoc IMerkleAdapter
    uint256 public lastSyncedNonce;

    /// @inheritdoc IMerkleAdapter
    uint256 public deallocatable;

    /// @inheritdoc IMerkleAdapter
    mapping(bytes4 selector => address capability) public override capabilityForSelector;

    /// @dev Implementation addresses installed by this adapter's owner.
    EnumerableSet.AddressSet private _capabilities;

    /// @dev Ordered array of monitored assets for each leaf.
    mapping(bytes32 leaf => address[] assets) private _leafAssets;

    /// @inheritdoc IMerkleAdapter
    mapping(bytes32 leaf => mapping(address asset => IAssetRateLimits.AssetLimit limit)) public leafAssetLimits;

    /* CONSTRUCTOR */

    /// @dev Initializes the immutable factory dependencies for the implementation.
    constructor(
        address newVaultFactory,
        address newAdapterFactory,
        address newOracleFactory,
        address newRootRegistry,
        address newCapabilitiesRegistry
    ) Adapter(newVaultFactory, newAdapterFactory) {
        ORACLE_FACTORY = newOracleFactory;
        ROOT_REGISTRY = newRootRegistry;
        CAPABILITIES_REGISTRY = newCapabilitiesRegistry;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IMerkleAdapter
    function getCapabilities() public view override returns (address[] memory) {
        return _capabilities.values();
    }

    /// @inheritdoc IMerkleAdapter
    function addCapability(address capability) public override onlyOwner {
        if (!ICapabilitiesRegistry(CAPABILITIES_REGISTRY).isWhitelisted(address(this), capability)) {
            revert CapabilityNotWhitelisted();
        }

        if (!_capabilities.add(capability)) revert CapabilityAlreadyAdded();

        bytes4[] memory selectors = ICapabilitiesRegistry(CAPABILITIES_REGISTRY).getCapabilitySelectors(capability);
        for (uint256 i; i < selectors.length; ++i) {
            bytes4 selector = selectors[i];
            if (capabilityForSelector[selector] != address(0)) revert SelectorAlreadyUsed();

            capabilityForSelector[selector] = capability;
        }
        emit AddCapability(capability);
    }

    /// @inheritdoc IMerkleAdapter
    function removeCapability(address capability) public override onlyOwner {
        if (!_capabilities.remove(capability)) revert CapabilityNotAdded();

        bytes4[] memory selectors = ICapabilitiesRegistry(CAPABILITIES_REGISTRY).getCapabilitySelectors(capability);
        for (uint256 i; i < selectors.length; ++i) {
            delete capabilityForSelector[selectors[i]];
        }
        emit RemoveCapability(capability);
    }

    /// @inheritdoc IMerkleAdapter
    function acceptRoot(bytes32 root) public override onlyOwner {
        if (IRootRegistry(ROOT_REGISTRY).roots(address(this)) != root) revert InvalidRoot();

        merkleRoot = root;
        emit SetMerkleRoot(root);
    }

    /// @inheritdoc IMerkleAdapter
    function setLeafLimits(bytes32 leaf, LeafLimit[] calldata newLimits) public onlyOwner {
        delete _leafAssets[leaf];
        for (uint256 i; i < newLimits.length; ++i) {
            address asset = newLimits[i].asset;
            if (asset != address(0) && asset.code.length == 0) revert InvalidLeafAsset();

            for (uint256 j; j < i; ++j) {
                if (asset == newLimits[j].asset) revert InvalidLeafAsset();
            }
            leafAssetLimits[leaf][asset].configure(newLimits[i].maxAssets, newLimits[i].duration);
            _leafAssets[leaf].push(asset);
        }
        emit SetLeafLimits(leaf, newLimits);
    }

    /// @inheritdoc IMerkleAdapter
    function getLeafLimits(bytes32 leaf) public view returns (LeafLimit[] memory limits) {
        address[] storage assets = _leafAssets[leaf];
        limits = new LeafLimit[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            IAssetRateLimits.AssetLimit storage limit = leafAssetLimits[leaf][assets[i]];
            limits[i] = LeafLimit(assets[i], limit.maxAssets, limit.duration);
        }
    }

    /// @inheritdoc IMerkleAdapter
    function manage(Action[] calldata actions) public override nonReentrant returns (bytes[] memory results) {
        bytes32 root = merkleRoot;
        bytes32[] memory leaves = new bytes32[](actions.length);

        for (uint256 i; i < actions.length; ++i) {
            Action calldata action = actions[i];
            bytes32 leaf = MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask);
            if (!MerkleProof.verifyCalldata(action.proof, root, leaf)) revert InvalidMerkleProof();

            _checkRole(leaf);
            leaves[i] = leaf;
        }

        results = new bytes[](actions.length);
        for (uint256 i; i < actions.length; ++i) {
            Action calldata action = actions[i];
            address[] memory assets = _leafAssets[leaves[i]];
            uint256[] memory balances = new uint256[](assets.length);
            for (uint256 j; j < assets.length; ++j) {
                balances[j] =
                    assets[j] == address(0) ? address(this).balance : IERC20(assets[j]).balanceOf(address(this));
            }
            results[i] = action.target.functionCallWithValue(action.data, action.value);
            for (uint256 j; j < assets.length; ++j) {
                uint256 balance =
                    assets[j] == address(0) ? address(this).balance : IERC20(assets[j]).balanceOf(address(this));
                if (balance < balances[j]) {
                    leafAssetLimits[leaves[i]][assets[j]].consume(balances[j] - balance);
                }
            }
        }
        uint256 nonce = _sync();
        if (freeAssets() < deallocatable + pendingAllocation[nonce] + pendingAllocation[nonce + 1]) {
            revert InsufficientIdleAssets();
        }
    }

    /// @inheritdoc IMerkleAdapter
    function isCapability(address capability) public view override returns (bool) {
        return _capabilities.contains(capability);
    }

    /// @inheritdoc IAdapter
    function totalAssets() public view override(Adapter, IAdapter) returns (uint256) {
        uint256 nonce = IMerkleAdapterOracle(oracle).nonce();
        return IMerkleAdapterOracle(oracle).totalAssets() + pendingAllocation[nonce] + pendingAllocation[nonce + 1]
            + _deallocatableAt(nonce);
    }

    /// @inheritdoc IAdapter
    function deallocate(uint256 amount) public override(Adapter, IAdapter) onlyDelegator returns (uint256 deallocated) {
        _sync();
        deallocated = Math.min(amount, deallocatable);
        deallocatable -= deallocated;
    }

    /* INTERNAL FUNCTIONS */

    function _allocate(uint256 amount) internal override returns (uint256 allocated) {
        uint256 epoch = _sync() + 1;
        uint256 matched = Math.min(amount, toDeallocate[epoch]);
        toDeallocate[epoch] -= matched;
        allocated = amount - matched;
        pendingAllocation[epoch] += allocated;
    }

    function _requestDeallocate(uint256 amount) internal override {
        uint256 nonce = _sync();
        amount = amount.saturatingSub(toDeallocate[nonce]);
        uint256 pending = pendingAllocation[nonce + 1];
        deallocatable += Math.min(amount, pending);
        pendingAllocation[nonce + 1] = pending.saturatingSub(amount);
        toDeallocate[nonce + 1] = amount.saturatingSub(pending);
    }

    function _sync() internal returns (uint256 nonce) {
        nonce = IMerkleAdapterOracle(oracle).nonce();
        if (nonce > lastSyncedNonce) {
            deallocatable = _deallocatableAt(nonce);
            lastSyncedNonce = nonce;
        }
    }

    function _deallocatableAt(uint256 nonce) internal view returns (uint256) {
        uint256 previous = lastSyncedNonce;
        return deallocatable + (nonce > previous ? toDeallocate[previous] : 0)
            + (nonce > previous + 1 ? toDeallocate[previous + 1] : 0);
    }

    /// @dev Initializes the default admin and the adapter's accounting oracle.
    function __initialize(address, bytes memory data) internal override {
        IMerkleAdapter.InitParams memory params = abi.decode(data, (IMerkleAdapter.InitParams));
        if (params.defaultAdminRoleHolder != address(0)) {
            _grantRole(DEFAULT_ADMIN_ROLE, params.defaultAdminRoleHolder);
        }
        oracle = IMigratablesFactory(ORACLE_FACTORY)
            .create(IMigratablesFactory(ORACLE_FACTORY).lastVersion(), owner(), abi.encode(address(this)));
        emit SetOracle(oracle);
    }

    /* RECEIVE FUNCTION */

    /// @dev Allows the adapter to receive native currency used by managed calls.
    receive() external payable {}

    /* FALLBACK FUNCTION */

    /// @dev Routes external calls to installed implementation code. Dispatch only reads
    /// storage so ERC-1271 and other view callbacks also work under STATICCALL. Each implementation
    /// must authenticate its callers and protect adapter accounting for its own protocol operations.
    fallback() external payable {
        address capability = capabilityForSelector[msg.sig];
        if (msg.data.length < 4 || capability == address(0)) revert UnknownSelector();

        assembly ("memory-safe") {
            let data := mload(0x40)
            calldatacopy(data, 0, calldatasize())
            let success := delegatecall(gas(), capability, data, calldatasize(), 0, 0)
            returndatacopy(data, 0, returndatasize())
            if iszero(success) { revert(data, returndatasize()) }
            return(data, returndatasize())
        }
    }
}
