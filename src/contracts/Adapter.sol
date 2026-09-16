// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.36;

import {IAdapter} from "../interfaces/IAdapter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRegistry} from "@symbioticfi/core/src/interfaces/common/IRegistry.sol";
import {IVaultV2} from "@symbioticfi/core/src/interfaces/vault/IVaultV2.sol";
import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {Multicallable} from "@symbioticfi/core/src/contracts/common/Multicallable.sol";
import {StaticDelegateCallable} from "@symbioticfi/core/src/contracts/common/StaticDelegateCallable.sol";

/// @title Adapter
/// @notice Base contract for vault adapters with shared vault validation.
abstract contract Adapter is MigratableEntity, StaticDelegateCallable, Multicallable, IAdapter {
    using SafeERC20 for IERC20;

    /* IMMUTABLES */

    /// @dev Vault factory used to validate adapter initialization vaults.
    address internal immutable _VAULT_FACTORY;

    /* STATE VARIABLES */

    /// @inheritdoc IAdapter
    address public vault;

    /// @dev Reserved storage gap for future upgrades.
    uint256[50] private __gap;

    /* MODIFIERS */

    modifier onlyDelegator() {
        if (IVaultV2(vault).delegator() != msg.sender) revert NotVault();

        _;
    }

    /* CONSTRUCTOR */

    constructor(address newVaultFactory, address newAdapterFactory) MigratableEntity(newAdapterFactory) {
        _VAULT_FACTORY = newVaultFactory;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IAdapter
    function allocatable() public view virtual returns (uint256) {
        return type(uint256).max;
    }

    /// @inheritdoc IAdapter
    function totalAssets() public view virtual returns (uint256);

    /// @inheritdoc IAdapter
    function freeAssets() public view virtual returns (uint256) {
        return IERC20(IERC4626(vault).asset()).balanceOf(address(this));
    }

    /// @inheritdoc IAdapter
    function allocate(uint256 amount) public onlyDelegator returns (uint256) {
        return amount > 0 ? _allocate(amount) : 0;
    }

    /// @inheritdoc IAdapter
    function deallocate(uint256 amount) public virtual onlyDelegator returns (uint256) {
        uint256 curFreeAssets = freeAssets();
        return curFreeAssets + (curFreeAssets < amount ? _deallocate(amount - curFreeAssets) : 0);
    }

    /// @inheritdoc IAdapter
    function requestDeallocate(uint256 amount) public onlyDelegator {
        return _requestDeallocate(amount);
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Allocates asset from the vault into the adapter position.
    function _allocate(uint256 amount) internal virtual returns (uint256) {}

    /// @dev Deallocates asset from the vault's adapter position.
    function _deallocate(uint256 amount) internal virtual returns (uint256) {}

    /// @dev Synchronizes adapter pending deallocation accounting.
    function _requestDeallocate(uint256 amount) internal virtual {}

    /// @dev Initializes the adapter vault and adapter-specific state.
    function _initialize(uint64, address, bytes memory data) internal override {
        (address initVault, bytes memory initData) = abi.decode(data, (address, bytes));

        if (!IRegistry(_VAULT_FACTORY).isEntity(initVault)) revert InvalidVault();

        vault = initVault;
        emit SetVault(initVault);

        IERC20(IERC4626(vault).asset()).forceApprove(initVault, type(uint256).max);

        __initialize(initVault, initData);
    }

    /// @dev Initializes adapter-specific state.
    function __initialize(address, bytes memory) internal virtual {}

    /// @dev Migration is intentionally unsupported for this implementation.
    function _migrate(uint64, uint64, bytes calldata) internal pure override {
        revert();
    }
}
