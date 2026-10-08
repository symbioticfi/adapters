// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import {ActivityContext, ActivityPhaseScript} from "./ActivityContext.sol";
import {CutoffMidasAccount} from "src/contracts/ll-adapter/MidasAccount.sol";
import {TestnetAsyncVault, TestnetMidasRedemptionVault} from "../protocols/TestnetRedemptions.sol";
import {TestnetCatalog} from "../catalog/TestnetCatalog.sol";
import {
    TestnetOpenEdenExpress,
    TestnetProviderIssuer,
    TestnetSecuritizeOffRamp,
    TestnetSpikoRedemption
} from "../protocols/TestnetProviderRedemptions.sol";
import {TestnetPriceFeed, TestnetToken} from "../protocols/TestnetAssets.sol";

import {IAccount} from "src/interfaces/ll-adapter/IAccount.sol";
import {IAssetoAccount} from "src/interfaces/ll-adapter/asseto/IAssetoAccount.sol";
import {ICutoffAccount} from "src/interfaces/ll-adapter/ICutoffAccount.sol";
import {IPriceDataOracle} from "src/interfaces/ll-adapter/IPriceDataOracle.sol";
import {ISecuritizeAccount} from "src/interfaces/ll-adapter/securitize/ISecuritizeAccount.sol";
import {ISettlementAccount} from "src/interfaces/ll-adapter/ISettlementAccount.sol";
import {ISpikoAccount} from "src/interfaces/ll-adapter/spiko/ISpikoAccount.sol";
import {ISpikoRedemption} from "src/interfaces/ll-adapter/spiko/ISpikoRedemption.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ITestnetActiveRequests
 * @notice Interface for the fixture's authoritative count of unclosed issuer obligations.
 */
interface ITestnetActiveRequests {
    /* FUNCTIONS */

    /**
     * @notice Returns the number of requests awaiting settlement or rejection across this fixture.
     */
    function activeRequestCount() external view returns (uint256);
}

/**
 * @title IIssuerActivityScript
 * @notice Interface for bounded, owner-funded native issuer maintenance.
 */
interface IIssuerActivityScript {
    /* ERRORS */

    /**
     * @notice Raised when the supplied catalog kind or provider variant is inconsistent.
     */
    error InvalidProfile();

    /**
     * @notice Raised when a cutoff's historical feed has no valid earlier valuation.
     */
    error MissingCutoffPrice();

    /* EVENTS */

    /**
     * @notice Emitted when existing owner cash replenishes an issuer's settlement reserve.
     */
    event Fund(address indexed endpoint, uint256 assets);

    /**
     * @notice Emitted when one bounded maintenance pass finishes.
     */
    event RunBase(uint256 indexed profile, uint256 settled, uint256 nextCursor, uint256 spent);

    /* FUNCTIONS */

    /**
     * @notice Refreshes valuation, processes at most eight historical positions, and replenishes inventory.
     * @dev Funding never exceeds context.assets or the owner's existing cash. Insufficient funding leaves
     * requests open; no settlement failures are suppressed. The caller persists nextCursor per profile.
     */
    function runBase(ActivityContext memory context, bool broadcast) external returns (uint256 settled);

    /**
     * @notice Returns the next historical position to scan on the next maintenance pass.
     */
    function nextCursor() external view returns (uint256);

    /**
     * @notice Returns authoritative outstanding requests for the issuer or single-flight controller.
     * @dev Atomic VBILL has no pending entries. Centrifuge and Spiko expose one controller request;
     * issuer, OpenEden and Midas counts include every receiver on the owner-created fixture endpoint.
     */
    function pendingEntries(ActivityContext memory context) external view returns (uint256);
}

/// @title IssuerActivityScript
/// @notice Maintains synthetic issuer dependencies through their native funded redemption lifecycle.
/// @dev Historical scans are cyclic and bounded to eight positions; closed and immature positions still
/// advance the cursor. Cutoff Midas uses at most 80 binary-search steps and publishes at most once daily.
contract IssuerActivityScript is ActivityPhaseScript, IIssuerActivityScript {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /* STATE VARIABLES */

    /// @inheritdoc IIssuerActivityScript
    uint256 public nextCursor;

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IIssuerActivityScript
    function runBase(ActivityContext memory context, bool broadcast) public returns (uint256 settled) {
        TestnetCatalog.Profile memory profile = TestnetCatalog.profile(context.profile);
        if (profile.mechanism > 4 || profile.mechanism != context.kind || profile.variant != context.variant) {
            revert InvalidProfile();
        }
        uint256 remaining = context.assets;
        nextCursor = 0;
        _start(context.owner, broadcast);

        // Read the raw round even when stale, then publish a small deterministic movement within native bounds.
        (, int256 answer,, uint256 updatedAt,) = TestnetPriceFeed(context.feed).latestRoundData();
        uint256 multiplier = 10 ** (18 - TestnetPriceFeed(context.feed).decimals());
        uint256 price = uint256(answer) * multiplier;
        // Settlement subaccounts freeze their valuation after the issuer's quote was locked. Keeping the
        // publication unchanged while a quote is live avoids creating an artificial underpayment gap.
        if (
            context.kind != 4 || (context.variant != 3 && context.variant != 4)
                || ITestnetActiveRequests(context.endpoint).activeRequestCount() == 0
        ) price = price.mulDiv(9998 + context.seed % 5, 10_000);
        price = Math.min(Math.max(price, profile.minPrice), profile.maxPrice);
        // Cutoff Midas reads historical prints backwards in production NAV. A daily cadence bounds
        // post-cutoff history while remaining comfortably inside the fixture's 30-hour freshness limit.
        if (context.kind != 2 || block.timestamp >= updatedAt + 1 days) {
            TestnetPriceFeed(context.feed).publish(int256(price / multiplier));
        }
        price = TestnetPriceFeed(context.feed).getDataInBase18();

        if (context.kind == 4 && context.variant == 2) {
            uint256 shares = IERC20(context.token).balanceOf(context.account);
            uint256 quote =
                shares > 0 ? TestnetSecuritizeOffRamp(context.endpoint).calculateLiquidityTokenAmount(shares) : 0;
            remaining = _fund(context, quote, remaining);
            if (IERC20(context.asset).balanceOf(context.endpoint) >= quote) {
                IAccount(context.account).sync();
                if (shares > 0) settled = 1;
            }
        } else {
            // A single-flight ERC-7540 request may coexist with newly received shares, which wait until fulfillment.
            if (
                context.kind != 3 || TestnetAsyncVault(context.endpoint).pending(context.account) == 0
                    || IERC20(context.token).balanceOf(context.account) == 0
            ) IAccount(context.account).sync();

            if (context.kind < 3) {
                uint256 count = TestnetMidasRedemptionVault(context.endpoint).nextRequestId();
                if (count > 0) {
                    nextCursor = context.cursor % count;
                    uint256 positions = Math.min(count, 8);
                    for (uint256 i; i < positions; ++i) {
                        uint256 id = nextCursor;
                        nextCursor = id + 1 == count ? 0 : id + 1;
                        TestnetMidasRedemptionVault.Request memory request;
                        (
                            request.sender,
                            request.tokenOut,
                            request.status,
                            request.amountMToken,
                            request.mTokenRate,
                            request.tokenOutRate
                        ) = TestnetMidasRedemptionVault(context.endpoint).redeemRequests(id);
                        if (
                            request.status > 0
                                || block.timestamp < TestnetMidasRedemptionVault(context.endpoint).readyAt(id)
                        ) {
                            continue;
                        }
                        uint256 rate = context.kind == 0 ? price : request.mTokenRate;
                        if (context.kind == 2) {
                            uint48 cutoff = ICutoffAccount(request.sender)
                                .bucketToTimestamp(CutoffMidasAccount(request.sender).requestToBucket(uint64(id)) + 1);
                            if (block.timestamp < cutoff) continue;
                            // Fixture round timestamps are monotonically increasing. Search for the last print strictly
                            // before the cohort cutoff, preserving the production account's exact boundary convention.
                            uint256 low = 1;
                            uint256 high = TestnetPriceFeed(context.feed).latestRound();
                            uint256 selected;
                            for (uint256 step; low <= high && step < 80; ++step) {
                                uint256 middle = low + (high - low) / 2;
                                (, uint48 timestamp) = TestnetPriceFeed(context.feed).rounds(uint80(middle));
                                if (timestamp < cutoff) {
                                    selected = middle;
                                    low = middle + 1;
                                } else {
                                    high = middle - 1;
                                }
                            }
                            if (selected == 0) revert MissingCutoffPrice();
                            (int256 cutoffAnswer,) = TestnetPriceFeed(context.feed).rounds(uint80(selected));
                            if (cutoffAnswer <= 0) revert MissingCutoffPrice();
                            rate = uint256(cutoffAnswer) * multiplier;
                        }
                        uint256 payout = request.amountMToken
                            .mulDiv(
                                rate * 10 ** IERC20Metadata(context.asset).decimals(),
                                1e18 * 10 ** IERC20Metadata(context.token).decimals()
                            );
                        remaining = _fund(context, payout, remaining);
                        if (IERC20(context.asset).balanceOf(context.endpoint) < payout) continue;
                        TestnetMidasRedemptionVault(context.endpoint).settleRequest(id, rate);
                        ++settled;
                    }
                }
            } else if (context.kind == 3) {
                uint256 shares = TestnetAsyncVault(context.endpoint).pending(context.account);
                if (shares > 0 && block.timestamp >= TestnetAsyncVault(context.endpoint).readyAt(context.account)) {
                    uint256 required = TestnetAsyncVault(context.endpoint).reservedAssets()
                        + TestnetAsyncVault(context.endpoint).convertToAssets(shares);
                    remaining = _fund(context, required, remaining);
                    if (IERC20(context.asset).balanceOf(context.endpoint) >= required) {
                        TestnetAsyncVault(context.endpoint).fulfill(context.account);
                        settled = 1;
                    }
                }
            } else if (context.variant == 5) {
                bytes32 id = ISpikoAccount(context.account).pendingId();
                if (id != bytes32(0)) {
                    (,, uint256 quote, uint48 requestedAt, uint48 deadline, ISpikoRedemption.Status status) =
                        TestnetSpikoRedemption(context.endpoint).requests(id);
                    if (
                        status == ISpikoRedemption.Status.PENDING && block.timestamp >= requestedAt + 1 hours
                            && block.timestamp < deadline
                    ) {
                        remaining = _fund(context, quote, remaining);
                        if (IERC20(context.asset).balanceOf(context.endpoint) >= quote) {
                            TestnetSpikoRedemption(context.endpoint).settle(id, quote);
                            settled = 1;
                        }
                    }
                }
            } else if (context.variant == 7) {
                uint256 count = TestnetOpenEdenExpress(context.endpoint).requestCount();
                if (count > 0) {
                    nextCursor = context.cursor % count;
                    uint256 positions = Math.min(count, 8);
                    for (uint256 i; i < positions; ++i) {
                        uint256 id = nextCursor;
                        nextCursor = id + 1 == count ? 0 : id + 1;
                        TestnetOpenEdenExpress.RequestData memory request;
                        (
                            request.sender,
                            request.receiver,
                            request.tokenAmount,
                            request.grossAssets,
                            request.feeAssets,
                            request.requestedAt,
                            request.stage
                        ) = TestnetOpenEdenExpress(context.endpoint).requests(id);
                        if (request.stage == 1 && block.timestamp >= request.requestedAt + 1 days) {
                            TestnetOpenEdenExpress(context.endpoint).lock(id);
                            (request.feeAssets, request.grossAssets,) =
                                TestnetOpenEdenExpress(context.endpoint).previewRedeem(request.tokenAmount);
                            request.stage = 2;
                        }
                        if (request.stage != 2 || block.timestamp < request.requestedAt + 2 days) continue;
                        uint256 payout = request.grossAssets - request.feeAssets;
                        remaining = _fund(context, payout, remaining);
                        if (IERC20(context.asset).balanceOf(context.endpoint) < payout) continue;
                        TestnetOpenEdenExpress(context.endpoint).settle(id, payout);
                        ++settled;
                    }
                }
            } else {
                uint256 count = TestnetProviderIssuer(context.endpoint).requestCount();
                if (count > 0) {
                    nextCursor = context.cursor % count;
                    uint256 positions = Math.min(count, 8);
                    for (uint256 i; i < positions; ++i) {
                        uint256 id = nextCursor;
                        nextCursor = id + 1 == count ? 0 : id + 1;
                        TestnetProviderIssuer.RequestData memory request;
                        (request.receiver, request.tokenAmount, request.quotedAssets, request.readyAt, request.closed) =
                            TestnetProviderIssuer(context.endpoint).requests(id);
                        if (request.closed || block.timestamp < request.readyAt) continue;
                        uint256 payout = request.quotedAssets;
                        if (payout == 0) {
                            // Other native cutoff accounts share this endpoint and must freeze their own bucket
                            // before a funded transfer can be reconciled against its valuation.
                            if (request.receiver != context.account) IAccount(request.receiver).sync();
                            uint48 bucket = ICutoffAccount(request.receiver)
                                .timestampToBucket(
                                    request.readyAt - (context.variant == 6 ? uint48(1 days) : uint48(4 days))
                                );
                            uint256 frozen;
                            if (context.variant == 6) (,, frozen) = IAssetoAccount(request.receiver).buckets(bucket);
                            else (,, frozen) = ISecuritizeAccount(request.receiver).buckets(bucket);
                            if (frozen == 0) {
                                uint48 valuationAt;
                                (frozen, valuationAt) = IPriceDataOracle(context.oracle).getPriceData();
                                if (valuationAt < request.readyAt) continue;
                            }
                            payout = request.tokenAmount
                                .mulDiv(
                                    frozen * 10 ** IERC20Metadata(context.asset).decimals(),
                                    1e18 * 10 ** IERC20Metadata(context.token).decimals()
                                );
                        }
                        remaining = _fund(context, payout, remaining);
                        if (IERC20(context.asset).balanceOf(context.endpoint) < payout) continue;
                        TestnetProviderIssuer(context.endpoint).settle(id, payout);
                        if (
                            (context.variant == 3 || context.variant == 4)
                                && ISettlementAccount(context.account).isSubAccount(request.receiver)
                        ) {
                            (uint256 pending,) =
                                ISettlementAccount(context.account).pendingCutoffs(uint160(request.receiver));
                            // Released subaccounts remain issuer receivers. Use the production late-funds rescue
                            // when the parent's write-off already removed this entry before the payout arrived.
                            if (pending == 0) ISettlementAccount(context.account).rescueSubAccount(request.receiver);
                        }
                        ++settled;
                    }
                }
            }
            if (
                context.kind != 3 || TestnetAsyncVault(context.endpoint).pending(context.account) == 0
                    || IERC20(context.token).balanceOf(context.account) == 0
            ) IAccount(context.account).sync();
        }

        uint256 target = context.assets
            .mulDiv(
                1e18 * 10 ** IERC20Metadata(context.token).decimals(),
                price * 10 ** IERC20Metadata(context.asset).decimals()
            );
        uint256 inventory = IERC20(context.token).balanceOf(context.owner);
        if (target > inventory) {
            uint256 shares = target - inventory;
            if (context.kind == 3) {
                uint256 available = Math.min(remaining, IERC20(context.asset).balanceOf(context.owner));
                shares =
                    Math.min(shares, available.mulDiv(1e36, price * 10 ** IERC20Metadata(context.asset).decimals()));
                if (shares > 0) {
                    uint256 cost = TestnetAsyncVault(context.endpoint).convertToAssets(shares);
                    IERC20(context.asset).forceApprove(context.endpoint, cost);
                    TestnetAsyncVault(context.endpoint).mint(context.owner, shares);
                    IERC20(context.asset).forceApprove(context.endpoint, 0);
                    remaining -= cost;
                }
            } else {
                TestnetToken(context.token).mint(context.owner, shares);
            }
        }
        // Keep a budget-sized reserve ready for future requests after giving matured payouts priority.
        remaining = _fund(context, context.assets, remaining);
        _stop(broadcast);
        emit RunBase(context.profile, settled, nextCursor, context.assets - remaining);
    }

    /// @inheritdoc IIssuerActivityScript
    function pendingEntries(ActivityContext memory context) public view returns (uint256) {
        TestnetCatalog.Profile memory profile = TestnetCatalog.profile(context.profile);
        if (profile.mechanism > 4 || profile.mechanism != context.kind || profile.variant != context.variant) {
            revert InvalidProfile();
        }
        if (context.kind == 3) {
            return TestnetAsyncVault(context.endpoint).pending(context.account) > 0
                || TestnetAsyncVault(context.endpoint).claimable(context.account) > 0
                ? 1
                : 0;
        }
        if (context.kind == 4 && context.variant == 2) return 0;
        if (context.kind == 4 && context.variant == 5) {
            return ISpikoAccount(context.account).pendingId() != bytes32(0) ? 1 : 0;
        }
        return ITestnetActiveRequests(context.endpoint).activeRequestCount();
    }

    /* INTERNAL FUNCTIONS */

    function _fund(ActivityContext memory context, uint256 required, uint256 remaining) internal returns (uint256) {
        uint256 cash = IERC20(context.asset).balanceOf(context.endpoint);
        if (cash < required && remaining > 0) {
            uint256 amount =
                Math.min(required - cash, Math.min(remaining, IERC20(context.asset).balanceOf(context.owner)));
            if (amount > 0) {
                IERC20(context.asset).safeTransfer(context.endpoint, amount);
                remaining -= amount;
                emit Fund(context.endpoint, amount);
            }
        }
        return remaining;
    }
}
