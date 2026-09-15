// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {Adapter} from "./Adapter.sol";

import {MerkleAdapterVerifier} from "./merkle_adapter/libraries/MerkleAdapterVerifier.sol";

import {ANY_VALUE, ANY_VALUE_FLAG, IMerkleAdapter} from "../interfaces/IMerkleAdapter.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {IMerkleAdapterOracle} from "../interfaces/merkle_adapter/IMerkleAdapterOracle.sol";
import {IRootRegistry} from "../interfaces/merkle_adapter/IRootRegistry.sol";

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMigratablesFactory} from "@symbioticfi/core/src/interfaces/common/IMigratablesFactory.sol";

/// @title MerkleAdapter
/// @notice Adapter whose Merkle-proven call permissions each serve as an enumerable access-control role.
contract MerkleAdapter is Adapter, AccessControlEnumerableUpgradeable, IMerkleAdapter {
    using Address for address;
    using Math for uint256;

    /// @inheritdoc IMerkleAdapter
    address public immutable override ORACLE_FACTORY;

    /// @inheritdoc IMerkleAdapter
    address public immutable override ROOT_REGISTRY;

    /// @inheritdoc IMerkleAdapter
    address public override oracle;

    /// @inheritdoc IMerkleAdapter
    bytes32 public override merkleRoot;

    mapping(uint256 nonce => uint256 amount) public pendingAllocation;
    mapping(uint256 nonce => uint256 amount) public toDeallocate;
    uint256 public lastSyncedNonce;
    uint256 public deallocatable;

    /// @dev Initializes the immutable factory dependencies for the implementation.
    constructor(address vaultFactory, address adapterFactory, address oracleFactory, address rootRegistry)
        Adapter(vaultFactory, adapterFactory)
    {
        ORACLE_FACTORY = oracleFactory;
        ROOT_REGISTRY = rootRegistry;
    }

    /// @dev Allows the adapter to receive native currency used by managed calls.
    receive() external payable {}

    /// @inheritdoc IMerkleAdapter
    function acceptRoot(bytes32 root) external override onlyOwner {
        if (IRootRegistry(ROOT_REGISTRY).roots(address(this)) != root) {
            revert InvalidRoot();
        }

        merkleRoot = root;
        emit SetMerkleRoot(root);
    }

    /// @inheritdoc IMerkleAdapter
    function manage(Action[] calldata actions) external override nonReentrant returns (bytes[] memory results) {
        bytes32 root = merkleRoot;
        uint256 length = actions.length;

        for (uint256 i; i < length; ++i) {
            Action calldata action = actions[i];
            uint96 flagsAndValue = action.flagsAndValue;

            bytes32 leaf = MerkleAdapterVerifier.leaf(
                action.target,
                (flagsAndValue & ANY_VALUE_FLAG) == 0 ? flagsAndValue & ANY_VALUE : ANY_VALUE,
                action.data,
                action.dataMask
            );
            if (!MerkleAdapterVerifier.verify(action.proof, root, leaf)) {
                revert InvalidMerkleProof(i);
            }
            _checkRole(leaf);
        }

        results = new bytes[](length);
        for (uint256 i; i < length; ++i) {
            Action calldata action = actions[i];
            results[i] = action.target.functionCallWithValue(action.data, action.flagsAndValue & ANY_VALUE);
        }
        uint256 nonce = _sync();
        if (freeAssets() < deallocatable + pendingAllocation[nonce] + pendingAllocation[nonce + 1]) {
            revert InsufficientIdleAssets();
        }
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
}
