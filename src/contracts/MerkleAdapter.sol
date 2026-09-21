// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Adapter} from "./Adapter.sol";

import {IAdapter} from "../interfaces/IAdapter.sol";
import {IMerkleAccount} from "../interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapterOracle} from "../interfaces/merkle-adapter/oracle/IMerkleAdapterOracle.sol";
import {IMerkleAdapter} from "../interfaces/IMerkleAdapter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMigratablesFactory} from "@symbioticfi/core/src/interfaces/common/IMigratablesFactory.sol";

/// @title MerkleAdapter
/// @notice Contract bridging vault reserves and a strategy account with oracle-backed accounting.
contract MerkleAdapter is Adapter, IMerkleAdapter {
    using SafeERC20 for IERC20;
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
    Batch public currentBatch;

    /// @inheritdoc IMerkleAdapter
    Batch public nextBatch;

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

        IERC20(IERC4626(vault).asset()).safeTransfer(account, amount);
        if (freeAssets() < reservedAssets()) revert InsufficientIdleAssets();
        emit Push(amount);
    }

    /// @inheritdoc IMerkleAdapter
    function pull(uint256 amount) public {
        if (account != msg.sender) revert InvalidCaller();

        IERC20(IERC4626(vault).asset()).safeTransferFrom(account, address(this), amount);
        emit Pull(amount);
    }

    /// @inheritdoc IMerkleAdapter
    function settleReport(uint256 assets) public returns (bool, uint256) {
        if (oracle != msg.sender) revert InvalidCaller();

        uint256 released = Math.min(currentBatch.deallocation, assets);
        uint256 protectedAssets = deallocatable + nextBatch.allocation;
        if (assets > type(uint256).max - protectedAssets || freeAssets() < protectedAssets + released) {
            return (false, 0);
        }

        deallocatable += released;
        currentBatch = nextBatch;
        delete nextBatch;
        emit SettleReport(released);
        return (true, assets - released);
    }

    /// @inheritdoc IAdapter
    function totalAssets() public view override(Adapter, IAdapter) returns (uint256) {
        (uint256 assets,) = IMerkleAdapterOracle(oracle).validate();
        return assets + reservedAssets();
    }

    /// @inheritdoc IAdapter
    function allocatable() public view override(Adapter, IAdapter) returns (uint256) {
        IMerkleAdapterOracle(oracle).validate();
        return type(uint256).max;
    }

    /// @inheritdoc IMerkleAdapter
    function reservedAssets() public view returns (uint256) {
        return deallocatable + currentBatch.allocation + nextBatch.allocation;
    }

    /// @inheritdoc IAdapter
    function deallocate(uint256 amount) public override(Adapter, IAdapter) onlyDelegator returns (uint256 deallocated) {
        IMerkleAdapterOracle(oracle).validate();
        deallocated = Math.min(amount, deallocatable);
        deallocatable -= deallocated;
    }

    /* INTERNAL FUNCTIONS */

    function _allocate(uint256 amount) internal override returns (uint256 allocated) {
        (, uint256 cutoff) = IMerkleAdapterOracle(oracle).validate();
        Batch storage batch = block.timestamp < cutoff ? currentBatch : nextBatch;
        uint256 matched = Math.min(amount, batch.deallocation);
        batch.deallocation -= matched;
        allocated = amount - matched;
        batch.allocation += allocated;
    }

    function _requestDeallocate(uint256 amount) internal override {
        (, uint256 cutoff) = IMerkleAdapterOracle(oracle).validate();
        Batch storage batch = block.timestamp < cutoff ? currentBatch : nextBatch;
        if (block.timestamp >= cutoff) amount = amount.saturatingSub(currentBatch.deallocation);
        uint256 matched = Math.min(amount, batch.allocation);
        deallocatable += matched;
        batch.allocation -= matched;
        batch.deallocation = amount - matched;
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
