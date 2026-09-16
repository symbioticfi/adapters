// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {CooldownAccount} from "./common/CooldownAccount.sol";
import {CutoffAccount} from "./common/CutoffAccount.sol";

import {IAcredSecuritizeAccount} from "../../interfaces/ll-adapter/IAcredSecuritizeAccount.sol";
import {ICutoffAccount} from "../../interfaces/ll-adapter/ICutoffAccount.sol";
import {IPriceDataOracle} from "../../interfaces/ll-adapter/IPriceDataOracle.sol";
import {ISecuritizeAccount} from "../../interfaces/ll-adapter/securitize/ISecuritizeAccount.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SecuritizeAccount
/// @notice Account contract for Securitize off-chain settlement redemptions with windowed repurchases.
/// @dev The redemption notice is an ERC-20 transfer to the issuer's redemption wallet; settlement
/// returns vault assets directly to this account.
abstract contract SecuritizeAccount is CooldownAccount, CutoffAccount, ISecuritizeAccount {
    using SafeERC20 for IERC20;

    /* IMMUTABLES */

    /// @inheritdoc ISecuritizeAccount
    address public immutable REDEMPTION_WALLET;

    /// @inheritdoc ISecuritizeAccount
    uint48 public immutable VALUATION_DELAY;

    /// @inheritdoc ISecuritizeAccount
    uint48 public immutable POST_CUTOFF_WINDOW;

    /* STATE VARIABLES */

    /// @inheritdoc ISecuritizeAccount
    mapping(uint48 bucket => Bucket data) public buckets;

    /// @inheritdoc ISecuritizeAccount
    mapping(uint256 key => PendingCutoff data) public pendingCutoffs;

    /// @dev Pending cutoff keys tracked by this account.
    uint256[] internal _pendingKeys;

    /// @dev Next pending cutoff key.
    uint256 internal _nextPendingKey;

    /* CONSTRUCTOR */

    /// @dev Creates the Securitize account implementation.
    constructor(
        address newOracle,
        address newFactory,
        uint48 newCooldown,
        address newTokenToRedeem,
        address newRedemptionWallet,
        uint48 newValuationDelay,
        uint48 newPostCutoffWindow,
        address newCowSwapSettlement
    ) CooldownAccount(newOracle, newFactory, newCooldown, newTokenToRedeem, newCowSwapSettlement) {
        REDEMPTION_WALLET = newRedemptionWallet;
        VALUATION_DELAY = newValuationDelay;
        POST_CUTOFF_WINDOW = newPostCutoffWindow;
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Returns pending cutoff value not already covered by same-account settlement assets.
    function _totalAssets() internal view override returns (uint256 assets) {
        uint256 remainingAssets = IERC20(_asset).balanceOf(address(this));

        uint256 length = _pendingKeys.length;
        for (uint256 i; i < length; ++i) {
            (uint256 value,) = _cutoffValue(_pendingKeys[i]);
            if (remainingAssets >= value) {
                remainingAssets -= value;
            } else {
                assets += value - remainingAssets;
                remainingAssets = 0;
            }
        }
    }

    /// @dev Freezes rates and clears pending entries covered by received settlement assets or written off.
    function _finalizeRequests() internal override {
        uint256 remainingAssets = IERC20(_asset).balanceOf(address(this));

        uint256 length = _pendingKeys.length;
        for (uint256 i = length; i > 0; --i) {
            uint256 index = i - 1;
            uint256 key = _pendingKeys[index];
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
            if (!writtenOff && (bucket.rate == 0 || remainingAssets < value)) {
                continue;
            }
            if (!writtenOff) {
                remainingAssets -= value;
            }

            bucket.pendingTokenToRedeem -= pendingCutoff.amount;
            delete pendingCutoffs[key];
            --length;
            _pendingKeys[index] = _pendingKeys[length];
            _pendingKeys.pop();
        }
    }

    /// @dev Transfers held Securitize tokens to the redemption wallet as the redemption notice.
    function _requestRedeem() internal override returns (bool) {
        uint256 amount = IERC20(TOKEN_TO_REDEEM).balanceOf(address(this));
        uint256 key = _nextPendingKey++;

        _pendingKeys.push(key);
        uint48 bucket = currentBucket();
        pendingCutoffs[key] = PendingCutoff({amount: amount, bucket: bucket});
        buckets[bucket].totalTokenToRedeem += amount;
        buckets[bucket].pendingTokenToRedeem += amount;
        IERC20(TOKEN_TO_REDEEM).safeTransfer(REDEMPTION_WALLET, amount);
        return true;
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
}

/// @title AcredSecuritizeAccount
/// @notice Contract for ACRED account with the published quarterly repurchase cutoff schedule.
contract AcredSecuritizeAccount is SecuritizeAccount, IAcredSecuritizeAccount {
    /* CONSTRUCTOR */

    /// @notice Creates the ACRED Securitize account implementation.
    constructor(
        address newOracle,
        address newFactory,
        address newTokenToRedeem,
        address newRedemptionWallet,
        uint48 newValuationDelay,
        uint48 newPostCutoffWindow,
        address newCowSwapSettlement
    )
        SecuritizeAccount(
            newOracle,
            newFactory,
            0,
            newTokenToRedeem,
            newRedemptionWallet,
            newValuationDelay,
            newPostCutoffWindow,
            newCowSwapSettlement
        )
    {}

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ICutoffAccount
    function timestampToBucket(uint48 timestamp)
        public
        pure
        override(CutoffAccount, ICutoffAccount)
        returns (uint48 bucket)
    {
        if (timestamp <= CUTOFF_0) {
            return 0;
        }
        if (timestamp <= CUTOFF_1) {
            return 1;
        }
        if (timestamp <= CUTOFF_2) {
            return 2;
        }
        if (timestamp <= CUTOFF_3) {
            return 3;
        }
        revert InvalidCutoff();
    }

    /// @inheritdoc ICutoffAccount
    function bucketToTimestamp(uint48 bucket)
        public
        pure
        override(CutoffAccount, ICutoffAccount)
        returns (uint48 timestamp)
    {
        if (bucket == 0) {
            return CUTOFF_0;
        }
        if (bucket == 1) {
            return CUTOFF_1;
        }
        if (bucket == 2) {
            return CUTOFF_2;
        }
        if (bucket == 3) {
            return CUTOFF_3;
        }
        revert InvalidCutoff();
    }
}
