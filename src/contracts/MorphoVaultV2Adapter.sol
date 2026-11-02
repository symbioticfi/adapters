// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Adapter} from "./Adapter.sol";
import {CoWSwapConverter} from "./common/CoWSwapConverter.sol";
import {MerklClaimer} from "./common/MerklClaimer.sol";

import {IAdapter} from "../interfaces/IAdapter.sol";
import {IConverter} from "../interfaces/common/IConverter.sol";
import {IMorphoLiquidityAdapter} from "../interfaces/morpho_vaultv2_adapter/IMorphoLiquidityAdapter.sol";
import {IMorphoVaultV2Adapter} from "../interfaces/IMorphoVaultV2Adapter.sol";
import {IMorphoVaultV2Factory} from "../interfaces/morpho_vaultv2_adapter/IMorphoVaultV2Factory.sol";
import {IMorphoVaultV2} from "../interfaces/morpho_vaultv2_adapter/IMorphoVaultV2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MorphoVaultV2Adapter
/// @notice VaultV2 adapter contract for Morpho ERC4626 vaults.
contract MorphoVaultV2Adapter is Adapter, CoWSwapConverter, MerklClaimer, IMorphoVaultV2Adapter {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /* IMMUTABLES */

    /// @dev Morpho vault factory used for curator-side vault validation.
    address internal immutable _MORPHO_VAULT_FACTORY;

    /// @dev Required Morpho adapter registry for configured vaults.
    address internal immutable _MORPHO_ADAPTER_REGISTRY;

    /* STATE VARIABLES */

    /// @inheritdoc IMorphoVaultV2Adapter
    address public morphoVault;

    /// @inheritdoc IMorphoVaultV2Adapter
    uint256 public totalShares;

    /* CONSTRUCTOR */

    constructor(
        address newVaultFactory,
        address newAdapterFactory,
        address newMerklDistributor,
        address newCowSwapSettlement,
        address newMorphoVaultFactory,
        address newMorphoAdapterRegistry
    )
        Adapter(newVaultFactory, newAdapterFactory)
        CoWSwapConverter(newCowSwapSettlement)
        MerklClaimer(newMerklDistributor)
    {
        _MORPHO_VAULT_FACTORY = newMorphoVaultFactory;
        _MORPHO_ADAPTER_REGISTRY = newMorphoAdapterRegistry;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IAdapter
    function totalAssets() public view override(Adapter, IAdapter) returns (uint256) {
        return freeAssets() + IMorphoVaultV2(morphoVault).previewRedeem(totalShares);
    }

    /// @inheritdoc IConverter
    function convert(address tokenIn, uint256 amountIn, address tokenOut, bytes calldata data) public virtual override {
        if (tokenIn == morphoVault || tokenIn == IERC4626(vault).asset()) revert InvalidTokenIn();

        if (tokenOut != IERC4626(vault).asset()) revert InvalidTokenOut();

        super.convert(tokenIn, amountIn, tokenOut, data);
    }

    /// @dev Uses a self-call so failed or zero-share deposits roll back before allocation catches the revert.
    function deposit(uint256 amount) public returns (uint256 shares) {
        if (address(this) != msg.sender) revert NotSelf();

        shares = IMorphoVaultV2(morphoVault).deposit(amount, address(this));
        if (shares == 0) revert InsufficientAmount();
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Deposits asset from the calling vault into the configured Morpho vault.
    function _allocate(uint256 amount) internal override returns (uint256) {
        try this.deposit(amount) returns (uint256 shares) {
            totalShares += shares;
            return amount;
        } catch {}
        return 0;
    }

    /// @dev Withdraws asset for the calling vault from the configured Morpho vault.
    function _deallocate(uint256 amount) internal override returns (uint256) {
        address liquidityAdapter = IMorphoVaultV2(morphoVault).liquidityAdapter();
        amount = Math.min(
            amount,
            Math.min(
                IMorphoVaultV2(morphoVault).previewRedeem(totalShares),
                IERC20(IERC4626(vault).asset()).balanceOf(morphoVault)
                    + (liquidityAdapter == address(0) ? 0 : IMorphoLiquidityAdapter(liquidityAdapter).realAssets())
            )
        );
        if (amount == 0) {
            return 0;
        }

        try IMorphoVaultV2(morphoVault).withdraw(amount, address(this), address(this)) returns (uint256 shares) {
            totalShares -= shares;
            return amount;
        } catch {}
        return 0;
    }

    /// @dev Initializes and permanently binds the Morpho vault.
    function __initialize(address, bytes memory data) internal override {
        InitParams memory params = abi.decode(data, (InitParams));

        __CoWSwapConverter_init(params.converters);

        if (
            params.morphoVault == address(0)
                || !IMorphoVaultV2Factory(_MORPHO_VAULT_FACTORY).isVaultV2(params.morphoVault)
                || !IMorphoVaultV2(params.morphoVault).abdicated(IMorphoVaultV2.setAdapterRegistry.selector)
                || IMorphoVaultV2(params.morphoVault).adapterRegistry() != _MORPHO_ADAPTER_REGISTRY
                || IMorphoVaultV2(params.morphoVault).asset() != IERC4626(vault).asset()
        ) revert InvalidMorphoVault();

        morphoVault = params.morphoVault;

        IERC20(IERC4626(vault).asset()).forceApprove(params.morphoVault, type(uint256).max);

        emit Initialize(params.morphoVault);
    }
}
