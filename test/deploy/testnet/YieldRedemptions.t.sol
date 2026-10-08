// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ChainlinkOracle} from "../../../src/contracts/ll-adapter/oracles/ChainlinkOracle.sol";
import {FigureAccount} from "../../../src/contracts/ll-adapter/FigureAccount.sol";
import {GaibAccount} from "../../../src/contracts/ll-adapter/GaibAccount.sol";
import {
    ITestnetYieldVault,
    TestnetFigureYieldVault,
    TestnetInfiniFiBucketFeed,
    TestnetInfiniFiGateway,
    TestnetMakinaMachine,
    TestnetMakinaRedeemer,
    TestnetNoonHandler,
    TestnetParetoCDO,
    TestnetParetoQueue,
    TestnetSaid,
    TestnetSUSD3,
    TestnetTheoVault,
    TestnetYieldDeploymentScript,
    TestnetYieldVault
} from "../../../script/deploy/testnet/protocols/TestnetYieldRedemptions.sol";
import {InfiniFiAccount} from "../../../src/contracts/ll-adapter/InfiniFiAccount.sol";
import {MakinaAccount} from "../../../src/contracts/ll-adapter/MakinaAccount.sol";
import {MakinaOracle} from "../../../src/contracts/ll-adapter/oracles/MakinaOracle.sol";
import {NoonAccount} from "../../../src/contracts/ll-adapter/NoonAccount.sol";
import {Oracle} from "../../../src/contracts/ll-adapter/oracles/Oracle.sol";
import {ParetoAccount} from "../../../src/contracts/ll-adapter/ParetoAccount.sol";
import {TestnetToken} from "../../../script/deploy/testnet/protocols/TestnetAssets.sol";

import {IAccount} from "../../../src/interfaces/ll-adapter/IAccount.sol";
import {ICooldownAccount} from "../../../src/interfaces/ll-adapter/ICooldownAccount.sol";
import {IOracle} from "../../../src/interfaces/ll-adapter/IOracle.sol";
import {IParetoWithdrawalQueue} from "../../../src/interfaces/ll-adapter/pareto/IParetoWithdrawalQueue.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

/// @title YieldRedemptionsTest
/// @notice Exercises funded native protocol models through the production generic account implementations.
contract YieldRedemptionsTest is Test {
    address internal _asset;
    address internal _factory;
    address internal _cow;
    address internal _vault;
    address internal _helper;
    uint256 internal constant _DEPOSIT = 100e6;

    function setUp() public {
        vm.warp(1_800_000_000);
        _asset = address(new TestnetToken("Testnet USD Coin", "USDC", 6, address(this)));
        _factory = address(new MigratablesFactory(address(this)));
        _cow = address(new YieldTestSettlement());
        _vault = address(new TestnetYieldVault(_asset, address(this), "Account asset vault", "VAULT", 6));
        _helper = address(new TestnetYieldDeploymentScript(address(this), false));
        TestnetToken(_asset).mint(address(this), 1_000_000e6);
    }

    function testDeploymentPreservesSourceCooldownsOracleBoundsAndStaleness() public {
        uint48[11] memory cooldowns =
            [uint48(18 hours), 1 days, 72 minutes, 6 days, 0, 0, 0, 17 hours, 3 days, 7 days, 0];
        for (uint8 profile; profile < 11; ++profile) {
            (, address oracle,, address account) = _deploy(profile, _DEPOSIT);
            if (cooldowns[profile] > 0) assertEq(ICooldownAccount(account).COOLDOWN(), cooldowns[profile]);
            uint256 minimum = 0.5e18;
            uint256 maximum = 2.5e18;
            if (profile == 2) {
                minimum = 515_533_500_000_000_000;
                maximum = 2_062_134_000_000_000_000;
                assertEq(MakinaOracle(oracle).STALENESS_DURATION(), 48 hours);
            } else if (profile == 3) {
                minimum = 527_574_236_280_171_822;
                maximum = 2_110_296_945_120_687_290;
            } else if (profile == 8 || profile == 9) {
                minimum = profile == 8 ? 599_319_571_104_044_928 : 610_302_338_122_868_364;
                maximum = profile == 8 ? 2_397_278_284_416_179_714 : 2_441_209_352_491_473_456;
                assertEq(ChainlinkOracle(oracle).STALENESS_DURATION_0(), 30 days);
                assertEq(ChainlinkOracle(oracle).AGGREGATOR_1(), address(0));
            }
            assertEq(Oracle(oracle).MIN_PRICE(), minimum);
            assertEq(Oracle(oracle).MAX_PRICE(), maximum);
        }
    }

    function testInfiniFiPublishedBucketFeedReallyExpiresAndRecoversOnlyAfterOwnerRefresh() public {
        (address token, address oracle,,) = _deploy(8, _DEPOSIT);
        address feed = ChainlinkOracle(oracle).AGGREGATOR_0();
        assertEq(TestnetInfiniFiBucketFeed(feed).vault(), token);
        (uint80 round,,, uint256 publishedAt,) = TestnetInfiniFiBucketFeed(feed).latestRoundData();
        vm.warp(publishedAt + 30 days + 1);
        (,,, uint256 oldTimestamp,) = TestnetInfiniFiBucketFeed(feed).latestRoundData();
        assertEq(oldTimestamp, publishedAt, "reads cannot silently refresh publication time");
        vm.expectRevert();
        IOracle(oracle).getPrice();
        vm.prank(makeAddr("unauthorized feed publisher"));
        vm.expectRevert();
        TestnetInfiniFiBucketFeed(feed).refresh();
        TestnetInfiniFiBucketFeed(feed).refresh();
        (uint80 freshRound,,, uint256 refreshedAt,) = TestnetInfiniFiBucketFeed(feed).latestRoundData();
        assertEq(freshRound, round + 1);
        assertEq(refreshedAt, publishedAt + 30 days + 1);
        assertEq(IOracle(oracle).getPrice(), 1e18);
    }

    function testMakinaExactAccountingFreshnessExpiresAndOwnerCheckpointRecovers() public {
        (address token, address oracle,,) = _deploy(2, _DEPOSIT);
        uint256 timestamp = TestnetMakinaMachine(token).lastGlobalAccountingTime();
        vm.warp(timestamp + 48 hours + 1);
        vm.expectRevert(IOracle.InvalidPrice.selector);
        IOracle(oracle).getPrice();
        TestnetMakinaMachine(token).updateAccounting();
        assertEq(IOracle(oracle).getPrice(), 1e18);
    }

    function testEveryNativeYieldProfileFundedRequestSettlementAndReplayProtection() public {
        for (uint8 profile; profile < 11; ++profile) {
            (address token,, address endpoint, address account) = _deploy(profile, _DEPOSIT);
            assertApproxEqAbs(IAccount(account).totalAssets(), _DEPOSIT, 2, "initial funded NAV");
            assertGt(IERC20(token).balanceOf(account), 0, "real deposited token inventory");
            if (profile == 10) {
                address cdo = IParetoWithdrawalQueue(endpoint).idleCDOEpoch();
                TestnetParetoCDO(cdo).startEpoch();
            }
            IAccount(account).sync();
            assertApproxEqAbs(IAccount(account).totalAssets(), _DEPOSIT, 2, "pending native NAV");
            _settle(profile, endpoint, account);
            IAccount(account).sync();
            assertApproxEqAbs(IERC20(_asset).balanceOf(account), _DEPOSIT, 2, "actual paid cash");
            assertApproxEqAbs(IAccount(account).totalAssets(), _DEPOSIT, 2, "final cash NAV");
            uint256 paid = IERC20(_asset).balanceOf(account);
            IAccount(account).sync();
            assertEq(IERC20(_asset).balanceOf(account), paid, "sync replay cannot pay twice");
        }
    }

    function testFigureLayeredBackingAndNoUnfundedAdminSettlement() public {
        (address token,, address endpoint, address account) = _deploy(0, _DEPOSIT);
        assertEq(IERC4626(token).asset(), endpoint);
        assertEq(IERC4626(endpoint).asset(), _asset);
        TestnetYieldVault(endpoint).deployCapital(address(this), 90e6);
        IAccount(account).sync();
        address subAccount = FigureAccount(account).subAccounts(0);
        vm.expectRevert(ITestnetYieldVault.NotMature.selector);
        TestnetFigureYieldVault(endpoint).finalize(subAccount);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(ITestnetYieldVault.InvalidAmount.selector);
        TestnetFigureYieldVault(endpoint).finalize(subAccount);
        assertApproxEqAbs(IAccount(account).totalAssets(), _DEPOSIT, 1);
        IERC20(_asset).approve(endpoint, 90e6);
        TestnetYieldVault(endpoint).repayCapital(90e6, 0);
        TestnetFigureYieldVault(endpoint).finalize(subAccount);
        vm.expectRevert(ITestnetYieldVault.InvalidRequest.selector);
        TestnetFigureYieldVault(endpoint).finalize(subAccount);
        IAccount(account).sync();
        assertEq(IERC20(_asset).balanceOf(account), _DEPOSIT);
        assertEq(TestnetYieldVault(endpoint).reservedAssets(), 0);
    }

    function testMakinaNftReceiptReflectsLossAndRequiresFundedCash() public {
        (address token, address oracle, address endpoint, address account) = _deploy(2, _DEPOSIT);
        TestnetYieldVault(token).deployCapital(address(this), 90e6);
        IAccount(account).sync();
        uint256 id = MakinaAccount(account).requestIds(0);
        assertEq(TestnetMakinaRedeemer(endpoint).ownerOf(id), account);
        vm.expectRevert(TestnetMakinaRedeemer.NotMature.selector);
        TestnetMakinaRedeemer(endpoint).finalize(id);
        TestnetYieldVault(token).recognizeLoss(20e6);
        TestnetMakinaMachine(token).updateAccounting();
        assertApproxEqAbs(IOracle(oracle).getPrice(), 0.8e18, 1e10);
        assertApproxEqAbs(IAccount(account).totalAssets(), 80e6, 1);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert();
        TestnetMakinaRedeemer(endpoint).finalize(id);
        IERC20(_asset).approve(token, 70e6);
        TestnetYieldVault(token).repayCapital(70e6, 0);
        TestnetMakinaRedeemer(endpoint).finalize(id);
        IAccount(account).sync();
        assertApproxEqAbs(IERC20(_asset).balanceOf(account), 80e6, 1);
        vm.expectRevert();
        TestnetMakinaRedeemer(endpoint).ownerOf(id);
        vm.expectRevert();
        TestnetMakinaRedeemer(endpoint).claimAssets(id);
    }

    function testGaibFifoCannotProcessUnfinalizedOrImmatureRequests() public {
        (address token,, address endpoint, address account) = _deploy(3, _DEPOSIT);
        IAccount(account).sync();
        address subAccount = GaibAccount(account).subAccounts(0);
        TestnetSaid(endpoint).processUnstakeQueue(10);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        vm.expectRevert(ITestnetYieldVault.NotMature.selector);
        TestnetSaid(endpoint).finalize(subAccount);
        vm.warp(block.timestamp + 2 days);
        TestnetSaid(endpoint).finalize(subAccount);
        IAccount(account).sync();
        assertEq(IERC20(_asset).balanceOf(account), _DEPOSIT);
        assertEq(TestnetSaid(token).queueHead(), 1);
        TestnetSaid(endpoint).processUnstakeQueue(10);
        assertEq(IERC20(_asset).balanceOf(account), _DEPOSIT);
    }

    function testUsd3CashLimitedPartialExitAndFundedRepayment() public {
        (address token,,, address account) = _deploy(4, _DEPOSIT);
        TestnetYieldVault(token).deployCapital(address(this), 90e6);
        IAccount(account).sync();
        assertEq(IERC20(_asset).balanceOf(account), 10e6);
        assertApproxEqAbs(IAccount(account).totalAssets(), _DEPOSIT, 1);
        IAccount(account).sync();
        assertEq(IERC20(_asset).balanceOf(account), 10e6);
        IERC20(_asset).approve(token, 90e6);
        TestnetYieldVault(token).repayCapital(90e6, 0);
        IAccount(account).sync();
        assertEq(IERC20(_asset).balanceOf(account), _DEPOSIT);
        assertEq(IERC20(token).balanceOf(account), 0);
    }

    function testSusd3NativeUnderlyingCooldownExpiryAndRestart() public {
        (address token,, address endpoint, address account) = _deploy(5, _DEPOSIT);
        assertEq(IERC4626(token).asset(), endpoint);
        assertEq(IERC4626(endpoint).asset(), _asset);
        IAccount(account).sync();
        (uint256 end, uint256 window, uint256 shares) = TestnetSUSD3(token).getCooldownStatus(account);
        assertGt(shares, 0);
        assertEq(end, block.timestamp + 7 days);
        vm.warp(window + 1);
        IAccount(account).sync();
        (uint256 newEnd,,) = TestnetSUSD3(token).getCooldownStatus(account);
        assertEq(newEnd, window + 1 + 7 days);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        vm.warp(newEnd);
        IAccount(account).sync();
        assertEq(IERC20(_asset).balanceOf(account), _DEPOSIT);
    }

    function testTheoSingleSlotRejectsEarlyClaimAndReplayedClaim() public {
        (address token,,, address account) = _deploy(6, _DEPOSIT);
        IAccount(account).sync();
        (uint256 assets, uint256 shares, uint256 maturity) = TestnetTheoVault(token).currentRedeemRequest(account);
        assertEq(assets, _DEPOSIT);
        vm.prank(account);
        vm.expectRevert(ITestnetYieldVault.NotMature.selector);
        IERC4626(token).redeem(shares, account, account);
        vm.warp(maturity);
        IAccount(account).sync();
        assertEq(IERC20(_asset).balanceOf(account), _DEPOSIT);
        vm.prank(account);
        vm.expectRevert(ITestnetYieldVault.InvalidRequest.selector);
        IERC4626(token).redeem(shares, account, account);
    }

    function testNoonRealHandlerCustodyWaitingPeriodAndPerOwnerIds() public {
        (,, address endpoint, address account) = _deploy(7, _DEPOSIT);
        IAccount(account).sync();
        assertEq(NoonAccount(account).requestIds(0), 0);
        assertEq(TestnetNoonHandler(endpoint).getUserNextRequestId(account), 1);
        assertEq(IERC20(_asset).balanceOf(endpoint), _DEPOSIT);
        vm.expectRevert(TestnetNoonHandler.NotMature.selector);
        TestnetNoonHandler(endpoint).finalize(account, 0);
        vm.warp(block.timestamp + 2 days);
        IAccount(account).sync();
        assertEq(IERC20(_asset).balanceOf(account), 0, "maturity alone is not admin settlement");
        TestnetNoonHandler(endpoint).finalize(account, 0);
        IAccount(account).sync();
        assertEq(IERC20(_asset).balanceOf(account), _DEPOSIT);
        vm.prank(account);
        vm.expectRevert(TestnetNoonHandler.InvalidRequest.selector);
        TestnetNoonHandler(endpoint).claimWithdrawal(0);
    }

    function testInfiniFiWeeklyUnwindLossAccountingCashRetryAndReplay() public {
        (,, address endpoint, address account) = _deploy(8, _DEPOSIT);
        TestnetInfiniFiGateway(endpoint).deployCapital(address(this), _DEPOSIT);
        IAccount(account).sync();
        uint256 timestamp = InfiniFiAccount(account).unwindingTimestamps(0);
        (, uint256 maturity) = TestnetInfiniFiGateway(endpoint).positions(account, timestamp);
        assertEq(maturity % 1 weeks, 0);
        assertGe(maturity, timestamp + 4 weeks);
        TestnetInfiniFiGateway(endpoint).reportLoss(0.8e18);
        assertEq(IAccount(account).totalAssets(), 80e6);
        vm.warp(maturity);
        IAccount(account).sync();
        assertEq(
            IERC20(InfiniFiAccount(account).IUSD()).balanceOf(account), 0, "unaccrued losses prevent receipt withdrawal"
        );
        TestnetInfiniFiGateway(endpoint).accrueLoss();
        IAccount(account).sync();
        assertEq(
            IERC20(InfiniFiAccount(account).IUSD()).balanceOf(account),
            80e18,
            "empty cash cannot enqueue and burn full-minimum receipt"
        );
        assertEq(IERC20(_asset).balanceOf(account), 0);
        IERC20(_asset).approve(endpoint, 80e6);
        TestnetInfiniFiGateway(endpoint).repayCapital(80e6);
        IAccount(account).sync();
        assertEq(IERC20(_asset).balanceOf(account), 80e6);
        vm.prank(account);
        vm.expectRevert(TestnetInfiniFiGateway.InvalidRequest.selector);
        TestnetInfiniFiGateway(endpoint).withdraw(timestamp);
    }

    function testParetoNativeEpochQueueProcessingCashSettlementAndDefaultPrice() public {
        (address token, address oracle, address endpoint, address account) = _deploy(10, _DEPOSIT);
        address cdo = IParetoWithdrawalQueue(endpoint).idleCDOEpoch();
        TestnetYieldVault(token).deployCapital(address(this), 90e6);
        TestnetParetoCDO(cdo).startEpoch();
        IAccount(account).sync();
        uint256 epoch = ParetoAccount(account).queueEpochs(0);
        vm.expectRevert(TestnetParetoCDO.NotMature.selector);
        TestnetParetoCDO(cdo).stopEpoch();
        vm.expectRevert(TestnetParetoQueue.InvalidRequest.selector);
        TestnetParetoQueue(endpoint).processEpoch(epoch);
        vm.warp(block.timestamp + 7 days);
        TestnetParetoCDO(cdo).stopEpoch();
        TestnetParetoQueue(endpoint).processEpoch(epoch);
        IAccount(account).sync();
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(TestnetParetoQueue(endpoint).epochPendingClaims(epoch), _DEPOSIT);
        vm.expectRevert();
        TestnetParetoQueue(endpoint).settleEpoch(epoch);
        IERC20(_asset).approve(token, 90e6);
        TestnetYieldVault(token).repayCapital(90e6, 0);
        TestnetParetoQueue(endpoint).settleEpoch(epoch);
        IAccount(account).sync();
        assertEq(IERC20(_asset).balanceOf(account), _DEPOSIT);
        vm.prank(account);
        vm.expectRevert(TestnetParetoQueue.InvalidRequest.selector);
        TestnetParetoQueue(endpoint).claimWithdrawRequest(epoch);
        TestnetParetoCDO(cdo).setDefaulted(true);
        assertEq(IOracle(oracle).getPrice(), 0);
    }

    function testParetoDirectReceiptPathOutsideEpoch() public {
        (,, address endpoint, address account) = _deploy(10, _DEPOSIT);
        address cdo = IParetoWithdrawalQueue(endpoint).idleCDOEpoch();
        IAccount(account).sync();
        assertEq(IERC20(TestnetParetoCDO(cdo).strategy()).balanceOf(account), _DEPOSIT);
        assertEq(IAccount(account).totalAssets(), _DEPOSIT);
        IAccount(account).sync();
        assertEq(IERC20(_asset).balanceOf(account), _DEPOSIT);
        assertEq(IERC20(TestnetParetoCDO(cdo).strategy()).balanceOf(account), 0);
    }

    function testNativeProtocolsCannotBypassTheirQueuesThroughImmediateVaultExits() public {
        uint8[6] memory profiles = [uint8(2), 3, 6, 7, 8, 10];
        for (uint256 i; i < profiles.length; ++i) {
            (address token,,, address account) = _deploy(profiles[i], _DEPOSIT);
            vm.prank(account);
            vm.expectRevert();
            IERC4626(token).withdraw(1e6, account, account);
        }
        (,, address figure, address holder) = _deploy(0, _DEPOSIT);
        IAccount(holder).sync();
        address subAccount = FigureAccount(holder).subAccounts(0);
        vm.prank(subAccount);
        vm.expectRevert(ITestnetYieldVault.InvalidRequest.selector);
        IERC4626(figure).withdraw(1, holder, subAccount);
    }

    function testFuzzFundedVaultYieldAndLossConservation(uint96 deposit, uint96 loan, uint96 loss, uint96 yield)
        public
    {
        uint256 assets = bound(uint256(deposit), 1e6, 100_000e6);
        uint256 principal = bound(uint256(loan), 1, assets);
        uint256 lost = bound(uint256(loss), 0, principal);
        uint256 earned = bound(uint256(yield), 0, 100e6);
        address token = address(new TestnetYieldVault(_asset, address(this), "Credit", "CREDIT", 18));
        IERC20(_asset).approve(token, assets);
        uint256 shares = IERC4626(token).deposit(assets, address(this));
        TestnetYieldVault(token).deployCapital(address(this), principal);
        if (lost > 0) TestnetYieldVault(token).recognizeLoss(lost);
        if (principal - lost + earned > 0) {
            IERC20(_asset).approve(token, principal - lost + earned);
            TestnetYieldVault(token).repayCapital(principal - lost, earned);
        }
        assertEq(TestnetYieldVault(token).receivable(), 0);
        assertEq(IERC4626(token).totalAssets(), assets - lost + earned);
        uint256 expected = IERC4626(token).previewRedeem(shares);
        uint256 paid = IERC4626(token).redeem(shares, address(this), address(this));
        assertEq(paid, expected);
        // ERC-4626 virtual shares retain funded donation dust, especially on very small deposits.
        assertEq(paid + IERC4626(token).totalAssets(), assets - lost + earned);
        assertEq(IERC4626(token).totalSupply(), 0);
    }

    function _deploy(uint8 profile, uint256 assets)
        internal
        returns (address token, address oracle, address endpoint, address account)
    {
        address implementation;
        (token, oracle, endpoint, implementation) =
            TestnetYieldDeploymentScript(_helper).deploy(_factory, _cow, _asset, profile);
        MigratablesFactory(_factory).whitelist(implementation);
        account = MigratablesFactory(_factory)
            .create(
                uint64(MigratablesFactory(_factory).lastVersion()), address(this), abi.encode(_vault, address(this))
            );
        if (profile == 10) {
            TestnetParetoCDO(IParetoWithdrawalQueue(endpoint).idleCDOEpoch()).setWalletAllowed(account, true);
        }
        TestnetYieldDeploymentScript(_helper).seed(token, endpoint, profile, assets, account);
    }

    function _settle(uint8 profile, address endpoint, address account) internal {
        if (profile < 2) {
            vm.warp(block.timestamp + 2 days);
            TestnetFigureYieldVault(endpoint).finalize(FigureAccount(account).subAccounts(0));
        } else if (profile == 2) {
            vm.warp(block.timestamp + 2 days);
            TestnetMakinaRedeemer(endpoint).finalize(MakinaAccount(account).requestIds(0));
        } else if (profile == 3) {
            vm.warp(block.timestamp + 2 days);
            TestnetSaid(endpoint).finalize(GaibAccount(account).subAccounts(0));
        } else if (profile == 5 || profile == 6) {
            vm.warp(block.timestamp + 7 days);
        } else if (profile == 7) {
            vm.warp(block.timestamp + 2 days);
            TestnetNoonHandler(endpoint).finalize(account, NoonAccount(account).requestIds(0));
        } else if (profile == 8 || profile == 9) {
            vm.warp(block.timestamp + (profile == 8 ? 5 weeks : 14 weeks));
        } else if (profile == 10) {
            address cdo = IParetoWithdrawalQueue(endpoint).idleCDOEpoch();
            vm.warp(block.timestamp + 7 days);
            TestnetParetoCDO(cdo).stopEpoch();
            uint256 epoch = ParetoAccount(account).queueEpochs(0);
            TestnetParetoQueue(endpoint).processEpoch(epoch);
            TestnetParetoQueue(endpoint).settleEpoch(epoch);
        }
    }
}

/// @title YieldTestSettlement
/// @notice Settlement constructor ABI for yield account tests which use native same-asset redemption only.
contract YieldTestSettlement {
    function vaultRelayer() public view returns (address) {
        return address(this);
    }

    function domainSeparator() public pure returns (bytes32) {
        return keccak256("Testnet Yield Settlement");
    }
}
