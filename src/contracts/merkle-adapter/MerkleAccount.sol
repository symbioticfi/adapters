// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MerkleAdapterVerifier} from "./libraries/MerkleAdapterVerifier.sol";

import {ICapabilitiesRegistry} from "../../interfaces/merkle-adapter/ICapabilitiesRegistry.sol";
import {IMerkleAccount} from "../../interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "../../interfaces/IMerkleAdapter.sol";
import {IRootRegistry} from "../../interfaces/merkle-adapter/IRootRegistry.sol";

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {Multicallable} from "@symbioticfi/core/src/contracts/common/Multicallable.sol";

/// @title MerkleAccount
/// @notice Migratable contract for strategy custody, Merkle permissions and capability execution.
contract MerkleAccount is
    MigratableEntity,
    AccessControlEnumerableUpgradeable,
    Multicallable,
    Proxy,
    ERC721Holder,
    IMerkleAccount
{
    using Address for address;
    using SafeERC20 for IERC20;
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

    /* VIEW FUNCTIONS */

    /// @inheritdoc IMerkleAccount
    function getCapabilities() public view override returns (address[] memory) {
        return _capabilities.values();
    }

    /// @inheritdoc IERC1271
    function isValidSignature(bytes32 digest, bytes calldata) public view returns (bytes4) {
        return signatures[digest] ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }

    /* PUBLIC FUNCTIONS (OWNER) */

    /// @inheritdoc IMerkleAccount
    function addCapability(address capability) public override onlyOwner {
        capabilitySelectors[capability] =
            ICapabilitiesRegistry(CAPABILITIES_REGISTRY).selectors(address(this), capability);

        uint256 length = capabilitySelectors[capability].length;
        if (length == 0) revert CapabilityNotWhitelisted();

        if (!_capabilities.add(capability)) revert CapabilityAlreadyAdded();

        for (uint256 i; i < length; ++i) {
            if (capabilityBySelector[capabilitySelectors[capability][i]] != address(0)) revert SelectorAlreadyUsed();

            capabilityBySelector[capabilitySelectors[capability][i]] = capability;
        }
        emit AddCapability(capability);
    }

    /// @inheritdoc IMerkleAccount
    function removeCapability(address capability) public override onlyOwner {
        if (!_capabilities.remove(capability)) revert CapabilityNotAdded();

        uint256 length = capabilitySelectors[capability].length;
        for (uint256 i; i < length; ++i) {
            delete capabilityBySelector[capabilitySelectors[capability][i]];
        }
        delete capabilitySelectors[capability];
        emit RemoveCapability(capability);
    }

    /// @inheritdoc IMerkleAccount
    function acceptRoot(bytes32 root) public override onlyOwner {
        if (IRootRegistry(ROOT_REGISTRY).roots(address(this)) != root) revert InvalidRoot();

        merkleRoot = root;
        emit AcceptRoot(root);
    }

    /* PUBLIC FUNCTIONS (CURATOR) */

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
            results[i] = action.target.functionCallWithValue(action.data, action.value);
        }
        emit Manage(actions);
    }

    /* PUBLIC FUNCTIONS (INTERNAL) */

    /// @inheritdoc IMerkleAccount
    function sign(bytes32 domainSeparator, bytes calldata buffer, Hash[] calldata plan) public {
        if (msg.sender != address(this)) revert InvalidCaller();

        uint256 size = buffer.length;
        if (size < 32 || plan.length == 0) revert InvalidHashPlan();

        // The plan collapses a copy, so the event can carry the buffer it was given.
        bytes memory collapsed = buffer;
        bytes32 structHash;
        for (uint256 i; i < plan.length; ++i) {
            uint256 offset = plan[i].offset;
            uint256 length = plan[i].length;
            uint256 destination = plan[i].destination;

            if (offset > size || length > size - offset || destination > size - 32) revert InvalidHashPlan();

            assembly ("memory-safe") {
                let base := add(collapsed, 0x20)
                structHash := keccak256(add(base, offset), length)
                mstore(add(base, destination), structHash)
            }
        }

        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        signatures[digest] = true;
        emit Sign(digest, domainSeparator, buffer, plan);
    }

    /// @inheritdoc IMerkleAccount
    function revokeSignature(bytes32 digest) public {
        if (address(this) != msg.sender) revert InvalidCaller();

        delete signatures[digest];
        emit RevokeSignature(digest);
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Unrecognized selectors delegate into installed capabilities in this account's storage.
    function _implementation() internal view override returns (address capability) {
        capability = capabilityBySelector[msg.sig];
        if (msg.data.length < 4 || capability == address(0)) revert UnknownSelector();
    }

    /* INITIALIZATION */

    function _initialize(uint64, address, bytes memory data) internal override {
        InitParams memory params = abi.decode(data, (InitParams));
        adapter = params.adapter;
        if (params.defaultAdminRoleHolder != address(0)) {
            _grantRole(DEFAULT_ADMIN_ROLE, params.defaultAdminRoleHolder);
        }
        IERC20(IERC4626(IMerkleAdapter(adapter).vault()).asset()).forceApprove(adapter, type(uint256).max);
    }

    /* RECEIVE FUNCTION */

    receive() external payable {}
}
