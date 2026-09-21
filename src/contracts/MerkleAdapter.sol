// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Adapter} from "./Adapter.sol";

import {IAdapter} from "../interfaces/IAdapter.sol";
import {IMerkleAccount} from "../interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapterOracle} from "../interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {IMerkleAdapter} from "../interfaces/IMerkleAdapter.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IMigratablesFactory} from "@symbioticfi/core/src/interfaces/common/IMigratablesFactory.sol";

import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib as SafeERC20} from "solady/utils/SafeTransferLib.sol";

/// @title MerkleAdapter
/// @notice Contract bridging vault reserves and a strategy account with oracle-backed accounting.
contract MerkleAdapter is Adapter, IMerkleAdapter {
    using SafeERC20 for address;
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc IMerkleAdapter
    address public immutable override ORACLE_FACTORY;

    /// @inheritdoc IMerkleAdapter
    address public immutable override ACCOUNT_FACTORY;

    /* STATE VARIABLES */

    /// @inheritdoc IMerkleAdapter
    address public override oracle;

    /// @inheritdoc IMerkleAdapter
    mapping(uint256 nonce => uint256 amount) public pendingAllocation;

    /// @inheritdoc IMerkleAdapter
    mapping(uint256 nonce => uint256 amount) public toDeallocate;

    /// @inheritdoc IMerkleAdapter
    uint256 public lastSyncedNonce;

    /// @inheritdoc IMerkleAdapter
    uint256 public deallocatable;

    /// @inheritdoc IMerkleAdapter
    address public account;

    /* CONSTRUCTOR */

    /// @dev Initializes the immutable factory dependencies for the implementation.
    constructor(address newVaultFactory, address newAdapterFactory, address newOracleFactory, address newAccountFactory)
        Adapter(newVaultFactory, newAdapterFactory)
    {
        ORACLE_FACTORY = newOracleFactory;
        ACCOUNT_FACTORY = newAccountFactory;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IMerkleAdapter
    function push(uint256 amount) public {
        if (account != msg.sender) revert InvalidCaller();

        IERC4626(vault).asset().safeTransfer(account, amount);
        if (freeAssets() < reservedAssets()) revert InsufficientIdleAssets();
        emit Push(amount);
    }

    /// @inheritdoc IMerkleAdapter
    function pull(uint256 amount) public {
        if (account != msg.sender) revert InvalidCaller();

        IERC4626(vault).asset().safeTransferFrom(account, address(this), amount);
        emit Pull(amount);
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

    /// @dev Creates the latest strategy account and accounting oracle owned by the adapter owner.
    function __initialize(address, bytes memory data) internal override {
        IMerkleAdapter.InitParams memory params = abi.decode(data, (IMerkleAdapter.InitParams));
        account = IMigratablesFactory(ACCOUNT_FACTORY)
            .create(
                IMigratablesFactory(ACCOUNT_FACTORY).lastVersion(),
                owner(),
                abi.encode(
                    IMerkleAccount.InitParams({
                        adapter: address(this), defaultAdminRoleHolder: params.defaultAdminRoleHolder
                    })
                )
            );
        emit SetAccount(account);
        oracle = IMigratablesFactory(ORACLE_FACTORY)
            .create(IMigratablesFactory(ORACLE_FACTORY).lastVersion(), owner(), abi.encode(address(this)));
        emit SetOracle(oracle);
    }
}
