// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.37;

import {CooldownAccount} from "./common/CooldownAccount.sol";

import {IGaibAccount} from "../../interfaces/ll-adapter/gaib/IGaibAccount.sol";
import {IGaibSubAccount} from "../../interfaces/ll-adapter/gaib/IGaibSubAccount.sol";
import {ISaid} from "../../interfaces/ll-adapter/gaib/ISaid.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title GaibAccount
/// @notice Account contract for GAIB sAID queued unstaking.
contract GaibAccount is CooldownAccount, IGaibAccount {
    using SafeERC20 for IERC20;

    /* IMMUTABLES */

    /// @dev AID asset received after unstaking.
    address internal immutable _ASSET;

    /* STATE VARIABLES */

    /// @inheritdoc IGaibAccount
    address[] public subAccounts;

    /* CONSTRUCTOR */

    /// @notice Creates the GAIB account implementation.
    constructor(
        address newOracle,
        address newFactory,
        uint48 newCooldown,
        address newTokenToRedeem,
        address newCowSwapSettlement
    ) CooldownAccount(newOracle, newFactory, newCooldown, newTokenToRedeem, newCowSwapSettlement) {
        _ASSET = IERC4626(newTokenToRedeem).asset();
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Returns pending sAID unstake value in vault assets.
    function _totalAssets() internal view override returns (uint256 assets) {
        uint256 length = subAccounts.length;
        for (uint256 i; i < length; ++i) {
            assets += _redemptionTokenToAssets(_ASSET, IGaibSubAccount(subAccounts[i]).totalAssets());
        }
    }

    /// @dev Processes fulfilled unstake queue items.
    function _finalizeRequests() internal override {
        uint256 length = subAccounts.length;
        for (uint256 i = length; i > 0; --i) {
            uint256 index = i - 1;
            address subAccount = subAccounts[index];

            IGaibSubAccount(subAccount).sync();
            if (IGaibSubAccount(subAccount).totalAssets() == 0) {
                --length;
                subAccounts[index] = subAccounts[length];
                subAccounts.pop();
            }
        }
    }

    /// @dev Submits held sAID through a new request-holder subaccount.
    function _requestRedeem() internal override returns (bool) {
        uint256 amount = IERC20(TOKEN_TO_REDEEM).balanceOf(address(this));
        address subAccount = address(new GaibSubAccount(address(this), TOKEN_TO_REDEEM));

        subAccounts.push(subAccount);
        IERC20(TOKEN_TO_REDEEM).safeTransfer(subAccount, amount);
        IGaibSubAccount(subAccount).requestRedeem(amount);
        return true;
    }

    /// @dev Initializes the account for an adapter and vault.
    function _initialize(uint64 initialVersion, address initOwner, bytes memory data) internal override {
        super._initialize(initialVersion, initOwner, data);
        if (_ASSET != _asset) revert InvalidAsset();
    }
}

/// @title GaibSubAccount
/// @notice Subaccount contract for one GAIB unstake request.
contract GaibSubAccount is IGaibSubAccount {
    using SafeERC20 for IERC20;

    /* IMMUTABLES */

    /// @dev Parent account that owns this subaccount.
    address internal immutable _ACCOUNT;

    /// @dev GAIB sAID token submitted for unstaking.
    address internal immutable _TOKEN_TO_REDEEM;

    /// @dev AID asset received after unstaking.
    address internal immutable _ASSET;

    /* CONSTRUCTOR */

    /// @notice Creates the GAIB request-holder subaccount.
    constructor(address newAccount, address newTokenToRedeem) {
        _ACCOUNT = newAccount;
        _TOKEN_TO_REDEEM = newTokenToRedeem;
        _ASSET = IERC4626(newTokenToRedeem).asset();
    }

    /* EXTERNAL FUNCTIONS */

    /// @inheritdoc IGaibSubAccount
    function requestRedeem(uint256 amount) external {
        if (_ACCOUNT != msg.sender) revert NotAccount();

        ISaid(_TOKEN_TO_REDEEM).unstake(amount);
    }

    /// @inheritdoc IGaibSubAccount
    function sync() external {
        if (_ACCOUNT != msg.sender) revert NotAccount();

        try ISaid(_TOKEN_TO_REDEEM).processUnstakeQueue(1) {} catch {}

        uint256 assets = IERC20(_ASSET).balanceOf(address(this));
        if (assets > 0) {
            IERC20(_ASSET).safeTransfer(_ACCOUNT, assets);
        }
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IGaibSubAccount
    function totalAssets() public view returns (uint256 assets) {
        (, assets) = ISaid(_TOKEN_TO_REDEEM).getUnstakeRequest(address(this));

        assets += IERC20(_ASSET).balanceOf(address(this));
    }
}
