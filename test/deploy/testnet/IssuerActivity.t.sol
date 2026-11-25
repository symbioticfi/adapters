// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import {AsyncRedeemOracle} from "src/contracts/ll-adapter/oracles/AsyncRedeemOracle.sol";
import {CutoffMidasAccount, MidasCompAccount, MidasNonCompAccount} from "src/contracts/ll-adapter/MidasAccount.sol";
import {MidasOracle} from "src/contracts/ll-adapter/oracles/MidasOracle.sol";

import {IAccount} from "src/interfaces/ll-adapter/IAccount.sol";
import {ICutoffAccount} from "src/interfaces/ll-adapter/ICutoffAccount.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

import {ActivityContext} from "script/deploy/testnet/activity/ActivityContext.sol";
import {IIssuerActivityScript, IssuerActivityScript} from "script/deploy/testnet/activity/IssuerActivity.s.sol";
import {TestnetAsyncAccount} from "script/deploy/testnet/protocols/TestnetAsyncAccount.sol";
import {TestnetAsyncVault, TestnetMidasRedemptionVault} from "script/deploy/testnet/protocols/TestnetRedemptions.sol";
import {TestnetCatalog} from "script/deploy/testnet/catalog/TestnetCatalog.sol";
import {TestnetCowSettlement} from "script/deploy/testnet/protocols/TestnetServices.sol";
import {
    TestnetOpenEdenExpress,
    TestnetProviderDeploymentScript
} from "script/deploy/testnet/protocols/TestnetProviderRedemptions.sol";
import {TestnetPriceFeed, TestnetToken} from "script/deploy/testnet/protocols/TestnetAssets.sol";

/// @title IssuerActivityVault
/// @notice Exposes the asset used by genuine production account clone initialization.
contract IssuerActivityVault {
    address public immutable asset;

    constructor(address newAsset) {
        asset = newAsset;
    }
}

/// @title IssuerActivityTest
/// @notice Verifies bounded funded maintenance through genuine Midas, Centrifuge and all provider accounts.
contract IssuerActivityTest is Test {
    address internal _activity;

    function setUp() public {
        vm.warp(1_790_000_000);
        _activity = address(new IssuerActivityScript());
    }

    function testOpenEdenUsesNativeReadinessCustodyAndFundedPayout() public {
        ActivityContext memory context = _openEden();
        assertEq(IssuerActivityScript(_activity).pendingEntries(context), 0);
        (,, uint256 expected) =
            TestnetOpenEdenExpress(context.endpoint).previewRedeem(IERC20(context.token).balanceOf(context.account));
        uint256 started = vm.getBlockTimestamp();
        uint256 ownerCash = IERC20(context.asset).balanceOf(address(this));
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 0);
        assertEq(vm.getBlockTimestamp(), started);
        assertLe(ownerCash - IERC20(context.asset).balanceOf(address(this)), context.assets);
        assertEq(IERC20(context.token).balanceOf(context.account), 0);
        assertEq(IssuerActivityScript(_activity).pendingEntries(context), 1);

        vm.warp(started + 2 days);
        ownerCash = IERC20(context.asset).balanceOf(address(this));
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 1);
        assertLe(ownerCash - IERC20(context.asset).balanceOf(address(this)), context.assets);
        assertEq(IERC20(context.asset).balanceOf(context.account), expected);
        assertEq(IssuerActivityScript(_activity).pendingEntries(context), 0);
        assertEq(IERC20(context.token).balanceOf(context.endpoint), 0);
        assertGt(IERC20(context.token).balanceOf(address(this)), 0);
        assertEq(TestnetOpenEdenExpress(context.endpoint).getRedeemQueueLength(), 0);
    }

    function testMidasCompoundsWhileNonCompPreservesTheCreationRateAndFee() public {
        for (uint8 kind; kind < 2; ++kind) {
            ActivityContext memory context = _midas(kind);
            IssuerActivityScript(_activity).runBase(context, false);
            (,,, uint256 netShares, uint256 originalRate,) =
                TestnetMidasRedemptionVault(context.endpoint).redeemRequests(0);
            assertEq(netShares, 9.99e18);
            assertEq(IERC20(context.token).balanceOf(context.endpoint), 10e18);
            vm.warp(TestnetMidasRedemptionVault(context.endpoint).readyAt(0));
            TestnetPriceFeed(context.feed).publish(2e18);
            assertEq(IssuerActivityScript(_activity).runBase(context, false), 1);
            (,, uint8 status,, uint256 approvedRate,) = TestnetMidasRedemptionVault(context.endpoint).redeemRequests(0);
            assertEq(status, 1);
            assertEq(approvedRate, kind == 0 ? 2e18 : originalRate);
            assertEq(IERC20(context.asset).balanceOf(context.account), netShares * approvedRate * 1e6 / 1e36);
            assertEq(IERC20(context.token).balanceOf(context.endpoint), 0.01e18);
            assertEq(IssuerActivityScript(_activity).pendingEntries(context), 0);
        }
    }

    function testCutoffMidasChoosesTheLastStrictlyPreCutoffRoundThroughLongHistory() public {
        ActivityContext memory context = _midas(2);
        IssuerActivityScript(_activity).runBase(context, false);
        uint48 cutoff = ICutoffAccount(context.account)
            .bucketToTimestamp(CutoffMidasAccount(context.account).requestToBucket(0) + 1);
        vm.warp(cutoff - 1);
        TestnetPriceFeed(context.feed).publish(1.2e18);
        vm.warp(cutoff);
        TestnetPriceFeed(context.feed).publish(1.4e18);
        for (uint256 i; i < 100; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1);
            TestnetPriceFeed(context.feed).publish(1.5e18);
        }
        vm.warp(TestnetMidasRedemptionVault(context.endpoint).readyAt(0));
        uint256 started = vm.getBlockTimestamp();
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 1);
        assertEq(vm.getBlockTimestamp(), started);
        (,,,, uint256 approvedRate,) = TestnetMidasRedemptionVault(context.endpoint).redeemRequests(0);
        assertEq(approvedRate, 1.2e18);
        assertEq(IERC20(context.asset).balanceOf(context.account), 11.988e6);
    }

    function testCutoffMidasPublicationCadencePreservesFreshnessWithoutGrowingEveryTick() public {
        ActivityContext memory context = _midas(2);
        uint80 firstRound = TestnetPriceFeed(context.feed).latestRound();
        IssuerActivityScript(_activity).runBase(context, false);
        assertEq(TestnetPriceFeed(context.feed).latestRound(), firstRound);
        vm.warp(vm.getBlockTimestamp() + 23 hours);
        IssuerActivityScript(_activity).runBase(context, false);
        assertEq(TestnetPriceFeed(context.feed).latestRound(), firstRound);
        assertGt(TestnetPriceFeed(context.feed).getDataInBase18(), 0);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        IssuerActivityScript(_activity).runBase(context, false);
        assertEq(TestnetPriceFeed(context.feed).latestRound(), firstRound + 1);
        (, uint48 publishedAt) = TestnetPriceFeed(context.feed).rounds(firstRound + 1);
        assertEq(publishedAt, vm.getBlockTimestamp());
    }

    function testMidasActiveCounterTracksApprovalRejectionAndCannotDoubleClose() public {
        ActivityContext memory context = _midas(0);
        assertEq(IssuerActivityScript(_activity).pendingEntries(context), 0);
        IssuerActivityScript(_activity).runBase(context, false);
        assertEq(IssuerActivityScript(_activity).pendingEntries(context), 1);
        vm.warp(TestnetMidasRedemptionVault(context.endpoint).readyAt(0));
        TestnetMidasRedemptionVault(context.endpoint).approveRequest(0);
        assertEq(IssuerActivityScript(_activity).pendingEntries(context), 0);
        vm.expectRevert(TestnetMidasRedemptionVault.InvalidRequest.selector);
        TestnetMidasRedemptionVault(context.endpoint).approveRequest(0);
        IAccount(context.account).sync();
        TestnetToken(context.token).mint(context.account, 10e18);
        IAccount(context.account).sync();
        assertEq(IssuerActivityScript(_activity).pendingEntries(context), 1);
        TestnetMidasRedemptionVault(context.endpoint).rejectRequest(1);
        assertEq(IssuerActivityScript(_activity).pendingEntries(context), 0);
        vm.expectRevert(TestnetMidasRedemptionVault.InvalidRequest.selector);
        TestnetMidasRedemptionVault(context.endpoint).rejectRequest(1);
        assertEq(IssuerActivityScript(_activity).pendingEntries(context), 0);
    }

    function testCyclicCursorSkipsClosedHistoryAndSettlesAtMostEightPositions() public {
        ActivityContext memory context = _midas(0);
        vm.prank(context.account);
        TestnetToken(context.token).burn(10e18);
        TestnetToken(context.token).mint(address(this), 180e18);
        IERC20(context.token).approve(context.endpoint, type(uint256).max);
        for (uint256 i; i < 18; ++i) {
            TestnetMidasRedemptionVault(context.endpoint).redeemRequest(context.asset, 10e18);
        }
        for (uint256 i; i < 8; ++i) {
            TestnetMidasRedemptionVault(context.endpoint).rejectRequest(i);
        }
        assertEq(IssuerActivityScript(_activity).pendingEntries(context), 10);
        vm.warp(TestnetMidasRedemptionVault(context.endpoint).readyAt(17));
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 0);
        assertEq(IssuerActivityScript(_activity).nextCursor(), 8);
        context.cursor = IssuerActivityScript(_activity).nextCursor();
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 8);
        assertEq(IssuerActivityScript(_activity).nextCursor(), 16);
        assertEq(IssuerActivityScript(_activity).pendingEntries(context), 2);
        context.cursor = IssuerActivityScript(_activity).nextCursor();
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 2);
        assertEq(IssuerActivityScript(_activity).nextCursor(), 6);
        assertEq(IssuerActivityScript(_activity).pendingEntries(context), 0);
    }

    function testOpenEdenCursorCountsPendingAndLockedRequestsAcrossClosedHistory() public {
        ActivityContext memory context = _openEden();
        vm.prank(context.account);
        TestnetToken(context.token).burn(10e18);
        TestnetToken(context.token).mint(address(this), 180e18);
        IERC20(context.token).approve(context.endpoint, type(uint256).max);
        for (uint256 i; i < 18; ++i) {
            TestnetOpenEdenExpress(context.endpoint).requestRedeem(address(this), 10e18);
        }
        vm.warp(vm.getBlockTimestamp() + 2 days);
        TestnetPriceFeed(context.feed).publish(1.08e18);
        IERC20(context.asset).transfer(context.endpoint, 1000e6);
        for (uint256 i; i < 8; ++i) {
            TestnetOpenEdenExpress(context.endpoint).lock(i);
            (,, uint256 quote) = TestnetOpenEdenExpress(context.endpoint).previewRedeem(10e18);
            TestnetOpenEdenExpress(context.endpoint).settle(i, quote);
        }
        assertEq(IssuerActivityScript(_activity).pendingEntries(context), 10);
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 0);
        context.cursor = IssuerActivityScript(_activity).nextCursor();
        assertEq(context.cursor, 8);
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 8);
        context.cursor = IssuerActivityScript(_activity).nextCursor();
        assertEq(IssuerActivityScript(_activity).pendingEntries(context), 2);
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 2);
        assertEq(IssuerActivityScript(_activity).pendingEntries(context), 0);
        assertEq(TestnetOpenEdenExpress(context.endpoint).getRedeemQueueLength(), 0);
    }

    function testOpenEdenLockedFinalQuoteSurvivesLaterValuationChanges() public {
        ActivityContext memory context = _openEden();
        IssuerActivityScript(_activity).runBase(context, false);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 0);
        (,,, uint256 gross, uint256 fee,, uint8 stage) = TestnetOpenEdenExpress(context.endpoint).requests(0);
        assertEq(stage, 2);
        TestnetPriceFeed(context.feed).publish(2e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 1);
        assertEq(IERC20(context.asset).balanceOf(context.account), gross - fee);
    }

    function testAsyncReservedCashCannotFundAnotherControllerAndHeldSharesWait() public {
        ActivityContext memory context = _async();
        address other = makeAddr("other controller");
        IERC20(context.asset).approve(context.endpoint, type(uint256).max);
        TestnetAsyncVault(context.endpoint).mint(other, 20e18);
        vm.prank(other);
        TestnetAsyncVault(context.endpoint).requestRedeem(20e18, other, other);
        context.assets = 0;
        IssuerActivityScript(_activity).runBase(context, false);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        TestnetPriceFeed(context.feed).publish(1e18);
        TestnetAsyncVault(context.endpoint).fulfill(other);
        assertEq(TestnetAsyncVault(context.endpoint).reservedAssets(), 20e6);
        TestnetPriceFeed(context.feed).publish(2e18);
        context.assets = 5e6;
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 0);
        assertEq(TestnetAsyncVault(context.endpoint).pending(context.account), 10e18);
        assertEq(TestnetAsyncVault(context.endpoint).reservedAssets(), 20e6);
        assertEq(IERC20(context.asset).balanceOf(context.account), 0);
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 1);
        assertEq(IERC20(context.asset).balanceOf(context.account), 20e6);
        assertEq(TestnetAsyncVault(context.endpoint).reservedAssets(), 20e6);
        assertEq(TestnetAsyncVault(context.endpoint).claimableAssets(other), 20e6);
        assertEq(IERC20(context.asset).balanceOf(context.endpoint), 20e6);
        assertEq(IssuerActivityScript(_activity).pendingEntries(context), 0);
        assertEq(IERC20(context.asset).allowance(address(this), context.endpoint), type(uint256).max);
    }

    function testAsyncInventoryMintConsumesOnlyItsPrefundedBudgetAndClearsAllowance() public {
        ActivityContext memory context = _async();
        vm.prank(context.account);
        IERC20(context.token).transfer(address(this), 10e18);
        IERC20(context.token).transfer(makeAddr("existing shares buyer"), 10e18);
        context.assets = 5e6;
        uint256 ownerCash = IERC20(context.asset).balanceOf(address(this));
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 0);
        assertEq(ownerCash - IERC20(context.asset).balanceOf(address(this)), 5e6);
        assertEq(IERC20(context.token).balanceOf(address(this)), 5e18);
        assertEq(IERC20(context.asset).allowance(address(this), context.endpoint), 0);
        assertEq(TestnetAsyncVault(context.endpoint).reservedAssets(), 0);
    }

    function testAsyncReceivedSharesDoNotResubmitDuringAnOutstandingRequest() public {
        ActivityContext memory context = _async();
        context.assets = 0;
        IssuerActivityScript(_activity).runBase(context, false);
        IERC20(context.asset).approve(context.endpoint, 5e6);
        TestnetAsyncVault(context.endpoint).mint(context.account, 5e18);
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 0);
        assertEq(TestnetAsyncVault(context.endpoint).pending(context.account), 10e18);
        assertEq(IERC20(context.token).balanceOf(context.account), 5e18);
        vm.warp(TestnetAsyncVault(context.endpoint).readyAt(context.account));
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 1);
        assertEq(TestnetAsyncVault(context.endpoint).pending(context.account), 5e18);
        assertEq(IERC20(context.asset).balanceOf(context.account), 10e6);
        assertEq(IERC20(context.token).balanceOf(context.account), 0);
    }

    function testWrongOwnerCannotPublishOrMoveFunding() public {
        ActivityContext memory context = _openEden();
        address wrongOwner = makeAddr("not issuer owner");
        context.owner = wrongOwner;
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, wrongOwner));
        IssuerActivityScript(_activity).runBase(context, false);
        assertEq(IERC20(context.asset).balanceOf(context.endpoint), 0);
        assertEq(IERC20(context.token).balanceOf(context.account), 10e18);
    }

    function testMismatchedCatalogIdentityRejectsBeforeAnyMutation() public {
        ActivityContext memory context = _openEden();
        context.variant = 0;
        uint80 beforeRound = TestnetPriceFeed(context.feed).latestRound();
        vm.expectRevert(IIssuerActivityScript.InvalidProfile.selector);
        IssuerActivityScript(_activity).runBase(context, false);
        assertEq(TestnetPriceFeed(context.feed).latestRound(), beforeRound);
        vm.expectRevert(IIssuerActivityScript.InvalidProfile.selector);
        IssuerActivityScript(_activity).pendingEntries(context);
    }

    function _openEden() internal returns (ActivityContext memory context) {
        context = _base(33);
        address factory = address(new MigratablesFactory(address(this)));
        address implementation;
        (context.token, context.oracle, context.endpoint, implementation) = new TestnetProviderDeploymentScript(
                address(this), false
            )
            .deploy(factory, address(new TestnetCowSettlement()), context.asset);
        context.feed = TestnetOpenEdenExpress(context.endpoint).priceOracle();
        MigratablesFactory(factory).whitelist(implementation);
        address vault = address(new IssuerActivityVault(context.asset));
        context.account = MigratablesFactory(factory).create(1, address(this), abi.encode(vault, address(this)));
        TestnetToken(context.token).mint(context.account, 10e18);
    }

    function _midas(uint8 kind) internal returns (ActivityContext memory context) {
        context = _base(kind == 0 ? 3 : kind == 1 ? 18 : 19);
        TestnetCatalog.Profile memory profile = TestnetCatalog.profile(context.profile);
        context.token = address(new TestnetToken("Midas fixture", "MIDAS", 18, address(this)));
        context.feed = address(new TestnetPriceFeed(address(this), "Midas", 18, 30 hours, int256(profile.fixturePrice)));
        context.endpoint = address(
            new TestnetMidasRedemptionVault(
                address(this),
                context.token,
                context.feed,
                context.asset,
                kind == 2 ? uint48(35 days) : profile.cooldown,
                10
            )
        );
        context.oracle = address(new MidasOracle(profile.minPrice, profile.maxPrice, context.feed));
        address factory = address(new MigratablesFactory(address(this)));
        address cow = address(new TestnetCowSettlement());
        address implementation = kind == 0
            ? address(
                new MidasCompAccount(context.oracle, factory, 0, context.token, context.asset, context.endpoint, cow)
            )
            : kind == 1
                ? address(
                    new MidasNonCompAccount(
                        context.oracle, factory, 0, context.token, context.asset, context.endpoint, cow
                    )
                )
                : address(
                    new CutoffMidasAccount(
                        context.oracle,
                        factory,
                        0,
                        1_785_074_400,
                        context.token,
                        5 days,
                        context.asset,
                        context.endpoint,
                        cow
                    )
                );
        MigratablesFactory(factory).whitelist(implementation);
        context.account = MigratablesFactory(factory)
            .create(1, address(this), abi.encode(address(new IssuerActivityVault(context.asset)), address(this)));
        TestnetToken(context.token).mint(context.account, 10e18);
    }

    function _async() internal returns (ActivityContext memory context) {
        context = _base(1);
        context.feed = address(new TestnetPriceFeed(address(this), "Centrifuge", 18, 30 hours, 1e18));
        context.token =
            address(new TestnetAsyncVault(address(this), context.asset, context.feed, 2 days, "Centrifuge", "CF"));
        context.endpoint = context.token;
        context.oracle = address(new AsyncRedeemOracle(0.5e18, 3e18, context.token, context.token));
        address factory = address(new MigratablesFactory(address(this)));
        address implementation = address(
            new TestnetAsyncAccount(
                context.oracle, factory, 0, context.token, context.asset, address(new TestnetCowSettlement())
            )
        );
        MigratablesFactory(factory).whitelist(implementation);
        context.account = MigratablesFactory(factory)
            .create(1, address(this), abi.encode(address(new IssuerActivityVault(context.asset)), address(this)));
        IERC20(context.asset).approve(context.endpoint, 10e6);
        TestnetAsyncVault(context.endpoint).mint(context.account, 10e18);
        IERC20(context.asset).approve(context.endpoint, 0);
    }

    function _base(uint256 profileIndex) internal returns (ActivityContext memory context) {
        TestnetCatalog.Profile memory profile = TestnetCatalog.profile(profileIndex);
        context = ActivityContext({
            owner: address(this),
            asset: address(new TestnetToken("USDC", "USDC", 6, address(this))),
            token: address(0),
            endpoint: address(0),
            feed: address(0),
            oracle: address(0),
            account: address(0),
            profile: profileIndex,
            kind: profile.mechanism,
            variant: profile.variant,
            assets: 100_000e6,
            seed: 2,
            cursor: 0
        });
        TestnetToken(context.asset).mint(address(this), 1_000_000e6);
    }
}
