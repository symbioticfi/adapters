// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MerkleAdapterVerifier} from "./libraries/MerkleAdapterVerifier.sol";

import {ICapabilitiesRegistry} from "../../interfaces/merkle-adapter/ICapabilitiesRegistry.sol";
import {IMerkleAccount} from "../../interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "../../interfaces/IMerkleAdapter.sol";
import {IRoles} from "../../interfaces/merkle-adapter/oracle/IRoles.sol";
import {IRootRegistry} from "../../interfaces/merkle-adapter/IRootRegistry.sol";

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {Multicallable} from "@symbioticfi/core/src/contracts/common/Multicallable.sol";

import {LibBytes as Bytes} from "solady/utils/LibBytes.sol";
import {LibCall as Address} from "solady/utils/LibCall.sol";
import {MerkleProofLib as MerkleProof} from "solady/utils/MerkleProofLib.sol";
import {SafeTransferLib as SafeERC20} from "solady/utils/SafeTransferLib.sol";

/// @title MerkleAccount
/// @notice Migratable contract for strategy custody, Merkle permissions and capability execution.
contract MerkleAccount is
    MigratableEntity,
    AccessControlEnumerableUpgradeable,
    Multicallable,
    ERC721Holder,
    IRoles,
    IMerkleAccount
{
    using Address for address;
    using Bytes for bytes;
    using SafeERC20 for address;
    using EnumerableSet for EnumerableSet.AddressSet;

    /* IMMUTABLES */

    /// @inheritdoc IMerkleAccount
    address public immutable ROOT_REGISTRY;

    /// @inheritdoc IMerkleAccount
    address public immutable CAPABILITIES_REGISTRY;

    /* STATE VARIABLES */

    /// @inheritdoc IMerkleAccount
    address public adapter;

    /// @inheritdoc IMerkleAccount
    bytes32 public merkleRoot;

    /// @inheritdoc IMerkleAccount
    mapping(bytes4 selector => address capability) public capabilityBySelector;

    EnumerableSet.AddressSet private _capabilities;

    /// @inheritdoc IMerkleAccount
    mapping(address capability => bytes4[] selectors) public capabilitySelectors;

    /// @inheritdoc IMerkleAccount
    mapping(bytes32 digest => bool approved) public signatures;

    /* CONSTRUCTOR */

    constructor(address newFactory, address newRootRegistry, address newCapabilitiesRegistry)
        MigratableEntity(newFactory)
    {
        ROOT_REGISTRY = newRootRegistry;
        CAPABILITIES_REGISTRY = newCapabilitiesRegistry;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IMerkleAccount
    function getCapabilities() public view override returns (address[] memory) {
        return _capabilities.values();
    }

    /// @inheritdoc IMerkleAccount
    function capabilitySelectorsLength(address capability) public view returns (uint256) {
        return capabilitySelectors[capability].length;
    }

    /// @inheritdoc IMerkleAccount
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

    /// @inheritdoc IMerkleAccount
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

    /// @inheritdoc IMerkleAccount
    function acceptRoot(bytes32 root) public override onlyOwner {
        if (IRootRegistry(ROOT_REGISTRY).roots(address(this)) != root) revert InvalidRoot();

        merkleRoot = root;
        emit SetMerkleRoot(root);
    }

    /// @inheritdoc IMerkleAccount
    function manage(Action[] calldata actions) public override nonReentrant returns (bytes[] memory results) {
        bytes32 root = merkleRoot;
        uint256 length = actions.length;
        for (uint256 i; i < length; ++i) {
            Action calldata action = actions[i];
            bytes32 leaf = MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask);
            if (!MerkleProof.verifyCalldata(action.proof, root, leaf)) revert InvalidMerkleProof();

            _checkRole(leaf);
        }

        results = new bytes[](length);
        for (uint256 i; i < length; ++i) {
            Action calldata action = actions[i];
            results[i] = action.target.callContract(action.value, action.data);
        }
    }

    /// @inheritdoc IMerkleAccount
    function isCapability(address capability) public view override returns (bool) {
        return _capabilities.contains(capability);
    }

    /// @inheritdoc IMerkleAccount
    function setSignature(bytes32 domain, bytes calldata signature, Hash[] calldata hashes) public {
        if (address(this) != msg.sender) revert InvalidCaller();

        bytes memory data = signature;
        uint256 length = hashes.length;
        for (uint256 i; i < length; ++i) {
            Hash calldata range = hashes[i];
            if (range.start > range.end || range.end > data.length) revert InvalidSignature();
            data = bytes.concat(
                data.slice(0, range.start),
                abi.encode(keccak256(data.slice(range.start, range.end))),
                data.slice(range.end)
            );
        }
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domain, keccak256(data)));
        signatures[digest] = true;
        emit SetSignature(digest, signature, hashes);
    }

    /// @inheritdoc IMerkleAccount
    function revokeSignature(bytes32 digest) public {
        if (address(this) != msg.sender) revert InvalidCaller();

        delete signatures[digest];
        emit RevokeSignature(digest);
    }

    /// @inheritdoc IERC1271
    function isValidSignature(bytes32 digest, bytes calldata) public view returns (bytes4) {
        return signatures[digest] ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }

    /* INTERNAL FUNCTIONS */

    function _initialize(uint64, address, bytes memory data) internal override {
        InitParams memory params = abi.decode(data, (InitParams));
        adapter = params.adapter;
        if (params.defaultAdminRoleHolder != address(0)) {
            _grantRole(DEFAULT_ADMIN_ROLE, params.defaultAdminRoleHolder);
        }
        IERC4626(IMerkleAdapter(adapter).vault()).asset().safeApproveWithRetry(adapter, type(uint256).max);
    }

    /* RECEIVE FUNCTION */

    receive() external payable {}

    /* FALLBACK FUNCTION */

    /// @dev Unrecognized selectors delegate into installed capabilities in this account's storage.
    fallback(bytes calldata data) external payable returns (bytes memory) {
        address capability = capabilityBySelector[msg.sig];
        if (data.length < 4 || capability == address(0)) revert UnknownSelector();
        return capability.delegateCallContract(data);
    }
}
