// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IAccount} from "src/interfaces/ll-adapter/IAccount.sol";
import {IAssetoAccount} from "src/interfaces/ll-adapter/asseto/IAssetoAccount.sol";
import {IAssetoOracle} from "src/interfaces/ll-adapter/oracles/IAssetoOracle.sol";
import {IChainlinkOracle} from "src/interfaces/ll-adapter/oracles/IChainlinkOracle.sol";
import {ICutoffAccount} from "src/interfaces/ll-adapter/ICutoffAccount.sol";
import {IOracle} from "src/interfaces/ll-adapter/IOracle.sol";
import {ISecuritizeNoticeAccount} from "src/interfaces/ll-adapter/securitize/ISecuritizeNoticeAccount.sol";
import {ISettlementAccount} from "src/interfaces/ll-adapter/ISettlementAccount.sol";
import {ISpikoAccount} from "src/interfaces/ll-adapter/spiko/ISpikoAccount.sol";
import {ISpikoRedemption} from "src/interfaces/ll-adapter/spiko/ISpikoRedemption.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

import {
    ITestnetProviderIssuer,
    TestnetProviderDeploymentScript,
    TestnetProviderIssuer,
    TestnetSecuritizeOffRamp,
    TestnetSpikoRedemption,
    TestnetOpenEdenExpress
} from "script/deploy/testnet/protocols/TestnetProviderRedemptions.sol";
import {TestnetCowSettlement} from "script/deploy/testnet/protocols/TestnetServices.sol";
import {TestnetToken, TestnetPriceFeed} from "script/deploy/testnet/protocols/TestnetAssets.sol";

/// @title ProviderRedemptionVault
/// @notice Exposes the underlying asset required by production account initialization.
contract ProviderRedemptionVault {
    address public immutable asset;

    constructor(address newAsset) {
        asset = newAsset;
    }
}

/// @title ProviderRedemptionsTest
/// @notice Exercises every issuer dependency through its actual factory-created production account.
contract ProviderRedemptionsTest is Test {
    struct Profile {
        address token;
        address asset;
        address oracle;
        address feed;
        address endpoint;
        address account;
        uint256 tokenAmount;
        bytes32 requestId;
    }

    function setUp() public {
        vm.warp(1_790_000_000);
    }

    function testAllNineProfilesRequireCustodyAndFundedSettlement() public {
        for (uint8 profile; profile < 9; ++profile) {
            Profile memory p = _deploy(profile);
            uint256 expected = IAccount(p.account).totalAssets();
            if (profile == 2) {
                // Atomic native redemption must roll back both the share burn and allowance when unfunded.
                vm.expectRevert();
                IAccount(p.account).sync();
                assertEq(IERC20(p.token).balanceOf(p.account), p.tokenAmount);
                _fund(p, expected);
                IAccount(p.account).sync();
            } else {
                IAccount(p.account).sync();
                assertEq(IERC20(p.token).balanceOf(p.account), 0);
                assertEq(IERC20(p.asset).balanceOf(p.account), 0);
                assertEq(IAccount(p.account).totalAssets(), expected);
                if (profile == 0 || profile == 1 || profile == 5 || profile == 7 || profile == 8) {
                    assertEq(IERC20(p.token).balanceOf(p.endpoint), p.tokenAmount);
                } else {
                    assertEq(IERC20(p.token).totalSupply(), 0);
                }
                _ready(p, profile);
                vm.expectRevert();
                _settle(p, profile, expected);
                assertEq(IERC20(p.asset).balanceOf(p.account), 0);
                _fund(p, expected);
                _settle(p, profile, expected);
                IAccount(p.account).sync();
            }
            assertEq(IERC20(p.token).totalSupply(), 0);
            assertEq(IERC20(p.asset).balanceOf(p.endpoint), 0);
            assertEq(IERC20(p.asset).balanceOf(p.account), expected);
            assertEq(IAccount(p.account).totalAssets(), expected);
            IERC20(p.asset).transferFrom(p.account, address(this), expected);
            assertEq(IAccount(p.account).totalAssets(), 0);
        }
    }

    function testSuperstatePartialPayoutStaysIsolatedUntilLossExpiry() public {
        Profile memory p = _deploy(3);
        uint256 expected = IAccount(p.account).totalAssets();
        IAccount(p.account).sync();
        address subAccount = ISettlementAccount(p.account).subAccounts(0);
        IAccount(p.account).sync();
        uint48 started = uint48(vm.getBlockTimestamp());
        _ready(p, 3);
        _fund(p, expected / 2);
        _settle(p, 3, expected / 2);
        IAccount(p.account).sync();
        assertEq(IERC20(p.asset).balanceOf(subAccount), expected / 2);
        assertEq(IERC20(p.asset).balanceOf(p.account), 0);
        assertEq(IAccount(p.account).totalAssets(), expected);
        vm.warp(started + 3 days);
        assertEq(IAccount(p.account).totalAssets(), expected / 2);
        IAccount(p.account).sync();
        assertEq(IERC20(p.asset).balanceOf(subAccount), 0);
        assertEq(IERC20(p.asset).balanceOf(p.account), expected / 2);
        vm.expectRevert();
        ISettlementAccount(p.account).subAccounts(0);
    }

    function testSecuritizeNoticeShortSettlementWritesOffOnlyResidual() public {
        Profile memory p = _deploy(1);
        uint256 expected = IAccount(p.account).totalAssets();
        IAccount(p.account).sync();
        uint48 expiry = ISecuritizeNoticeAccount(p.account).pendingExpiry();
        _ready(p, 1);
        _fund(p, expected / 2);
        _settle(p, 1, expected / 2);
        IAccount(p.account).sync();
        assertEq(ISecuritizeNoticeAccount(p.account).pendingAssets(), expected / 2);
        assertEq(IAccount(p.account).totalAssets(), expected);
        vm.warp(expiry);
        IAccount(p.account).sync();
        assertEq(ISecuritizeNoticeAccount(p.account).pendingAssets(), 0);
        assertEq(IAccount(p.account).totalAssets(), expected / 2);
    }

    function testSpikoCancellationReturnsCustodyAndPausesProductionAccount() public {
        Profile memory p = _deploy(5);
        IAccount(p.account).sync();
        bytes32 id = ISpikoAccount(p.account).pendingId();
        (, uint48 deadline) = ISpikoRedemption(p.endpoint).details(id);
        vm.warp(deadline);
        IAccount(p.account).sync();
        (ISpikoRedemption.Status status,) = ISpikoRedemption(p.endpoint).details(id);
        assertEq(uint8(status), uint8(ISpikoRedemption.Status.CANCELED));
        assertEq(IERC20(p.token).balanceOf(p.account), p.tokenAmount);
        assertEq(IERC20(p.token).balanceOf(p.endpoint), 0);
        assertEq(ISpikoAccount(p.account).pendingId(), bytes32(0));
        assertTrue(ISpikoAccount(p.account).redemptionPaused());
        vm.prank(makeAddr("keeper"));
        IAccount(p.account).sync();
        assertEq(ISpikoAccount(p.account).pendingId(), bytes32(0));
    }

    function testSpikoShortExecutionWritesOffAfterSettlementWindow() public {
        Profile memory p = _deploy(5);
        uint256 expected = IAccount(p.account).totalAssets();
        IAccount(p.account).sync();
        uint48 expiry = ISpikoAccount(p.account).pendingExpiry();
        _ready(p, 5);
        _fund(p, expected / 2);
        _settle(p, 5, expected / 2);
        IAccount(p.account).sync();
        assertEq(ISpikoAccount(p.account).pendingAssets(), expected / 2);
        assertEq(IAccount(p.account).totalAssets(), expected);
        vm.warp(expiry);
        IAccount(p.account).sync();
        assertEq(ISpikoAccount(p.account).pendingId(), bytes32(0));
        assertTrue(ISpikoAccount(p.account).redemptionPaused());
        assertEq(IAccount(p.account).totalAssets(), expected / 2);
    }

    function testOpenEdenFinalQueuePriceRemainsLockedAfterFreshPriceChanges() public {
        Profile memory p = _deploy(7);
        uint256 expected = IAccount(p.account).totalAssets();
        IAccount(p.account).sync();
        assertEq(TestnetOpenEdenExpress(p.endpoint).pendingRedeemInfo(p.account), p.tokenAmount);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        TestnetOpenEdenExpress(p.endpoint).lock(0);
        assertEq(TestnetOpenEdenExpress(p.endpoint).getRedeemQueueLength(), 1);
        assertEq(TestnetOpenEdenExpress(p.endpoint).pendingRedeemInfo(p.account), 0);
        assertEq(TestnetOpenEdenExpress(p.endpoint).redeemInfo(p.account), p.tokenAmount);
        TestnetPriceFeed(TestnetOpenEdenExpress(p.endpoint).priceOracle()).publish(2e18);
        assertEq(IAccount(p.account).totalAssets(), expected);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _fund(p, expected);
        _settle(p, 7, expected);
        assertEq(TestnetOpenEdenExpress(p.endpoint).getRedeemQueueLength(), 0);
        assertEq(TestnetOpenEdenExpress(p.endpoint).redeemInfo(p.account), 0);
        assertEq(IAccount(p.account).totalAssets(), expected);
    }

    function testAcredCannotSettleBeforeCutoffOrWithoutPostCutoffValuation() public {
        Profile memory p = _deploy(0);
        IAccount(p.account).sync();
        uint48 cutoff = ICutoffAccount(p.account).bucketToTimestamp(ICutoffAccount(p.account).currentBucket());
        uint256 expected = IAccount(p.account).totalAssets();
        _fund(p, expected);
        vm.expectRevert(ITestnetProviderIssuer.NotReady.selector);
        TestnetProviderIssuer(p.endpoint).settle(0, expected);
        vm.warp(cutoff + 4 days);
        vm.expectRevert();
        TestnetProviderIssuer(p.endpoint).settle(0, expected);
        TestnetPriceFeed(p.feed).publish(100e18);
        IAccount(p.account).sync();
        TestnetPriceFeed(p.feed).publish(200e18);
        assertEq(IAccount(p.account).totalAssets(), expected);
        vm.expectRevert(ITestnetProviderIssuer.InvalidRequest.selector);
        TestnetProviderIssuer(p.endpoint).settle(0, expected + 1);
        TestnetProviderIssuer(p.endpoint).settle(0, expected);
        assertEq(IERC20(p.asset).balanceOf(p.account), expected);
    }

    function testOffRampRejectsMinimumAndProductionOracleFloor() public {
        Profile memory p = _deploy(2);
        uint256 quote = TestnetSecuritizeOffRamp(p.endpoint).calculateLiquidityTokenAmount(p.tokenAmount);
        _fund(p, quote);
        TestnetToken(p.token).mint(address(this), p.tokenAmount);
        IERC20(p.token).approve(p.endpoint, p.tokenAmount);
        vm.expectRevert(ITestnetProviderIssuer.InvalidRequest.selector);
        TestnetSecuritizeOffRamp(p.endpoint).redeem(p.tokenAmount, quote + 1);
        TestnetSecuritizeOffRamp(p.endpoint).setFee(1);
        vm.expectRevert();
        IAccount(p.account).sync();
        assertEq(IERC20(p.token).balanceOf(p.account), p.tokenAmount);
        assertEq(IERC20(p.asset).balanceOf(p.endpoint), quote);
    }

    function testSettlementAndShareIssuanceRejectNonOwnersForEveryProfile() public {
        address stranger = makeAddr("unauthorized issuer");
        for (uint8 profile; profile < 9; ++profile) {
            Profile memory p = _deploy(profile);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
            vm.prank(stranger);
            TestnetToken(p.token).mint(stranger, 1);
            if (profile == 2) {
                vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
                vm.prank(stranger);
                TestnetSecuritizeOffRamp(p.endpoint).setFee(1);
            } else {
                IAccount(p.account).sync();
                bytes32 id = profile == 5 ? ISpikoAccount(p.account).pendingId() : bytes32(0);
                vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
                vm.prank(stranger);
                if (profile == 5) TestnetSpikoRedemption(p.endpoint).settle(id, 1);
                else if (profile == 7) TestnetOpenEdenExpress(p.endpoint).lock(0);
                else TestnetProviderIssuer(p.endpoint).settle(0, 1);
            }
        }
    }

    function testNativeManagersRejectForgedTokenCallbacksAndWrongRoutes() public {
        Profile memory p = _deploy(3);
        vm.expectRevert(ITestnetProviderIssuer.InvalidCaller.selector);
        TestnetProviderIssuer(p.endpoint).onBurn(address(this), 1e6);
        p = _deploy(4);
        vm.expectRevert(ITestnetProviderIssuer.InvalidRoute.selector);
        TestnetProviderIssuer(p.endpoint).redeem(p.token, makeAddr("wrong stablecoin"), 1e6, vm.getBlockTimestamp());
        p = _deploy(5);
        vm.expectRevert(ITestnetProviderIssuer.InvalidCaller.selector);
        TestnetSpikoRedemption(p.endpoint).onTransferReceived(address(this), address(this), 1e5, "");
        p = _deploy(6);
        vm.expectRevert(ITestnetProviderIssuer.InvalidRequest.selector);
        TestnetProviderIssuer(p.endpoint).requestRedemptionServicedOffchain(1e18 - 1, bytes32(uint256(1)));
    }

    function testAllProductionOracleProfilesRejectStalePricesAndRecoverAfterPublication() public {
        for (uint8 profile; profile < 9; ++profile) {
            Profile memory p = _deploy(profile);
            uint256 expected = IAccount(p.account).totalAssets();
            vm.warp(vm.getBlockTimestamp() + 30 hours + 1);
            vm.expectRevert();
            IAccount(p.account).totalAssets();
            (, int256 price,,,) = TestnetPriceFeed(p.feed).latestRoundData();
            TestnetPriceFeed(p.feed).publish(price);
            assertEq(IAccount(p.account).totalAssets(), expected);
        }
    }

    function testNativeStacVbillSpikoOracleBoundsAreEnforced() public {
        Profile memory p = _deploy(1);
        TestnetPriceFeed(p.feed).publish(99e18);
        vm.expectRevert(IOracle.InvalidPrice.selector);
        IAccount(p.account).totalAssets();
        p = _deploy(2);
        TestnetPriceFeed(p.feed).publish(0.94e18);
        vm.expectRevert(IOracle.InvalidPrice.selector);
        IAccount(p.account).totalAssets();
        p = _deploy(5);
        TestnetPriceFeed(p.feed).publish(2e18 + 1);
        vm.expectRevert(IOracle.InvalidPrice.selector);
        IAccount(p.account).totalAssets();
    }

    function testFuzzSpikoRestrictedInvestorsKeepNativeCustodyAndFundedPayoutExact(uint128 rawShares) public {
        Profile memory p = _deploy(5);
        uint256 amount = bound(uint256(rawShares), 1e5, 1_000_000e5);
        if (amount > p.tokenAmount) {
            TestnetToken(p.token).mint(p.account, amount - p.tokenAmount);
        } else if (amount < p.tokenAmount) {
            vm.prank(p.account);
            TestnetToken(p.token).burn(p.tokenAmount - amount);
        }
        TestnetToken(p.token).setInvestor(p.account, true);
        TestnetToken(p.token).setInvestor(p.endpoint, true);
        TestnetToken(p.token).setRestricted(true);
        vm.expectRevert(TestnetToken.InvalidInvestor.selector);
        vm.prank(p.account);
        IERC20(p.token).transfer(makeAddr("unenrolled investor"), 1);
        uint256 expected = IAccount(p.account).totalAssets();
        IAccount(p.account).sync();
        assertEq(IERC20(p.token).balanceOf(p.endpoint), amount);
        assertEq(IERC20(p.token).balanceOf(p.account), 0);
        _ready(p, 5);
        _fund(p, expected);
        _settle(p, 5, expected);
        IAccount(p.account).sync();
        assertEq(IERC20(p.token).totalSupply(), 0);
        assertEq(ISpikoAccount(p.account).pendingId(), bytes32(0));
        assertEq(IERC20(p.asset).balanceOf(p.endpoint), 0);
        assertEq(IERC20(p.asset).balanceOf(p.account), expected);
    }

    function _deploy(uint8 profile) internal returns (Profile memory p) {
        p.asset = address(new TestnetToken("Testnet USDC", "USDC", 6, address(this)));
        address factory = address(new MigratablesFactory(address(this)));
        address cow = address(new TestnetCowSettlement());
        address implementation;
        (p.token, p.oracle, p.endpoint, implementation) =
            new TestnetProviderDeploymentScript(address(this), false).deploy(factory, cow, p.asset, profile);
        p.feed = profile == 6
            ? IAssetoOracle(p.oracle).PRICER()
            : profile == 7
                ? TestnetOpenEdenExpress(p.endpoint).priceOracle()
                : IChainlinkOracle(p.oracle).AGGREGATOR_0();
        MigratablesFactory(factory).whitelist(implementation);
        address vault = address(new ProviderRedemptionVault(p.asset));
        bytes memory init = profile == 6
            ? abi.encode(
                IAssetoAccount.InitParams({
                    vault: vault,
                    adapter: address(this),
                    offChainDestination: keccak256("testnet investor bank account")
                })
            )
            : abi.encode(vault, address(this));
        p.account = MigratablesFactory(factory).create(1, address(this), init);
        p.tokenAmount = 10 * 10 ** IERC20Metadata(p.token).decimals();
        TestnetToken(p.token).mint(p.account, p.tokenAmount);
    }

    function _fund(Profile memory p, uint256 amount) internal {
        TestnetToken(p.asset).mint(address(this), amount);
        IERC20(p.asset).transfer(p.endpoint, amount);
    }

    function _ready(Profile memory p, uint8 profile) internal {
        if (profile == 5) {
            p.requestId = ISpikoAccount(p.account).pendingId();
            vm.warp(vm.getBlockTimestamp() + 1 hours);
        } else if (profile == 0 || profile == 8) {
            vm.warp(ICutoffAccount(p.account).bucketToTimestamp(ICutoffAccount(p.account).currentBucket()) + 4 days);
        } else {
            vm.warp(vm.getBlockTimestamp() + 1 days);
        }
        (, int256 price,,,) = TestnetPriceFeed(p.feed).latestRoundData();
        TestnetPriceFeed(p.feed).publish(price);
        if (profile == 7) {
            TestnetOpenEdenExpress(p.endpoint).lock(0);
            vm.warp(vm.getBlockTimestamp() + 1 days);
        } else {
            IAccount(p.account).sync();
        }
    }

    function _settle(Profile memory p, uint8 profile, uint256 amount) internal {
        if (profile == 5) TestnetSpikoRedemption(p.endpoint).settle(p.requestId, amount);
        else if (profile == 7) TestnetOpenEdenExpress(p.endpoint).settle(0, amount);
        else TestnetProviderIssuer(p.endpoint).settle(0, amount);
    }
}
