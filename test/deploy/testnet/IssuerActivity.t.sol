// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import {AsyncRedeemOracle} from "src/contracts/ll-adapter/oracles/AsyncRedeemOracle.sol";
import {CutoffMidasAccount, MidasCompAccount, MidasNonCompAccount} from "src/contracts/ll-adapter/MidasAccount.sol";
import {MidasOracle} from "src/contracts/ll-adapter/oracles/MidasOracle.sol";

import {IAccount} from "src/interfaces/ll-adapter/IAccount.sol";
import {IAssetoAccount} from "src/interfaces/ll-adapter/asseto/IAssetoAccount.sol";
import {IAssetoOracle} from "src/interfaces/ll-adapter/oracles/IAssetoOracle.sol";
import {IChainlinkOracle} from "src/interfaces/ll-adapter/oracles/IChainlinkOracle.sol";
import {ICutoffAccount} from "src/interfaces/ll-adapter/ICutoffAccount.sol";
import {ISettlementAccount} from "src/interfaces/ll-adapter/ISettlementAccount.sol";
import {ISpikoAccount} from "src/interfaces/ll-adapter/spiko/ISpikoAccount.sol";
import {ISpikoRedemption} from "src/interfaces/ll-adapter/spiko/ISpikoRedemption.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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
    TestnetProviderDeploymentScript,
    TestnetProviderIssuer,
    TestnetSpikoRedemption
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

    function testEveryProviderUsesNativeReadinessCustodyAndFundedPayout() public {
        for (uint8 variant; variant < 9; ++variant) {
            ActivityContext memory context = _provider(variant);
            assertEq(IssuerActivityScript(_activity).pendingEntries(context), 0);
            uint256 expected = IAccount(context.account).totalAssets();
            uint256 started = vm.getBlockTimestamp();
            uint256 ownerCash = IERC20(context.asset).balanceOf(address(this));
            assertEq(IssuerActivityScript(_activity).runBase(context, false), variant == 2 ? 1 : 0);
            assertEq(vm.getBlockTimestamp(), started);
            assertLe(ownerCash - IERC20(context.asset).balanceOf(address(this)), context.assets);
            assertEq(IERC20(context.token).balanceOf(context.account), 0);
            assertEq(IssuerActivityScript(_activity).pendingEntries(context), variant == 2 ? 0 : 1);
            if (variant == 2) {
                assertEq(IERC20(context.asset).balanceOf(context.account), expected);
                continue;
            }
            if (variant == 5) {
                vm.warp(started + 1 hours);
            } else if (variant == 7) {
                vm.warp(started + 2 days);
            } else {
                (,,, uint48 readyAt,) = TestnetProviderIssuer(context.endpoint).requests(0);
                vm.warp(readyAt);
            }
            ownerCash = IERC20(context.asset).balanceOf(address(this));
            assertEq(IssuerActivityScript(_activity).runBase(context, false), 1);
            assertLe(ownerCash - IERC20(context.asset).balanceOf(address(this)), context.assets);
            assertEq(IERC20(context.asset).balanceOf(context.account), expected);
            assertEq(IssuerActivityScript(_activity).pendingEntries(context), 0);
            assertEq(IERC20(context.token).balanceOf(context.endpoint), 0);
            assertGt(IERC20(context.token).balanceOf(address(this)), 0);
            if (variant == 7) assertEq(TestnetOpenEdenExpress(context.endpoint).getRedeemQueueLength(), 0);
        }
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

    function testPartialFundingLeavesTheNativeNoticeOpenUntilCashIsSufficient() public {
        ActivityContext memory context = _provider(1);
        context.assets = 100e6;
        IssuerActivityScript(_activity).runBase(context, false);
        (,,, uint48 readyAt,) = TestnetProviderIssuer(context.endpoint).requests(0);
        vm.warp(readyAt);
        uint256 beforeCash = IERC20(context.asset).balanceOf(address(this));
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 0);
        assertEq(beforeCash - IERC20(context.asset).balanceOf(address(this)), 100e6);
        assertEq(IERC20(context.asset).balanceOf(context.endpoint), 200e6);
        assertEq(IERC20(context.asset).balanceOf(context.account), 0);
        assertEq(IssuerActivityScript(_activity).pendingEntries(context), 1);
        (,,,, bool closed) = TestnetProviderIssuer(context.endpoint).requests(0);
        assertFalse(closed);
        context.assets = 9800e6;
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 1);
        assertEq(IERC20(context.asset).balanceOf(context.account), 10_000e6);
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
        ActivityContext memory context = _provider(7);
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
        ActivityContext memory context = _provider(7);
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

    function testSpikoExpiryCancelsCustodyAndDoesNotForgeIssuerSettlement() public {
        ActivityContext memory context = _provider(5);
        IssuerActivityScript(_activity).runBase(context, false);
        bytes32 id = ISpikoAccount(context.account).pendingId();
        (, uint48 deadline) = ISpikoRedemption(context.endpoint).details(id);
        vm.warp(deadline);
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 0);
        (ISpikoRedemption.Status status,) = ISpikoRedemption(context.endpoint).details(id);
        assertEq(uint8(status), uint8(ISpikoRedemption.Status.CANCELED));
        // The second native sync is owner-authorized and restarts the refunded shares with a new salt.
        assertEq(IERC20(context.token).balanceOf(context.account), 0);
        assertEq(IERC20(context.token).balanceOf(context.endpoint), 1e6);
        assertFalse(ISpikoAccount(context.account).redemptionPaused());
        assertEq(IssuerActivityScript(_activity).pendingEntries(context), 1);
        assertNotEq(ISpikoAccount(context.account).pendingId(), id);
        assertEq(ISpikoAccount(context.account).requestNonce(), 2);
        assertEq(IERC20(context.asset).balanceOf(context.account), 0);
    }

    function testSpikoIssuerCannotRestartAnotherOwnersPausedAccount() public {
        ActivityContext memory context = _provider(5);
        Ownable(context.account).transferOwnership(makeAddr("separate account owner"));
        IssuerActivityScript(_activity).runBase(context, false);
        bytes32 id = ISpikoAccount(context.account).pendingId();
        (, uint48 deadline) = ISpikoRedemption(context.endpoint).details(id);
        vm.warp(deadline);
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 0);
        assertEq(IERC20(context.token).balanceOf(context.account), 1e6);
        assertTrue(ISpikoAccount(context.account).redemptionPaused());
        assertEq(IssuerActivityScript(_activity).pendingEntries(context), 0);
        assertEq(ISpikoAccount(context.account).requestNonce(), 1);
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

    function testReleasedSettlementSubAccountRescuesActualLateCash() public {
        ActivityContext memory context = _provider(3);
        IssuerActivityScript(_activity).runBase(context, false);
        address subAccount = ISettlementAccount(context.account).subAccounts(0);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 1);
        assertEq(IERC20(context.asset).balanceOf(subAccount), 0);
        assertEq(IERC20(context.asset).balanceOf(context.account), 114e6);
        assertEq(IssuerActivityScript(_activity).pendingEntries(context), 0);
        vm.expectRevert();
        ISettlementAccount(context.account).subAccounts(0);
    }

    function testSettlementSubAccountRefreshKeepsLiveLockedQuoteCovered() public {
        ActivityContext memory context = _provider(4);
        context.seed = 4;
        IssuerActivityScript(_activity).runBase(context, false);
        uint256 creationRate = TestnetPriceFeed(context.feed).getDataInBase18();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(IssuerActivityScript(_activity).runBase(context, false), 1);
        assertEq(TestnetPriceFeed(context.feed).getDataInBase18(), creationRate);
        assertEq(IERC20(context.asset).balanceOf(context.account), 1000.2e6);
        vm.expectRevert();
        ISettlementAccount(context.account).subAccounts(0);
    }

    function testWrongOwnerCannotPublishOrMoveFunding() public {
        ActivityContext memory context = _provider(1);
        address wrongOwner = makeAddr("not issuer owner");
        context.owner = wrongOwner;
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, wrongOwner));
        IssuerActivityScript(_activity).runBase(context, false);
        assertEq(IERC20(context.asset).balanceOf(context.endpoint), 0);
        assertEq(IERC20(context.token).balanceOf(context.account), 10e6);
    }

    function testMismatchedCatalogIdentityRejectsBeforeAnyMutation() public {
        ActivityContext memory context = _provider(1);
        context.variant = 0;
        uint80 beforeRound = TestnetPriceFeed(context.feed).latestRound();
        vm.expectRevert(IIssuerActivityScript.InvalidProfile.selector);
        IssuerActivityScript(_activity).runBase(context, false);
        assertEq(TestnetPriceFeed(context.feed).latestRound(), beforeRound);
        vm.expectRevert(IIssuerActivityScript.InvalidProfile.selector);
        IssuerActivityScript(_activity).pendingEntries(context);
    }

    function testFuzzValuationMovementKeepsVBILLWithinItsNativeBounds(uint256 seed) public {
        ActivityContext memory context = _provider(2);
        context.seed = seed;
        TestnetCatalog.Profile memory profile = TestnetCatalog.profile(context.profile);
        TestnetPriceFeed(context.feed).publish(seed % 2 == 0 ? int256(profile.minPrice) : int256(profile.maxPrice));
        IssuerActivityScript(_activity).runBase(context, false);
        uint256 price = TestnetPriceFeed(context.feed).getDataInBase18();
        assertGe(price, profile.minPrice);
        assertLe(price, profile.maxPrice);
        assertEq(IERC20(context.token).balanceOf(context.account), 0);
    }

    function _provider(uint8 variant) internal returns (ActivityContext memory context) {
        uint256[9] memory indices = [uint256(2), 11, 15, 13, 16, 10, 49, 50, 51];
        context = _base(indices[variant]);
        address factory = address(new MigratablesFactory(address(this)));
        address implementation;
        (context.token, context.oracle, context.endpoint, implementation) = new TestnetProviderDeploymentScript(
                address(this), false
            )
            .deploy(factory, address(new TestnetCowSettlement()), context.asset, variant);
        context.feed = variant == 6
            ? IAssetoOracle(context.oracle).PRICER()
            : variant == 7
                ? TestnetOpenEdenExpress(context.endpoint).priceOracle()
                : IChainlinkOracle(context.oracle).AGGREGATOR_0();
        MigratablesFactory(factory).whitelist(implementation);
        address vault = address(new IssuerActivityVault(context.asset));
        context.account = MigratablesFactory(factory)
            .create(
                1,
                address(this),
                variant == 6
                    ? abi.encode(
                        IAssetoAccount.InitParams({
                            vault: vault, adapter: address(this), offChainDestination: keccak256("testnet investor")
                        })
                    )
                    : abi.encode(vault, address(this))
            );
        TestnetToken(context.token).mint(context.account, 10 * 10 ** IERC20Metadata(context.token).decimals());
    }

    function _midas(uint8 kind) internal returns (ActivityContext memory context) {
        context = _base(kind == 0 ? 4 : kind == 1 ? 28 : 29);
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
