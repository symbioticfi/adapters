// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.37;

import {CooldownAccount} from "./CooldownAccount.sol";
import {CutoffAccount} from "./CutoffAccount.sol";

import {ICutoffAccount} from "../../../interfaces/ll-adapter/ICutoffAccount.sol";
import {IPriceDataOracle} from "../../../interfaces/ll-adapter/IPriceDataOracle.sol";
import {ISettlementAccount} from "../../../interfaces/ll-adapter/ISettlementAccount.sol";
import {ISettlementSubAccount} from "../../../interfaces/ll-adapter/ISettlementSubAccount.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SettlementAccount
/// @notice Base contract for settling redemptions through per-request subaccounts priced by cutoff cohorts.
/// @dev Partial settlements stay isolated in the subaccount until they cover the frozen cohort value or
/// the cohort is written off; released subaccounts remain rescueable for late funds.
abstract contract SettlementAccount is CooldownAccount, CutoffAccount, ISettlementAccount {
    using SafeERC20 for IERC20;

    /* IMMUTABLES */

    /// @inheritdoc ISettlementAccount
    uint48 public immutable VALUATION_DELAY;

    /// @inheritdoc ISettlementAccount
    uint48 public immutable POST_CUTOFF_WINDOW;

    /* STATE VARIABLES */

    /// @dev Cutoff bucket accounting.
    struct Bucket {
        uint256 totalTokenToRedeem;
        uint256 pendingTokenToRedeem;
        uint256 rate;
    }

    /// @dev Pending cutoff entry.
    struct PendingCutoff {
        uint256 amount;
        uint48 bucket;
    }

    /// @inheritdoc ISettlementAccount
    address[] public subAccounts;

    /// @inheritdoc ISettlementAccount
    mapping(uint48 bucket => Bucket data) public buckets;

    /// @inheritdoc ISettlementAccount
    mapping(address subAccount => bool created) public isSubAccount;

    /// @inheritdoc ISettlementAccount
    mapping(uint256 key => PendingCutoff data) public pendingCutoffs;

    /* CONSTRUCTOR */

    /// @dev Creates the settlement account implementation.
    constructor(
        address newOracle,
        address newFactory,
        uint48 newCooldown,
        address newTokenToRedeem,
        uint48 newValuationDelay,
        uint48 newPostCutoffWindow,
        address newCowSwapSettlement
    ) CooldownAccount(newOracle, newFactory, newCooldown, newTokenToRedeem, newCowSwapSettlement) {
        VALUATION_DELAY = newValuationDelay;
        POST_CUTOFF_WINDOW = newPostCutoffWindow;
    }

    /* EXTERNAL FUNCTIONS */

    /// @inheritdoc ISettlementAccount
    function rescueSubAccount(address subAccount) external nonReentrant {
        if (!isSubAccount[subAccount]) revert UnknownSubAccount();

        uint256 length = subAccounts.length;
        for (uint256 i; i < length; ++i) {
            if (subAccounts[i] == subAccount) revert SubAccountTracked();
        }
        ISettlementSubAccount(subAccount).sync();
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ICutoffAccount
    function timestampToBucket(uint48 timestamp)
        public
        pure
        virtual
        override(CutoffAccount, ICutoffAccount)
        returns (uint48 bucket)
    {
        return timestamp;
    }

    /// @inheritdoc ICutoffAccount
    function bucketToTimestamp(uint48 bucket)
        public
        pure
        virtual
        override(CutoffAccount, ICutoffAccount)
        returns (uint48 timestamp)
    {
        return bucket;
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Returns each subaccount's pending value or isolated holdings, whichever is larger.
    function _totalAssets() internal view override returns (uint256 assets) {
        uint256 length = subAccounts.length;
        for (uint256 i; i < length; ++i) {
            address subAccount = subAccounts[i];
            uint256 holdings = _subAccountAssets(subAccount);
            (uint256 value,) = _cutoffValue(uint160(subAccount));
            assets += holdings > value ? holdings : value;
        }
    }

    /// @dev Freezes cohort rates and releases subaccounts that are covered or written off.
    function _finalizeRequests() internal override {
        uint256 length = subAccounts.length;
        for (uint256 i = length; i > 0; --i) {
            uint256 index = i - 1;
            address subAccount = subAccounts[index];
            uint256 key = uint160(subAccount);
            PendingCutoff storage pendingCutoff = pendingCutoffs[key];
            Bucket storage bucket = buckets[pendingCutoff.bucket];

            if (pendingCutoff.amount > 0 && bucket.rate == 0) {
                uint256 pricingTimestamp = uint256(bucketToTimestamp(pendingCutoff.bucket)) + VALUATION_DELAY;
                if (
                    block.timestamp >= pricingTimestamp
                        && block.timestamp < uint256(bucketToTimestamp(pendingCutoff.bucket)) + POST_CUTOFF_WINDOW
                ) {
                    (uint256 price, uint48 updatedAt) = IPriceDataOracle(ORACLE).getPriceData();
                    if (price > 0 && updatedAt >= pricingTimestamp) {
                        bucket.rate = price;
                        emit FreezeBucket(pendingCutoff.bucket, price);
                    }
                }
            }

            (uint256 value, bool writtenOff) = _cutoffValue(key);
            if (!writtenOff && (bucket.rate == 0 || _subAccountAssets(subAccount) < value)) {
                continue;
            }

            (uint256 sweptAssets, uint256 sweptTokenAmount) = ISettlementSubAccount(subAccount).sync();

            bucket.pendingTokenToRedeem -= pendingCutoff.amount;
            delete pendingCutoffs[key];
            --length;
            subAccounts[index] = subAccounts[length];
            subAccounts.pop();

            if (sweptAssets > 0 || sweptTokenAmount > 0) {
                emit SweepSubAccount(subAccount, sweptAssets, sweptTokenAmount);
            }
            emit ReleaseSubAccount(subAccount);
        }
    }

    /// @dev Submits held token-to-redeem inventory through a new request-holder subaccount.
    function _requestRedeem() internal override returns (bool) {
        uint256 amount = IERC20(TOKEN_TO_REDEEM).balanceOf(address(this));
        address subAccount = _createSubAccount();

        isSubAccount[subAccount] = true;
        subAccounts.push(subAccount);
        uint48 bucket = currentBucket();
        pendingCutoffs[uint160(subAccount)] = PendingCutoff({amount: amount, bucket: bucket});
        buckets[bucket].totalTokenToRedeem += amount;
        buckets[bucket].pendingTokenToRedeem += amount;
        IERC20(TOKEN_TO_REDEEM).safeTransfer(subAccount, amount);
        ISettlementSubAccount(subAccount).requestRedeem();
        return true;
    }

    /// @dev Deploys the issuer-specific request-holder subaccount.
    function _createSubAccount() internal virtual returns (address subAccount);

    /// @dev Returns a subaccount's isolated vault-asset value.
    function _subAccountAssets(address subAccount) internal view returns (uint256 assets) {
        assets = IERC20(_asset).balanceOf(subAccount);
        uint256 tokenBalance = IERC20(TOKEN_TO_REDEEM).balanceOf(subAccount);
        if (tokenBalance > 0) {
            assets += _tokenToRedeemToAssets(tokenBalance);
        }
    }

    /// @dev Returns a pending cutoff entry's value and whether it is past its counting window.
    function _cutoffValue(uint256 key) internal view returns (uint256 value, bool writtenOff) {
        PendingCutoff memory pendingCutoff = pendingCutoffs[key];
        if (pendingCutoff.amount == 0) {
            return (0, false);
        }

        writtenOff = block.timestamp >= uint256(bucketToTimestamp(pendingCutoff.bucket)) + POST_CUTOFF_WINDOW;
        if (writtenOff) {
            return (0, true);
        }

        uint256 rate = buckets[pendingCutoff.bucket].rate;
        if (rate == 0) {
            (rate,) = IPriceDataOracle(ORACLE).getPriceData();
            if (rate == 0) revert InvalidCutoffPrice();
        }

        value = _tokenToRedeemToAssets(pendingCutoff.amount, rate);
    }

    /// @dev Blocks migration while subaccounts are still tracked: a live pipeline cannot be assumed
    /// ABI- or storage-compatible across implementations (legacy subaccounts had a void `sync()`,
    /// and legacy layouts stored the subaccount array at a different slot), so migration is only
    /// safe from an empty pipeline.
    function _migrate(uint64 oldVersion, uint64 newVersion, bytes calldata data) internal virtual override {
        if (subAccounts.length > 0) revert MigrationWithLiveSubAccounts();

        super._migrate(oldVersion, newVersion, data);
    }
}

/// @title SettlementSubAccount
/// @notice Subaccount contract for one issuer redemption settlement.
abstract contract SettlementSubAccount is ISettlementSubAccount {
    using SafeERC20 for IERC20;

    /* IMMUTABLES */

    /// @dev Parent account that owns this subaccount.
    address internal immutable _ACCOUNT;

    /// @dev Vault asset expected from settlement.
    address internal immutable _ASSET;

    /// @dev Token submitted for redemption.
    address internal immutable _TOKEN_TO_REDEEM;

    /* CONSTRUCTOR */

    /// @dev Creates the request-holder subaccount.
    constructor(address newAsset, address newAccount, address newTokenToRedeem) {
        _ASSET = newAsset;
        _ACCOUNT = newAccount;
        _TOKEN_TO_REDEEM = newTokenToRedeem;
    }

    /* EXTERNAL FUNCTIONS */

    /// @inheritdoc ISettlementSubAccount
    function requestRedeem() external {
        if (_ACCOUNT != msg.sender) revert NotAccount();

        _executeRedemption();
    }

    /// @inheritdoc ISettlementSubAccount
    function sync() external returns (uint256 assets, uint256 tokenAmount) {
        if (_ACCOUNT != msg.sender) revert NotAccount();

        assets = IERC20(_ASSET).balanceOf(address(this));
        if (assets > 0) {
            IERC20(_ASSET).safeTransfer(_ACCOUNT, assets);
        }

        tokenAmount = IERC20(_TOKEN_TO_REDEEM).balanceOf(address(this));
        if (tokenAmount > 0) {
            IERC20(_TOKEN_TO_REDEEM).safeTransfer(_ACCOUNT, tokenAmount);
        }
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Submits the held token balance to the issuer's redemption flow.
    function _executeRedemption() internal virtual;
}
