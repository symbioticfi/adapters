// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {ActivityContext} from "script/deploy/testnet/activity/ActivityContext.sol";
import {IYieldActivityScript, YieldActivityScript} from "script/deploy/testnet/activity/YieldActivity.s.sol";
import {TestnetToken} from "script/deploy/testnet/protocols/TestnetAssets.sol";
import {
    TestnetInfiniFiBucketFeed,
    TestnetInfiniFiGateway,
    TestnetMakinaMachine,
    TestnetParetoCDO,
    TestnetParetoQueue,
    TestnetSaid,
    TestnetSUSD3,
    TestnetYieldDeploymentScript,
    TestnetYieldVault
} from "script/deploy/testnet/protocols/TestnetYieldRedemptions.sol";

import {IAccount} from "src/interfaces/ll-adapter/IAccount.sol";
import {ICooldownAccount} from "src/interfaces/ll-adapter/ICooldownAccount.sol";
import {IOracle} from "src/interfaces/ll-adapter/IOracle.sol";
import {IChainlinkOracle} from "src/interfaces/ll-adapter/oracles/IChainlinkOracle.sol";
import {IInfiniFiAccount} from "src/interfaces/ll-adapter/infinifi/IInfiniFiAccount.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

/// @title YieldActivityTest
/// @notice Exercises repeatable real-time fixture activity through deployed production account implementations.
contract YieldActivityTest is Test {
    /* STATE VARIABLES */

    address internal _asset;
    address internal _factory;
    address internal _vault;
    address internal _cow;
    address internal _deployment;
    address internal _activity;
    address internal _adapterOwner;

    /* PUBLIC FUNCTIONS */

    function setUp() public {
        vm.warp(1_800_000_000);
        _asset = address(new TestnetToken("Activity USD Coin", "USDC", 6, address(this)));
        _factory = address(new MigratablesFactory(address(this)));
        _vault = address(new TestnetYieldVault(_asset, address(this), "Activity asset vault", "VAULT", 6));
        _cow = address(new YieldActivitySettlement());
        _deployment = address(new TestnetYieldDeploymentScript(address(this), false));
        _activity = address(new YieldActivityScript());
        _adapterOwner = makeAddr("Liquid Lane adapter owner");
        TestnetToken(_asset).mint(address(this), 1_000_000e6);
    }

    function testEveryProfileSettlesUsingRealChainTimeAndRetainsFundedInventory() public {
        for (uint8 variant; variant < 11; ++variant) {
            ActivityContext memory context = _deploy(variant, 100e6);
            uint256 timestamp = block.timestamp;
            assertEq(YieldActivityScript(_activity).runBase(context, false), variant == 4 ? 1 : 0);
            assertEq(block.timestamp, timestamp, "activity never advances virtual time");
            assertGt(IERC20(context.token).balanceOf(address(this)), 0, "owner inventory has real deposited backing");
            uint256 inventory = IERC20(context.token).balanceOf(address(this));
            if (variant < 2 || variant == 2 || variant == 3 || variant == 7) {
                vm.warp(timestamp + 2 days);
            } else if (variant == 5 || variant == 6 || variant == 10) {
                vm.warp(timestamp + 7 days);
            } else if (variant == 8 || variant == 9) {
                uint256 key = IInfiniFiAccount(context.account).unwindingTimestamps(0);
                (, uint256 maturity) = TestnetInfiniFiGateway(context.endpoint).positions(context.account, key);
                vm.warp(maturity);
            }
            timestamp = block.timestamp;
            uint256 settled = YieldActivityScript(_activity).runBase(context, false);
            assertEq(settled, variant == 4 ? 0 : 1);
            assertEq(block.timestamp, timestamp);
            assertApproxEqAbs(IERC20(_asset).balanceOf(context.account), 100e6, 2, "settlement transfers actual cash");
            assertApproxEqAbs(IAccount(context.account).totalAssets(), 100e6, 2);
            assertEq(
                IERC20(context.token).balanceOf(address(this)),
                inventory,
                "repeated activity does not inflate inventory"
            );
            assertEq(YieldActivityScript(_activity).runBase(context, false), 0, "settlement replay pays no second time");
        }
    }

    function testInventoryTopUpDepositsOnlyMissingNativeValueAndIsBounded() public {
        ActivityContext memory context = _deploy(5, 0);
        context.assets = 10e6;
        uint256 balance = IERC20(_asset).balanceOf(address(this));
        YieldActivityScript(_activity).runBase(context, false);
        assertEq(balance - IERC20(_asset).balanceOf(address(this)), 10e6);
        uint256 shares = IERC20(context.token).balanceOf(address(this));
        IERC20(context.token).transfer(makeAddr("inventory purchaser"), shares / 2);
        balance = IERC20(_asset).balanceOf(address(this));
        YieldActivityScript(_activity).runBase(context, false);
        assertApproxEqAbs(balance - IERC20(_asset).balanceOf(address(this)), 5e6, 1);
        uint256 receipts = IERC4626(context.token).convertToAssets(IERC20(context.token).balanceOf(address(this)));
        assertApproxEqAbs(IERC4626(context.endpoint).convertToAssets(receipts), context.assets, 1);
        balance = IERC20(_asset).balanceOf(address(this));
        YieldActivityScript(_activity).runBase(context, false);
        assertEq(IERC20(_asset).balanceOf(address(this)), balance);
    }

    function testOwnerFaucetShortfallBecomesRealVaultBacking() public {
        ActivityContext memory context = _deploy(4, 0);
        IERC20(_asset).transfer(makeAddr("existing owner cash recipient"), IERC20(_asset).balanceOf(address(this)));
        uint256 supply = IERC20(_asset).totalSupply();
        context.assets = 3e6;
        YieldActivityScript(_activity).runBase(context, false);
        assertEq(IERC20(_asset).totalSupply() - supply, 3e6);
        assertEq(IERC20(_asset).balanceOf(context.token), 3e6);
        assertEq(IERC4626(context.token).convertToAssets(IERC20(context.token).balanceOf(address(this))), 3e6);
    }

    function testCashLimitedUsd3RepaymentAndLiquidExitConsumeOneBudget() public {
        ActivityContext memory context = _deploy(4, 100e6);
        TestnetYieldVault(context.token).deployCapital(address(this), 90e6);
        context.assets = 0;
        assertEq(YieldActivityScript(_activity).runBase(context, false), 1);
        assertEq(IERC20(_asset).balanceOf(context.account), 10e6);
        context.assets = 20e6;
        uint256 before = IERC20(_asset).balanceOf(address(this));
        assertEq(YieldActivityScript(_activity).runBase(context, false), 1);
        assertEq(before - IERC20(_asset).balanceOf(address(this)), 20e6);
        assertEq(IERC20(context.token).balanceOf(address(this)), 0, "repayment consumes inventory funding budget");
        assertEq(IERC20(_asset).balanceOf(context.account), 30e6);
        assertEq(TestnetYieldVault(context.token).receivable(), 70e6);
        context.assets = 70e6;
        YieldActivityScript(_activity).runBase(context, false);
        assertEq(IERC20(_asset).balanceOf(context.account), 100e6);
    }

    function testSusd3ExpiredWindowRestartsNativeCooldownWithoutTimeMutation() public {
        ActivityContext memory context = _deploy(5, 100e6);
        context.assets = 0;
        YieldActivityScript(_activity).runBase(context, false);
        (, uint256 window,) = TestnetSUSD3(context.token).getCooldownStatus(context.account);
        vm.warp(window + 1);
        uint256 timestamp = block.timestamp;
        assertEq(YieldActivityScript(_activity).runBase(context, false), 0);
        (uint256 end,,) = TestnetSUSD3(context.token).getCooldownStatus(context.account);
        assertEq(end, timestamp + 7 days);
        assertEq(block.timestamp, timestamp);
        vm.warp(end);
        assertEq(YieldActivityScript(_activity).runBase(context, false), 1);
        assertEq(IERC20(_asset).balanceOf(context.account), 100e6);
    }

    function testTheoMatureRequestWaitsForActualRepayment() public {
        ActivityContext memory context = _deploy(6, 100e6);
        TestnetYieldVault(context.token).deployCapital(address(this), 90e6);
        context.assets = 0;
        YieldActivityScript(_activity).runBase(context, false);
        vm.warp(block.timestamp + 7 days);
        assertEq(YieldActivityScript(_activity).runBase(context, false), 0);
        assertEq(IERC20(_asset).balanceOf(context.account), 0);
        context.assets = 90e6;
        assertEq(YieldActivityScript(_activity).runBase(context, false), 1);
        assertEq(IERC20(_asset).balanceOf(context.account), 100e6);
        assertEq(TestnetYieldVault(context.token).receivable(), 0);
    }

    function testPublishedMakinaAndInfiniFiQuotesRefreshAfterActualFunding() public {
        ActivityContext memory makina = _deploy(2, 100e6);
        vm.warp(block.timestamp + 48 hours + 1);
        vm.expectRevert(IOracle.InvalidPrice.selector);
        IOracle(makina.oracle).getPrice();
        YieldActivityScript(_activity).runBase(makina, false);
        assertEq(TestnetMakinaMachine(makina.token).lastGlobalAccountingTime(), block.timestamp);
        assertEq(IOracle(makina.oracle).getPrice(), 1e18);
        ActivityContext memory infinifi = _deploy(8, 100e6);
        (uint80 round,,,,) = TestnetInfiniFiBucketFeed(infinifi.feed).latestRoundData();
        vm.warp(block.timestamp + 30 days + 1);
        vm.expectRevert();
        IOracle(infinifi.oracle).getPrice();
        YieldActivityScript(_activity).runBase(infinifi, false);
        (uint80 newRound,,, uint256 publishedAt,) = TestnetInfiniFiBucketFeed(infinifi.feed).latestRoundData();
        assertEq(newRound, round + 2);
        assertEq(publishedAt, block.timestamp);
        assertEq(IOracle(infinifi.oracle).getPrice(), 1e18);
    }

    function testInfiniFiAccruedLossAndRealReceivableRepaymentSettleWeeklyPosition() public {
        ActivityContext memory context = _deploy(8, 100e6);
        TestnetInfiniFiGateway(context.endpoint).deployCapital(address(this), 90e6);
        IAccount(context.account).sync();
        TestnetInfiniFiGateway(context.endpoint).reportLoss(0.9e18);
        uint256 key = IInfiniFiAccount(context.account).unwindingTimestamps(0);
        (, uint256 maturity) = TestnetInfiniFiGateway(context.endpoint).positions(context.account, key);
        vm.warp(maturity);
        context.assets = 80e6;
        assertEq(YieldActivityScript(_activity).runBase(context, false), 1);
        assertFalse(TestnetInfiniFiGateway(context.endpoint).lossesUnaccrued());
        assertEq(TestnetInfiniFiGateway(context.endpoint).receivable(), 0);
        assertEq(IERC20(_asset).balanceOf(context.account), 90e6);
        assertEq(YieldActivityScript(_activity).pendingEntries(context.account, context.variant), 0);
    }

    function testFuzzFigureCursorProcessesAtMostEightAndEventuallyClearsOlderRequests(uint256 initialCursor) public {
        ActivityContext memory context = _deploy(0, 0);
        for (uint256 i; i < 17; ++i) {
            _deposit(context, 1e6);
            vm.warp(block.timestamp + ICooldownAccount(context.account).COOLDOWN());
            IAccount(context.account).sync();
        }
        vm.warp(block.timestamp + 2 days);
        context.assets = 0;
        context.cursor = initialCursor;
        assertEq(YieldActivityScript(_activity).pendingEntries(context.account, context.variant), 17);
        for (uint256 i; i < 3; ++i) {
            uint256 settled = YieldActivityScript(_activity).runBase(context, false);
            assertLe(settled, 8);
            assertGt(settled, 0);
            context.cursor = YieldActivityScript(_activity).nextCursor();
        }
        assertEq(YieldActivityScript(_activity).pendingEntries(context.account, context.variant), 0);
        assertEq(IERC20(_asset).balanceOf(context.account), 17e6);
    }

    function testGaibProcessesOlderGlobalFifoBeforeCurrentAccount() public {
        ActivityContext memory older = _deploy(3, 1e6);
        IAccount(older.account).sync();
        address other = MigratablesFactory(_factory)
            .create(
                uint64(MigratablesFactory(_factory).lastVersion()), _adapterOwner, abi.encode(_vault, address(this))
            );
        address olderAccount = older.account;
        ActivityContext memory newer = older;
        newer.account = other;
        _deposit(newer, 2e6);
        IAccount(other).sync();
        vm.warp(block.timestamp + 2 days);
        newer.assets = 0;
        assertEq(YieldActivityScript(_activity).runBase(newer, false), 2);
        assertEq(TestnetSaid(newer.endpoint).queueHead(), 2);
        assertEq(IERC20(_asset).balanceOf(other), 2e6);
        assertEq(IERC20(_asset).balanceOf(olderAccount), 0, "older proceeds remain in its own request-holder custody");
        IAccount(olderAccount).sync();
        assertEq(IERC20(_asset).balanceOf(olderAccount), 1e6);
    }

    function testInfiniFiOverEightBacklogRejectedBeforeAnyFundingMutation() public {
        ActivityContext memory context = _deploy(8, 0);
        for (uint256 i; i < 9; ++i) {
            _deposit(context, 1e6);
            vm.warp(block.timestamp + ICooldownAccount(context.account).COOLDOWN());
            IAccount(context.account).sync();
        }
        uint256 balance = IERC20(_asset).balanceOf(address(this));
        uint80 round = TestnetInfiniFiBucketFeed(context.feed).latestRound();
        assertEq(YieldActivityScript(_activity).pendingEntries(context.account, context.variant), 9);
        vm.expectRevert(IYieldActivityScript.BacklogLimit.selector);
        YieldActivityScript(_activity).runBase(context, false);
        assertEq(IERC20(_asset).balanceOf(address(this)), balance);
        assertEq(TestnetInfiniFiBucketFeed(context.feed).latestRound(), round);
    }

    function testParetoMatureEpochIsFundedAndNextEpochStartsWithoutReplayingClaims() public {
        ActivityContext memory context = _deploy(10, 100e6);
        context.assets = 0;
        assertEq(YieldActivityScript(_activity).runBase(context, false), 0);
        address cdo = TestnetParetoQueue(context.endpoint).idleCDOEpoch();
        assertTrue(TestnetParetoCDO(cdo).isEpochRunning());
        vm.warp(TestnetParetoCDO(cdo).epochMaturity());
        assertEq(YieldActivityScript(_activity).runBase(context, false), 1);
        assertTrue(TestnetParetoQueue(context.endpoint).settled(2));
        assertEq(TestnetParetoQueue(context.endpoint).epochPendingClaims(2), 0);
        assertTrue(TestnetParetoCDO(cdo).isEpochRunning());
        assertEq(TestnetParetoCDO(cdo).epochMaturity(), block.timestamp + 7 days);
        assertEq(IERC20(_asset).balanceOf(context.account), 100e6);
        assertEq(YieldActivityScript(_activity).runBase(context, false), 0);
    }

    function testParetoDefaultFlagIsPreservedAndNoUnbackedClaimIsInvented() public {
        ActivityContext memory context = _deploy(10, 100e6);
        address cdo = TestnetParetoQueue(context.endpoint).idleCDOEpoch();
        TestnetParetoCDO(cdo).setDefaulted(true);
        context.assets = 0;
        assertEq(YieldActivityScript(_activity).runBase(context, false), 0);
        assertTrue(TestnetParetoCDO(cdo).defaulted());
        assertFalse(TestnetParetoCDO(cdo).isEpochRunning());
        assertEq(IERC20(_asset).balanceOf(context.account), 0);
        assertGt(IERC20(context.token).balanceOf(context.account), 0);
    }

    function testInvalidIdentityAndFeedRejectBeforeMutation() public {
        ActivityContext memory context = _deploy(8, 100e6);
        uint256 supply = IERC20(_asset).totalSupply();
        context.feed = _asset;
        vm.expectRevert();
        YieldActivityScript(_activity).runBase(context, false);
        assertEq(IERC20(_asset).totalSupply(), supply);
        context.kind = 0;
        vm.expectRevert(IYieldActivityScript.InvalidContext.selector);
        YieldActivityScript(_activity).runBase(context, false);
    }

    function testCompilerGeneratedEmptyArrayGetterEndsQueueDiscovery() public {
        address empty = address(new YieldActivityEmptyArrayGetter());
        assertEq(YieldActivityScript(_activity).pendingEntries(empty, 0), 0);
    }

    function testIndexedGetterUnexpectedErrorsAreBubbledAndMalformedReturnsRejected() public {
        address failing = address(new YieldActivityFailingGetter());
        vm.expectRevert(YieldActivityFailingGetter.NativeFailure.selector);
        YieldActivityScript(_activity).pendingEntries(failing, 0);
        address malformed = address(new YieldActivityMalformedGetter());
        vm.expectRevert(IYieldActivityScript.InvalidQueue.selector);
        YieldActivityScript(_activity).pendingEntries(malformed, 0);
    }

    /* INTERNAL FUNCTIONS */

    function _deploy(uint8 variant, uint256 assets) internal returns (ActivityContext memory context) {
        address implementation;
        context.owner = address(this);
        context.asset = _asset;
        context.kind = 5;
        context.variant = variant;
        context.profile = 100 + variant;
        context.assets = 10e6;
        (context.token, context.oracle, context.endpoint, implementation) =
            TestnetYieldDeploymentScript(_deployment).deploy(_factory, _cow, _asset, variant);
        MigratablesFactory(_factory).whitelist(implementation);
        context.account = MigratablesFactory(_factory)
            .create(
                uint64(MigratablesFactory(_factory).lastVersion()), _adapterOwner, abi.encode(_vault, address(this))
            );
        if (variant == 8 || variant == 9) context.feed = IChainlinkOracle(context.oracle).AGGREGATOR_0();
        if (assets > 0) _deposit(context, assets);
    }

    function _deposit(ActivityContext memory context, uint256 assets) internal {
        TestnetYieldDeploymentScript(_deployment)
            .seed(context.token, context.endpoint, context.variant, assets, context.account);
    }
}

/// @title YieldActivitySettlement
/// @notice CoW constructor ABI helper for same-asset activity tests.
contract YieldActivitySettlement {
    function vaultRelayer() public view returns (address) {
        return address(this);
    }

    function domainSeparator() public pure returns (bytes32) {
        return keccak256("Yield activity settlement");
    }
}

/// @title YieldActivityFailingGetter
/// @notice Verifies that queue discovery preserves native failures.
contract YieldActivityFailingGetter {
    error NativeFailure();

    function subAccounts(uint256) public pure returns (address) {
        revert NativeFailure();
    }
}

/// @title YieldActivityMalformedGetter
/// @notice Verifies that successful empty getter data is rejected.
contract YieldActivityMalformedGetter {
    fallback() external {}
}

/// @title YieldActivityEmptyArrayGetter
/// @notice Exercises the compiler-generated empty revert for a native public-array getter.
contract YieldActivityEmptyArrayGetter {
    address[] public subAccounts;
}
