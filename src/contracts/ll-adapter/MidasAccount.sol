// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {CooldownAccount} from "./common/CooldownAccount.sol";
import {CutoffAccount} from "./common/CutoffAccount.sol";

import {IAggregatorV3} from "./oracles/libraries/ChainlinkPriceFeed.sol";

import {ICutoffAccount} from "../../interfaces/ll-adapter/ICutoffAccount.sol";
import {IMidasAccount, REQUEST_STATUS_PENDING} from "../../interfaces/ll-adapter/midas/IMidasAccount.sol";
import {IMidasDataFeed, IMidasOracle} from "../../interfaces/ll-adapter/midas/IMidasOracle.sol";
import {IMidasRedemptionVault} from "../../interfaces/ll-adapter/midas/IMidasRedemptionVault.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {DateTimeLib} from "solady/utils/DateTimeLib.sol";

/// @title MidasAccount
/// @notice Base contract for Midas redemption integrations.
abstract contract MidasAccount is CooldownAccount, IMidasAccount {
    using SafeERC20 for IERC20;

    /* IMMUTABLES */

    /// @inheritdoc IMidasAccount
    address public immutable REDEMPTION_TOKEN;

    /// @inheritdoc IMidasAccount
    address public immutable REDEMPTION_VAULT;

    /* STATE VARIABLES */

    /// @inheritdoc IMidasAccount
    uint64[] public requestIds;

    /// @dev Reserved storage gap for future upgrades.
    uint256[50] private __gap;

    /* CONSTRUCTOR */

    /// @dev Creates the Midas account implementation.
    constructor(
        address newOracle,
        address newFactory,
        uint48 newCooldown,
        address newTokenToRedeem,
        address newRedemptionToken,
        address newRedemptionVault,
        address newCowSwapSettlement
    ) CooldownAccount(newOracle, newFactory, newCooldown, newTokenToRedeem, newCowSwapSettlement) {
        REDEMPTION_TOKEN = newRedemptionToken;
        REDEMPTION_VAULT = newRedemptionVault;
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Returns pending request value in vault assets.
    function _pendingAssets() internal view virtual returns (uint256);

    /// @dev Returns held fallback redemption-token value plus pending request value in vault assets.
    function _totalAssets() internal view override returns (uint256 assets) {
        if (REDEMPTION_TOKEN != _asset) {
            assets += _redemptionTokenToAssets(REDEMPTION_TOKEN, IERC20(REDEMPTION_TOKEN).balanceOf(address(this)));
        }

        assets += _pendingAssets();
    }

    /// @dev Clears Midas redemption requests that are no longer pending.
    function _finalizeRequests() internal virtual override {
        uint256 length = requestIds.length;
        for (uint256 i = length; i > 0; --i) {
            (,, uint8 status,,,) = IMidasRedemptionVault(REDEMPTION_VAULT).redeemRequests(requestIds[i - 1]);
            if (status == REQUEST_STATUS_PENDING) {
                continue;
            }
            requestIds[i - 1] = requestIds[--length];
            requestIds.pop();
        }
    }

    /// @dev Submits held token-to-redeem inventory to the Midas redemption vault.
    function _requestRedeem() internal virtual override returns (bool) {
        (address dataFeed,,,) = IMidasRedemptionVault(REDEMPTION_VAULT).tokensConfig(_asset);
        requestIds.push(
            uint64(
                IMidasRedemptionVault(REDEMPTION_VAULT)
                    .redeemRequest(
                        dataFeed == address(0) ? REDEMPTION_TOKEN : _asset,
                        IERC20(TOKEN_TO_REDEEM).balanceOf(address(this))
                    )
            )
        );
        return true;
    }

    /// @dev Initializes the account for an adapter and vault.
    function _initialize(uint64 initialVersion, address initOwner, bytes memory data) internal virtual override {
        super._initialize(initialVersion, initOwner, data);

        IERC20(TOKEN_TO_REDEEM).forceApprove(REDEMPTION_VAULT, type(uint256).max);
    }
}

/// @title MidasCompAccount
/// @notice Midas account contract that prices pending requests at the current oracle rate.
contract MidasCompAccount is MidasAccount {
    /* CONSTRUCTOR */

    /// @notice Creates the compounding Midas account implementation.
    constructor(
        address newOracle,
        address newFactory,
        uint48 newCooldown,
        address newTokenToRedeem,
        address newRedemptionToken,
        address newRedemptionVault,
        address newCowSwapSettlement
    )
        MidasAccount(
            newOracle,
            newFactory,
            newCooldown,
            newTokenToRedeem,
            newRedemptionToken,
            newRedemptionVault,
            newCowSwapSettlement
        )
    {}

    /* INTERNAL FUNCTIONS */

    /// @dev Returns pending request value using the current oracle rate.
    function _pendingAssets() internal view override returns (uint256) {
        uint256 amount;
        uint256 length = requestIds.length;
        for (uint256 i; i < length; ++i) {
            (,, uint8 status, uint256 amountMToken,,) =
                IMidasRedemptionVault(REDEMPTION_VAULT).redeemRequests(requestIds[i]);
            if (status == REQUEST_STATUS_PENDING) {
                amount += amountMToken;
            }
        }
        return _tokenToRedeemToAssets(amount);
    }
}

/// @title MidasNonCompAccount
/// @notice Midas account contract that prices pending requests at their creation-time rate.
contract MidasNonCompAccount is MidasAccount {
    using Math for uint256;

    /* CONSTRUCTOR */

    /// @notice Creates the non-compounding Midas account implementation.
    constructor(
        address newOracle,
        address newFactory,
        uint48 newCooldown,
        address newTokenToRedeem,
        address newRedemptionToken,
        address newRedemptionVault,
        address newCowSwapSettlement
    )
        MidasAccount(
            newOracle,
            newFactory,
            newCooldown,
            newTokenToRedeem,
            newRedemptionToken,
            newRedemptionVault,
            newCowSwapSettlement
        )
    {}

    /* INTERNAL FUNCTIONS */

    /// @dev Returns pending request value using each request's locked rate.
    function _pendingAssets() internal view override returns (uint256 assets) {
        uint256 length = requestIds.length;
        for (uint256 i; i < length; ++i) {
            (,, uint8 status, uint256 amountMToken, uint256 mTokenRate, uint256 tokenOutRate) =
                IMidasRedemptionVault(REDEMPTION_VAULT).redeemRequests(requestIds[i]);
            if (status == REQUEST_STATUS_PENDING) {
                assets += _tokenToRedeemToAssets(amountMToken, mTokenRate) * 1e18 / tokenOutRate;
            }
        }
    }
}

/// @title CutoffMidasAccount
/// @notice Midas account contract for cutoff-cohort redemptions: pending requests compound until the cohort
/// boundary, then use the latest valid vault-feed print before the next cohort cutoff.
contract CutoffMidasAccount is MidasAccount, CutoffAccount {
    /* IMMUTABLES */

    /// @dev Cutoff day for monthly schedules.
    uint256 public immutable CUTOFF_DAY;

    /// @dev Cutoff hour for monthly schedules.
    uint256 public immutable CUTOFF_HOUR;

    /// @dev Initial cutoff year for monthly schedules.
    uint256 public immutable INITIAL_YEAR;

    /// @dev Initial cutoff month for monthly schedules.
    uint256 public immutable INITIAL_MONTH;

    /// @dev Initial cutoff timestamp.
    uint48 internal immutable _INITIAL_CUTOFF;

    /// @dev Window before a cutoff during which new requests may be submitted.
    uint48 internal immutable _PRE_CUTOFF_WINDOW;

    /* STATE VARIABLES */

    /// @dev Redemption request bucket.
    mapping(uint64 requestId => uint48 bucket) public requestToBucket;

    /* CONSTRUCTOR */

    /// @notice Creates the cutoff-cohort Midas account implementation.
    constructor(
        address newOracle,
        address newFactory,
        uint48 newCooldown,
        uint48 newInitialCutoff,
        address newTokenToRedeem,
        uint48 newPreCutoffWindow,
        address newRedemptionToken,
        address newRedemptionVault,
        address newCowSwapSettlement
    )
        MidasAccount(
            newOracle,
            newFactory,
            newCooldown,
            newTokenToRedeem,
            newRedemptionToken,
            newRedemptionVault,
            newCowSwapSettlement
        )
    {
        _INITIAL_CUTOFF = newInitialCutoff;
        _PRE_CUTOFF_WINDOW = newPreCutoffWindow;
        (INITIAL_YEAR, INITIAL_MONTH, CUTOFF_DAY, CUTOFF_HOUR,,) = DateTimeLib.timestampToDateTime(newInitialCutoff);
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ICutoffAccount
    function timestampToBucket(uint48 timestamp) public view override returns (uint48 bucket) {
        if (timestamp < _INITIAL_CUTOFF) {
            return 0;
        }

        (uint256 year, uint256 month,) = DateTimeLib.timestampToDate(timestamp);
        bucket = uint48((year - INITIAL_YEAR) * 12 + month - INITIAL_MONTH);
        if (timestamp >= DateTimeLib.dateTimeToTimestamp(year, month, CUTOFF_DAY, CUTOFF_HOUR, 0, 0)) {
            ++bucket;
        }
    }

    /// @inheritdoc ICutoffAccount
    function bucketToTimestamp(uint48 bucket) public view override returns (uint48 timestamp) {
        if (bucket == 0) {
            return 0;
        }

        uint256 month = INITIAL_MONTH + bucket - 2;
        return uint48(
            DateTimeLib.dateTimeToTimestamp(INITIAL_YEAR + month / 12, month % 12 + 1, CUTOFF_DAY, CUTOFF_HOUR, 0, 0)
        );
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Finalizes existing requests and submits a new request only inside the pre-cutoff window.
    function _sync() internal virtual override {
        _finalizeRequests();

        if (
            (owner() == msg.sender
                    || (block.timestamp + _PRE_CUTOFF_WINDOW >= nextCutoff()
                        && (lastRequestTimestamp == 0 || block.timestamp >= lastRequestTimestamp + COOLDOWN)))
                && IERC20(TOKEN_TO_REDEEM).balanceOf(address(this)) > 0
        ) {
            _requestRedeem();
            lastRequestTimestamp = uint48(block.timestamp);
        }
    }

    function _requestRedeem() internal virtual override returns (bool) {
        super._requestRedeem();
        requestToBucket[requestIds[requestIds.length - 1]] = currentBucket();
        return true;
    }

    /// @dev Returns pending request value priced by cutoff cohorts. Fulfilled-but-unsynced requests are
    /// skipped: Midas pays the assets and marks the request processed atomically, and the stale
    /// cohort entry is only cleared on the next sync.
    function _pendingAssets() internal view override returns (uint256 assets) {
        address aggregator;
        uint256 multiplier;
        uint80 latestRoundId;
        int256 latestAnswer;
        uint256 latestTimestamp;
        uint256 length = requestIds.length;
        for (uint256 i; i < length; ++i) {
            uint64 requestId = requestIds[i];
            (,, uint8 status, uint256 amountMToken,,) =
                IMidasRedemptionVault(REDEMPTION_VAULT).redeemRequests(requestId);
            if (status == REQUEST_STATUS_PENDING) {
                if (aggregator == address(0)) {
                    // Call getPrice() to trigger oracle validation checks.
                    IMidasOracle(ORACLE).getPrice();
                    aggregator = IMidasDataFeed(IMidasOracle(ORACLE).DATA_FEED()).aggregator();
                    multiplier = 10 ** (18 - IAggregatorV3(aggregator).decimals());
                    (latestRoundId, latestAnswer,, latestTimestamp,) = IAggregatorV3(aggregator).latestRoundData();
                }
                int256 answer = latestAnswer;
                uint80 roundId = latestRoundId;
                uint256 timestamp = latestTimestamp;
                uint48 nextBucketTimestamp = bucketToTimestamp(requestToBucket[requestId] + 1);
                while (timestamp >= nextBucketTimestamp) {
                    (, answer,, timestamp,) = IAggregatorV3(aggregator).getRoundData(--roundId);
                }
                if (answer <= 0 || timestamp == 0) revert InvalidCutoffPrice();

                assets += _tokenToRedeemToAssets(amountMToken, uint256(answer) * multiplier);
            }
        }
    }
}
