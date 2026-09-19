// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Adapter} from "./Adapter.sol";

import {MerkleAdapterVerifier} from "./merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IAdapter} from "../interfaces/IAdapter.sol";
import {ICapabilitiesRegistry} from "../interfaces/merkle-adapter/ICapabilitiesRegistry.sol";
import {IMerkleAdapterOracle} from "../interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {IMerkleAdapter} from "../interfaces/IMerkleAdapter.sol";
import {IRoles} from "../interfaces/merkle-adapter/oracle/IRoles.sol";
import {IRootRegistry} from "../interfaces/merkle-adapter/IRootRegistry.sol";

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {IMigratablesFactory} from "@symbioticfi/core/src/interfaces/common/IMigratablesFactory.sol";

/// @title MerkleAdapter
/// @notice Adapter contract whose Merkle-proven call permissions each serve as an enumerable access-control role.
contract MerkleAdapter is Adapter, AccessControlEnumerableUpgradeable, Proxy, IRoles, IMerkleAdapter {
    using Address for address;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

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
    mapping(bytes4 selector => address capability) public override capabilityBySelector;

    /// @dev Implementation addresses installed by this adapter's owner.
    EnumerableSet.AddressSet private _capabilities;

    /// @inheritdoc IMerkleAdapter
    mapping(address capability => bytes4[] selectors) public capabilitySelectors;

    /// @inheritdoc IMerkleAdapter
    mapping(bytes32 digest => bytes signature) public signatures;

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
    function setSignature(bytes32 digest, bytes calldata signature) public {
        if (address(this) != msg.sender) revert InvalidCaller();

        signatures[digest] = signature;
        emit SetSignature(digest, signature);
    }

    /// @inheritdoc IERC1271
    function isValidSignature(bytes32 digest, bytes calldata signature) public view returns (bytes4) {
        if (signature.length == 0 || !Bytes.equal(signature, signatures[digest])) return 0xffffffff;

        (address validator, bytes memory data) = abi.decode(signature, (address, bytes));
        return SignatureChecker.isValidERC1271SignatureNow(validator, digest, data)
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }

    /// @inheritdoc IMerkleAdapter
    function getCapabilities() public view override returns (address[] memory) {
        return _capabilities.values();
    }

    /// @inheritdoc IMerkleAdapter
    function capabilitySelectorsLength(address capability) public view returns (uint256) {
        return capabilitySelectors[capability].length;
    }

    /// @inheritdoc IMerkleAdapter
    function addCapability(address capability) public override onlyOwner {
        uint256 length =
            ICapabilitiesRegistry(CAPABILITIES_REGISTRY).capabilitySelectorsLength(address(this), capability);
        if (length == 0) revert CapabilityNotWhitelisted();

        if (!_capabilities.add(capability)) revert CapabilityAlreadyAdded();

        for (uint256 i; i < length; ++i) {
            bytes4 selector =
                ICapabilitiesRegistry(CAPABILITIES_REGISTRY).capabilitySelectors(address(this), capability, i);
            if (capabilityBySelector[selector] != address(0)) revert SelectorAlreadyUsed();

            capabilityBySelector[selector] = capability;
            capabilitySelectors[capability].push(selector);
        }
        emit AddCapability(capability);
    }

    /// @inheritdoc IMerkleAdapter
    function removeCapability(address capability) public override onlyOwner {
        if (!_capabilities.remove(capability)) revert CapabilityNotAdded();

        bytes4[] storage selectors = capabilitySelectors[capability];
        uint256 length = selectors.length;
        for (uint256 i; i < length; ++i) {
            delete capabilityBySelector[selectors[i]];
        }
        delete capabilitySelectors[capability];
        emit RemoveCapability(capability);
    }

    /// @inheritdoc IMerkleAdapter
    function acceptRoot(bytes32 root) public override onlyOwner {
        if (IRootRegistry(ROOT_REGISTRY).roots(address(this)) != root) revert InvalidRoot();

        merkleRoot = root;
        emit SetMerkleRoot(root);
    }

    /// @inheritdoc IMerkleAdapter
    function manage(Action[] calldata actions) public override nonReentrant returns (bytes[] memory results) {
        bytes32 root = merkleRoot;
        for (uint256 i; i < actions.length; ++i) {
            Action calldata action = actions[i];
            bytes32 leaf = MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask);
            if (!MerkleProof.verifyCalldata(action.proof, root, leaf)) revert InvalidMerkleProof();

            _checkRole(leaf);
        }

        results = new bytes[](actions.length);
        for (uint256 i; i < actions.length; ++i) {
            Action calldata action = actions[i];
            results[i] = action.target.functionCallWithValue(action.data, action.value);
        }
        if (freeAssets() < reservedAssetsAt(_sync())) {
            revert InsufficientIdleAssets();
        }
    }

    /// @inheritdoc IMerkleAdapter
    function isCapability(address capability) public view override returns (bool) {
        return _capabilities.contains(capability);
    }

    /// @inheritdoc IAdapter
    function totalAssets() public view override(Adapter, IAdapter) returns (uint256) {
        IMerkleAdapterOracle(oracle).validate();
        return IMerkleAdapterOracle(oracle).totalAssets() + reservedAssets();
    }

    /// @inheritdoc IAdapter
    function allocatable() public view override(Adapter, IAdapter) returns (uint256) {
        IMerkleAdapterOracle(oracle).validate();
        return type(uint256).max;
    }

    /// @inheritdoc IMerkleAdapter
    function reservedAssets() public view returns (uint256) {
        return reservedAssetsAt(IMerkleAdapterOracle(oracle).nonce());
    }

    /// @inheritdoc IAdapter
    function deallocate(uint256 amount) public override(Adapter, IAdapter) onlyDelegator returns (uint256 deallocated) {
        IMerkleAdapterOracle(oracle).validate();
        _sync();
        deallocated = Math.min(amount, deallocatable);
        deallocatable -= deallocated;
    }

    /// @inheritdoc IMerkleAdapter
    function reservedAssetsAt(uint256 nonce) public view returns (uint256) {
        return pendingAllocation[nonce] + pendingAllocation[nonce + 1] + deallocatableAt(nonce);
    }

    /// @inheritdoc IMerkleAdapter
    function deallocatableAt(uint256 nonce) public view returns (uint256) {
        uint256 previous = lastSyncedNonce;
        return deallocatable + (nonce > previous ? toDeallocate[previous] : 0)
            + (nonce > previous + 1 ? toDeallocate[previous + 1] : 0);
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Proxy dispatch only reads storage, including for STATICCALL callbacks.
    function _implementation() internal view override returns (address capability) {
        capability = capabilityBySelector[msg.sig];
        if (msg.data.length < 4 || capability == address(0)) revert UnknownSelector();
    }

    function _allocate(uint256 amount) internal override returns (uint256 allocated) {
        IMerkleAdapterOracle(oracle).validate();
        uint256 epoch = _sync() + 1;
        uint256 matched = Math.min(amount, toDeallocate[epoch]);
        toDeallocate[epoch] -= matched;
        allocated = amount - matched;
        pendingAllocation[epoch] += allocated;
    }

    function _requestDeallocate(uint256 amount) internal override {
        IMerkleAdapterOracle(oracle).validate();
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
            deallocatable = deallocatableAt(nonce);
            lastSyncedNonce = nonce;
        }
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
}
