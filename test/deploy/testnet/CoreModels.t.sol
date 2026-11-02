// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {MidasCompAccount, MidasNonCompAccount} from "src/contracts/ll-adapter/MidasAccount.sol";
import {MidasOracle} from "src/contracts/ll-adapter/oracles/MidasOracle.sol";

import {GPv2Order} from "src/libraries/GPv2Order.sol";

import {IAccount} from "src/interfaces/ll-adapter/IAccount.sol";
import {IMidasAccount} from "src/interfaces/ll-adapter/midas/IMidasAccount.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {
    TestnetCowSettlement,
    TestnetCowRelayer,
    TestnetMerklDistributor
} from "script/deploy/testnet/protocols/TestnetServices.sol";
import {TestnetMidasRedemptionVault, TestnetAsyncVault} from "script/deploy/testnet/protocols/TestnetRedemptions.sol";
import {TestnetToken, TestnetPriceFeed} from "script/deploy/testnet/protocols/TestnetAssets.sol";

/// @title CoreModelVaultAsset
/// @notice Provides the underlying asset needed to initialize genuine production accounts.
contract CoreModelVaultAsset {
    address public immutable asset;

    constructor(address newAsset) {
        asset = newAsset;
    }
}

/// @title CoreModelTestBase
/// @notice Common controlled issuance and timestamp fixtures for independent model verification.
abstract contract CoreModelTestBase is Test {
    function setUp() public virtual {
        vm.warp(1_790_000_000);
    }

    function _token(uint8 decimals) internal returns (address) {
        return address(new TestnetToken("Model test asset", "TEST", decimals, address(this)));
    }

    function _feed(int256 price) internal returns (address) {
        return address(new TestnetPriceFeed(address(this), "Model test NAV", 18, 30 hours, price));
    }
}

/// @title CoreRedemptionModelsTest
/// @notice Verifies native issuer custody, fees, rates, funded fulfillment, IDs, and partial claims.
contract CoreRedemptionModelsTest is CoreModelTestBase {
    struct MidasFixture {
        address token;
        address asset;
        address feed;
        address redemption;
        address account;
    }

    struct AsyncFixture {
        address asset;
        address feed;
        address vault;
        address alice;
        address bob;
    }

    function testMidasProductionCompAndNonCompUseDifferentPendingRates() public {
        for (uint256 kind; kind < 2; ++kind) {
            MidasFixture memory f = _midas(kind == 0);
            TestnetToken(f.token).mint(f.account, 1000e18);
            IAccount(f.account).sync();
            assertEq(IERC20(f.token).balanceOf(f.account), 0);
            assertEq(IERC20(f.token).balanceOf(f.redemption), 1000e18);
            (address sender, address output, uint8 status, uint256 amount, uint256 rate, uint256 outputRate) =
                TestnetMidasRedemptionVault(f.redemption).redeemRequests(0);
            assertEq(sender, f.account);
            assertEq(output, f.asset);
            assertEq(status, 0);
            assertEq(amount, 995e18);
            assertEq(rate, 2e18);
            assertEq(outputRate, 1e18);
            assertEq(IAccount(f.account).totalAssets(), 1990e6);
            TestnetPriceFeed(f.feed).publish(3e18);
            assertEq(IAccount(f.account).totalAssets(), kind == 0 ? 2985e6 : 1990e6);
            vm.expectRevert(TestnetMidasRedemptionVault.NotReady.selector);
            TestnetMidasRedemptionVault(f.redemption).approveRequest(0);
            vm.warp(TestnetMidasRedemptionVault(f.redemption).readyAt(0));
            uint256 settlementRate = kind == 0 ? 3e18 : 2e18;
            uint256 payout = kind == 0 ? 2985e6 : 1990e6;
            vm.expectRevert();
            TestnetMidasRedemptionVault(f.redemption).settleRequest(0, settlementRate);
            (,, status,, rate,) = TestnetMidasRedemptionVault(f.redemption).redeemRequests(0);
            assertEq(status, 0);
            assertEq(rate, 2e18);
            assertEq(IERC20(f.token).balanceOf(f.redemption), 1000e18);
            TestnetToken(f.asset).mint(address(this), payout);
            IERC20(f.asset).transfer(f.redemption, payout);
            TestnetMidasRedemptionVault(f.redemption).settleRequest(0, settlementRate);
            IAccount(f.account).sync();
            assertEq(IAccount(f.account).totalAssets(), payout);
            assertEq(IERC20(f.token).totalSupply(), 5e18);
            assertEq(IERC20(f.token).balanceOf(f.redemption), 5e18);
            vm.expectRevert();
            IMidasAccount(f.account).requestIds(0);
            vm.expectRevert(TestnetMidasRedemptionVault.InvalidRequest.selector);
            TestnetMidasRedemptionVault(f.redemption).approveRequest(0);
        }
    }

    function testMidasRejectedNoticeReturnsOnlyNetSharesAndCannotBeApprovedAgain() public {
        MidasFixture memory f = _midas(false);
        TestnetToken(f.token).mint(f.account, 100e18);
        IAccount(f.account).sync();
        TestnetMidasRedemptionVault(f.redemption).rejectRequest(0);
        assertEq(IERC20(f.token).balanceOf(f.account), 99.5e18);
        assertEq(IERC20(f.token).balanceOf(f.redemption), 0.5e18);
        assertEq(IERC20(f.token).totalSupply(), 100e18);
        assertEq(IAccount(f.account).totalAssets(), 199e6);
        vm.expectRevert(TestnetMidasRedemptionVault.InvalidRequest.selector);
        TestnetMidasRedemptionVault(f.redemption).rejectRequest(0);
        vm.expectRevert(TestnetMidasRedemptionVault.InvalidRequest.selector);
        TestnetMidasRedemptionVault(f.redemption).approveRequest(0);
    }

    function testMidasInvalidRequestsStalePublicationAndIssuerPermissions() public {
        MidasFixture memory f = _midas(true);
        vm.expectRevert(TestnetMidasRedemptionVault.InvalidRequest.selector);
        TestnetMidasRedemptionVault(f.redemption).approveRequest(999);
        vm.expectRevert(TestnetMidasRedemptionVault.InvalidRequest.selector);
        TestnetMidasRedemptionVault(f.redemption).redeemRequest(f.asset, 0);
        vm.expectRevert(TestnetMidasRedemptionVault.InvalidRequest.selector);
        TestnetMidasRedemptionVault(f.redemption).redeemRequest(f.token, 1);
        TestnetToken(f.token).mint(f.account, 10e18);
        vm.warp(vm.getBlockTimestamp() + 30 hours + 1);
        vm.expectRevert(TestnetPriceFeed.StalePrice.selector);
        IAccount(f.account).sync();
        assertEq(IERC20(f.token).balanceOf(f.account), 10e18);
        TestnetPriceFeed(f.feed).publish(2e18);
        IAccount(f.account).sync();
        address stranger = makeAddr("unauthorized issuer");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        TestnetMidasRedemptionVault(f.redemption).rejectRequest(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        TestnetMidasRedemptionVault(f.redemption).settleRequest(0, 2e18);
    }

    function testFuzzMidasFeesConserveCustodyAcrossApproval(uint96 rawAmount, uint16 rawFee) public {
        uint256 amount = bound(uint256(rawAmount), 1e18, 1_000_000e18);
        uint256 fee = bound(uint256(rawFee), 0, 1000);
        address token = _token(18);
        address asset = _token(6);
        address redemption = address(new TestnetMidasRedemptionVault(address(this), token, _feed(2e18), asset, 0, fee));
        TestnetToken(token).mint(address(this), amount);
        IERC20(token).approve(redemption, amount);
        TestnetMidasRedemptionVault(redemption).redeemRequest(asset, amount);
        uint256 retainedFee = amount * fee / 10_000;
        uint256 payout = (amount - retainedFee) * 2 / 1e12;
        TestnetToken(asset).mint(address(this), payout);
        IERC20(asset).transfer(redemption, payout);
        TestnetMidasRedemptionVault(redemption).approveRequest(0);
        assertEq(IERC20(asset).balanceOf(address(this)), payout);
        assertEq(IERC20(asset).balanceOf(redemption), 0);
        assertEq(IERC20(token).balanceOf(redemption), retainedFee);
        assertEq(IERC20(token).totalSupply(), retainedFee);
    }

    function testAsyncMintRequiresRealFundingAndApprovedCustody() public {
        AsyncFixture memory f = _async();
        vm.expectRevert();
        TestnetAsyncVault(f.vault).mint(f.alice, 100e18);
        assertEq(IERC20(f.vault).totalSupply(), 0);
        TestnetToken(f.asset).mint(address(this), 100e6);
        IERC20(f.asset).approve(f.vault, 100e6);
        TestnetAsyncVault(f.vault).mint(f.alice, 100e18);
        assertEq(IERC20(f.asset).balanceOf(f.vault), 100e6);
        assertEq(IERC20(f.vault).balanceOf(f.alice), 100e18);
        address stranger = makeAddr("unauthorized share issuer");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        TestnetAsyncVault(f.vault).mint(stranger, 1);
    }

    function testAsyncRequestIdsControllerRolesAndPartialClaimsUseLockedPrice() public {
        AsyncFixture memory f = _async();
        _mintAsync(f, f.alice, 100e18);
        vm.prank(f.alice);
        uint256 id = TestnetAsyncVault(f.vault).requestRedeem(100e18, f.alice, f.alice);
        assertEq(IERC20(f.vault).balanceOf(f.vault), 100e18);
        assertEq(TestnetAsyncVault(f.vault).pendingRedeemRequest(0, f.alice), 100e18);
        assertEq(TestnetAsyncVault(f.vault).pendingRedeemRequest(id, f.alice), 100e18);
        assertEq(TestnetAsyncVault(f.vault).pendingRedeemRequest(id + 1, f.alice), 0);
        assertEq(TestnetAsyncVault(f.vault).pendingRedeemRequest(id, f.bob), 0);
        vm.expectRevert(TestnetAsyncVault.NotReady.selector);
        TestnetAsyncVault(f.vault).fulfill(f.alice);
        vm.warp(TestnetAsyncVault(f.vault).readyAt(f.alice));
        TestnetAsyncVault(f.vault).fulfill(f.alice);
        assertEq(TestnetAsyncVault(f.vault).reservedAssets(), 100e6);
        assertEq(TestnetAsyncVault(f.vault).claimableRedeemRequest(id, f.alice), 100e18);
        assertEq(TestnetAsyncVault(f.vault).claimableRedeemRequest(id + 1, f.alice), 0);
        TestnetPriceFeed(f.feed).publish(2e18);
        vm.expectRevert(TestnetAsyncVault.InvalidRequest.selector);
        vm.prank(f.bob);
        TestnetAsyncVault(f.vault).redeem(40e18, f.bob, f.alice);
        vm.prank(f.alice);
        uint256 paid = TestnetAsyncVault(f.vault).redeem(40e18, f.bob, f.alice);
        assertEq(paid, 40e6);
        assertEq(IERC20(f.asset).balanceOf(f.bob), 40e6);
        assertEq(TestnetAsyncVault(f.vault).maxWithdraw(f.alice), 60e6);
        assertEq(TestnetAsyncVault(f.vault).maxRedeem(f.alice), 60e18);
        vm.expectRevert(TestnetAsyncVault.InvalidRequest.selector);
        vm.prank(f.alice);
        TestnetAsyncVault(f.vault).requestRedeem(1, f.alice, f.alice);
        vm.prank(f.alice);
        TestnetAsyncVault(f.vault).redeem(60e18, f.alice, f.alice);
        assertEq(TestnetAsyncVault(f.vault).activeRequest(f.alice), 0);
        assertEq(TestnetAsyncVault(f.vault).claimableRedeemRequest(id, f.alice), 0);
        assertEq(TestnetAsyncVault(f.vault).reservedAssets(), 0);
        assertEq(IERC20(f.vault).totalSupply(), 0);
        assertEq(IERC20(f.asset).balanceOf(f.vault), 0);
    }

    function testAsyncFulfillmentCannotSpendAnotherControllersReservedCash() public {
        AsyncFixture memory f = _async();
        _mintAsync(f, f.alice, 100e18);
        _mintAsync(f, f.bob, 100e18);
        vm.prank(f.alice);
        TestnetAsyncVault(f.vault).requestRedeem(100e18, f.alice, f.alice);
        vm.prank(f.bob);
        TestnetAsyncVault(f.vault).requestRedeem(100e18, f.bob, f.bob);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        TestnetAsyncVault(f.vault).fulfill(f.alice);
        TestnetPriceFeed(f.feed).publish(1.5e18);
        vm.expectRevert(TestnetAsyncVault.NotReady.selector);
        TestnetAsyncVault(f.vault).fulfill(f.bob);
        assertEq(TestnetAsyncVault(f.vault).reservedAssets(), 100e6);
        assertEq(TestnetAsyncVault(f.vault).pending(f.bob), 100e18);
        assertEq(TestnetAsyncVault(f.vault).claimable(f.bob), 0);
        TestnetToken(f.asset).mint(f.vault, 50e6);
        TestnetAsyncVault(f.vault).fulfill(f.bob);
        assertEq(TestnetAsyncVault(f.vault).reservedAssets(), 250e6);
        vm.prank(f.alice);
        TestnetAsyncVault(f.vault).redeem(100e18, f.alice, f.alice);
        vm.prank(f.bob);
        TestnetAsyncVault(f.vault).redeem(100e18, f.bob, f.bob);
        assertEq(IERC20(f.asset).balanceOf(f.alice), 100e6);
        assertEq(IERC20(f.asset).balanceOf(f.bob), 150e6);
        assertEq(IERC20(f.asset).balanceOf(f.vault), 0);
    }

    function testAsyncDelegatedRequestNeedsShareOwnerApprovalAndIssuerMustOwnFulfillment() public {
        AsyncFixture memory f = _async();
        _mintAsync(f, f.alice, 100e18);
        vm.expectRevert();
        vm.prank(f.bob);
        TestnetAsyncVault(f.vault).requestRedeem(30e18, f.bob, f.alice);
        assertEq(TestnetAsyncVault(f.vault).pending(f.bob), 0);
        vm.prank(f.alice);
        IERC20(f.vault).approve(f.bob, 30e18);
        vm.prank(f.bob);
        uint256 id = TestnetAsyncVault(f.vault).requestRedeem(30e18, f.bob, f.alice);
        assertEq(IERC20(f.vault).balanceOf(f.alice), 70e18);
        assertEq(TestnetAsyncVault(f.vault).pendingRedeemRequest(id, f.bob), 30e18);
        vm.warp(TestnetAsyncVault(f.vault).readyAt(f.bob));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, f.bob));
        vm.prank(f.bob);
        TestnetAsyncVault(f.vault).fulfill(f.bob);
        TestnetAsyncVault(f.vault).fulfill(f.bob);
        vm.prank(f.bob);
        TestnetAsyncVault(f.vault).redeem(30e18, f.bob, f.bob);
        assertEq(IERC20(f.asset).balanceOf(f.bob), 30e6);
        assertEq(IERC20(f.asset).balanceOf(f.vault), 70e6);
        assertEq(TestnetAsyncVault(f.vault).activeRequest(f.bob), 0);
    }

    function _midas(bool compounding) internal returns (MidasFixture memory f) {
        f.token = _token(18);
        f.asset = _token(6);
        f.feed = _feed(2e18);
        f.redemption = address(new TestnetMidasRedemptionVault(address(this), f.token, f.feed, f.asset, 1 days, 50));
        address factory = address(new MigratablesFactory(address(this)));
        address oracle = address(new MidasOracle(1e18, 10e18, f.feed));
        address cow = address(new TestnetCowSettlement());
        address implementation = compounding
            ? address(new MidasCompAccount(oracle, factory, 12 hours, f.token, f.asset, f.redemption, cow))
            : address(new MidasNonCompAccount(oracle, factory, 12 hours, f.token, f.asset, f.redemption, cow));
        MigratablesFactory(factory).whitelist(implementation);
        f.account = MigratablesFactory(factory)
            .create(1, address(this), abi.encode(address(new CoreModelVaultAsset(f.asset)), address(this)));
    }

    function _async() internal returns (AsyncFixture memory f) {
        f.asset = _token(6);
        f.feed = _feed(1e18);
        f.vault = address(new TestnetAsyncVault(address(this), f.asset, f.feed, 1 days, "Async shares", "ASYNC"));
        f.alice = makeAddr("async alice");
        f.bob = makeAddr("async bob");
    }

    function _mintAsync(AsyncFixture memory f, address receiver, uint256 shares) internal {
        uint256 assets = TestnetAsyncVault(f.vault).convertToAssets(shares);
        TestnetToken(f.asset).mint(address(this), assets);
        IERC20(f.asset).approve(f.vault, assets);
        TestnetAsyncVault(f.vault).mint(receiver, shares);
    }
}

/// @title CoreSettlementModelsTest
/// @notice Verifies canonical CoW authorization and limits, funded atomic fills, and cumulative Merkl claims.
contract CoreSettlementModelsTest is CoreModelTestBase {
    struct CowFixture {
        address sell;
        address buy;
        address settlement;
        address owner;
        address solver;
        address receiver;
        GPv2Order.Data order;
        bytes uid;
    }

    function testCowCanonicalDomainUidAndFundedPartialFillAreExact() public {
        CowFixture memory f = _cow();
        bytes32 independentDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Gnosis Protocol"),
                keccak256("v2"),
                block.chainid,
                f.settlement
            )
        );
        assertEq(TestnetCowSettlement(f.settlement).domainSeparator(), independentDomain);
        assertEq(f.uid.length, 56);
        assertEq(f.uid, abi.encodePacked(_digest(f.order, independentDomain), f.owner, f.order.validTo));
        vm.prank(f.solver);
        TestnetCowSettlement(f.settlement).fill(f.order, f.uid, 40e18, 80e6);
        assertEq(TestnetCowSettlement(f.settlement).filledAmount(f.uid), 40e18);
        assertEq(IERC20(f.sell).balanceOf(f.solver), 41.2e18);
        assertEq(IERC20(f.buy).balanceOf(f.receiver), 80e6);
        vm.prank(f.solver);
        TestnetCowSettlement(f.settlement).fill(f.order, f.uid, 60e18, 120e6);
        assertEq(IERC20(f.sell).balanceOf(f.owner), 0);
        assertEq(IERC20(f.sell).balanceOf(f.solver), 103e18);
        assertEq(IERC20(f.buy).balanceOf(f.receiver), 200e6);
        vm.expectRevert(TestnetCowSettlement.InvalidOrder.selector);
        vm.prank(f.solver);
        TestnetCowSettlement(f.settlement).fill(f.order, f.uid, 1, 1);
    }

    function testCowFundingAndSellApprovalFailuresRollBackBothLegsAndFillCounter() public {
        CowFixture memory f = _cow();
        vm.prank(f.solver);
        TestnetToken(f.buy).burn(200e6 + 2);
        vm.expectRevert();
        vm.prank(f.solver);
        TestnetCowSettlement(f.settlement).fill(f.order, f.uid, 40e18, 80e6);
        assertEq(TestnetCowSettlement(f.settlement).filledAmount(f.uid), 0);
        assertEq(IERC20(f.sell).balanceOf(f.owner), 103e18);
        TestnetToken(f.buy).mint(f.solver, 200e6 + 2);
        address relayer = TestnetCowSettlement(f.settlement).vaultRelayer();
        vm.prank(f.owner);
        IERC20(f.sell).approve(relayer, 0);
        vm.expectRevert();
        vm.prank(f.solver);
        TestnetCowSettlement(f.settlement).fill(f.order, f.uid, 40e18, 80e6);
        assertEq(IERC20(f.buy).balanceOf(f.receiver), 0);
        assertEq(IERC20(f.buy).balanceOf(f.solver), 200e6 + 2);
        assertEq(TestnetCowSettlement(f.settlement).filledAmount(f.uid), 0);
        vm.expectRevert(TestnetCowRelayer.InvalidCaller.selector);
        TestnetCowRelayer(relayer).transferFrom(f.sell, f.owner, address(this), 1);
    }

    function testCowUnauthorizedPresignatureRevocationExpiryAndForeignDigestFail() public {
        CowFixture memory f = _cow();
        vm.expectRevert(TestnetCowSettlement.InvalidOrder.selector);
        TestnetCowSettlement(f.settlement).setPreSignature(f.uid, true);
        vm.prank(f.owner);
        TestnetCowSettlement(f.settlement).setPreSignature(f.uid, false);
        vm.expectRevert(TestnetCowSettlement.InvalidOrder.selector);
        vm.prank(f.solver);
        TestnetCowSettlement(f.settlement).fill(f.order, f.uid, 1e18, 2e6);
        vm.prank(f.owner);
        TestnetCowSettlement(f.settlement).setPreSignature(f.uid, true);
        GPv2Order.Data memory modified = abi.decode(abi.encode(f.order), (GPv2Order.Data));
        modified.receiver = address(this);
        vm.expectRevert(TestnetCowSettlement.InvalidOrder.selector);
        vm.prank(f.solver);
        TestnetCowSettlement(f.settlement).fill(modified, f.uid, 1e18, 2e6);
        vm.warp(uint256(f.order.validTo) + 1);
        vm.expectRevert(TestnetCowSettlement.InvalidOrder.selector);
        vm.prank(f.solver);
        TestnetCowSettlement(f.settlement).fill(f.order, f.uid, 1e18, 2e6);
    }

    function testCowMinimumOutputRoundsUpAndNonPartialOrdersRejectPartialFills() public {
        CowFixture memory f = _cow();
        vm.expectRevert(TestnetCowSettlement.InvalidOrder.selector);
        vm.prank(f.solver);
        TestnetCowSettlement(f.settlement).fill(f.order, f.uid, 1, 0);
        vm.prank(f.solver);
        TestnetCowSettlement(f.settlement).fill(f.order, f.uid, 1, 1);
        f.order.partiallyFillable = false;
        f.uid = _uid(f);
        vm.prank(f.owner);
        TestnetCowSettlement(f.settlement).setPreSignature(f.uid, true);
        vm.expectRevert(TestnetCowSettlement.InvalidOrder.selector);
        vm.prank(f.solver);
        TestnetCowSettlement(f.settlement).fill(f.order, f.uid, 40e18, 80e6);
        assertEq(TestnetCowSettlement(f.settlement).filledAmount(f.uid), 0);
    }

    function testCowSignedUnsupportedModesFailAndDefaultReceiverIsOrderOwner() public {
        CowFixture memory f = _cow();
        for (uint256 mode; mode < 3; ++mode) {
            GPv2Order.Data memory order = abi.decode(abi.encode(f.order), (GPv2Order.Data));
            if (mode == 0) order.kind = keccak256("buy");
            else if (mode == 1) order.sellTokenBalance = keccak256("external");
            else order.buyTokenBalance = keccak256("internal");
            bytes memory uid = abi.encodePacked(
                _digest(order, TestnetCowSettlement(f.settlement).domainSeparator()), f.owner, order.validTo
            );
            vm.prank(f.owner);
            TestnetCowSettlement(f.settlement).setPreSignature(uid, true);
            vm.expectRevert(TestnetCowSettlement.InvalidOrder.selector);
            vm.prank(f.solver);
            TestnetCowSettlement(f.settlement).fill(order, uid, 40e18, 80e6);
            assertEq(TestnetCowSettlement(f.settlement).filledAmount(uid), 0);
        }
        f.order.receiver = address(0);
        f.uid = _uid(f);
        vm.prank(f.owner);
        TestnetCowSettlement(f.settlement).setPreSignature(f.uid, true);
        vm.prank(f.solver);
        TestnetCowSettlement(f.settlement).fill(f.order, f.uid, 100e18, 200e6);
        assertEq(IERC20(f.buy).balanceOf(f.owner), 200e6);
        assertEq(IERC20(f.buy).balanceOf(f.receiver), 0);
    }

    function testFuzzCowTwoFillsChargeExactlyTheSignedFeeAndCannotOverfill(uint96 rawSplit) public {
        CowFixture memory f = _cow();
        uint256 first = bound(uint256(rawSplit), 1, 100e18 - 1);
        uint256 firstBuy = (first * 200e6 + 100e18 - 1) / 100e18;
        uint256 secondBuy = ((100e18 - first) * 200e6 + 100e18 - 1) / 100e18;
        vm.prank(f.solver);
        TestnetCowSettlement(f.settlement).fill(f.order, f.uid, first, firstBuy);
        vm.prank(f.solver);
        TestnetCowSettlement(f.settlement).fill(f.order, f.uid, 100e18 - first, secondBuy);
        assertEq(IERC20(f.sell).balanceOf(f.solver), 103e18);
        assertEq(IERC20(f.sell).balanceOf(f.owner), 0);
        assertEq(TestnetCowSettlement(f.settlement).filledAmount(f.uid), 100e18);
        assertGe(IERC20(f.buy).balanceOf(f.receiver), 200e6);
        assertLe(IERC20(f.buy).balanceOf(f.receiver), 200e6 + 1);
        vm.expectRevert(TestnetCowSettlement.InvalidOrder.selector);
        vm.prank(f.solver);
        TestnetCowSettlement(f.settlement).fill(f.order, f.uid, 1, 1);
    }

    function testMerklCumulativeClaimsReplayOnlyTheIncrementAndRejectOldOrForgedRoots() public {
        address token = _token(6);
        address distributor = address(new TestnetMerklDistributor(address(this)));
        address recipient = makeAddr("merkl recipient");
        TestnetToken(token).mint(distributor, 15e6);
        TestnetMerklDistributor(distributor).setRoot(keccak256(abi.encode(recipient, token, uint256(10e6))));
        _claim(distributor, recipient, token, 10e6);
        _claim(distributor, recipient, token, 10e6);
        assertEq(IERC20(token).balanceOf(recipient), 10e6);
        TestnetMerklDistributor(distributor).setRoot(keccak256(abi.encode(recipient, token, uint256(15e6))));
        _claim(distributor, recipient, token, 15e6);
        assertEq(IERC20(token).balanceOf(recipient), 15e6);
        assertEq(TestnetMerklDistributor(distributor).claimed(recipient, token), 15e6);
        assertEq(IERC20(token).balanceOf(distributor), 0);
        vm.expectRevert(TestnetMerklDistributor.InvalidClaim.selector);
        _claim(distributor, address(this), token, 15e6);
        TestnetMerklDistributor(distributor).setRoot(keccak256(abi.encode(recipient, token, uint256(10e6))));
        vm.expectRevert(TestnetMerklDistributor.InvalidClaim.selector);
        _claim(distributor, recipient, token, 10e6);
        address stranger = makeAddr("merkl root stranger");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        TestnetMerklDistributor(distributor).setRoot(bytes32(0));
    }

    function testMerklUnfundedClaimRollsBackCumulativeStateAndArrayMismatchFails() public {
        address token = _token(6);
        address distributor = address(new TestnetMerklDistributor(address(this)));
        address recipient = makeAddr("unfunded reward user");
        TestnetMerklDistributor(distributor).setRoot(keccak256(abi.encode(recipient, token, uint256(10e6))));
        vm.expectRevert();
        _claim(distributor, recipient, token, 10e6);
        assertEq(TestnetMerklDistributor(distributor).claimed(recipient, token), 0);
        vm.expectRevert(TestnetMerklDistributor.InvalidClaim.selector);
        TestnetMerklDistributor(distributor)
            .claim(new address[](1), new address[](0), new uint256[](1), new bytes32[][](1));
        TestnetToken(token).mint(distributor, 10e6);
        _claim(distributor, recipient, token, 10e6);
        assertEq(IERC20(token).balanceOf(recipient), 10e6);
    }

    function testMerklNativePaddedLeafAndClaimAuthorization() public {
        address token = _token(6);
        address distributor = address(new TestnetMerklDistributor(address(this)));
        address recipient = makeAddr("native merkl user");
        TestnetToken(token).mint(distributor, 10e6);
        TestnetMerklDistributor(distributor).setRoot(keccak256(abi.encodePacked(recipient, token, uint256(10e6))));
        vm.expectRevert(TestnetMerklDistributor.InvalidClaim.selector);
        _claim(distributor, recipient, token, 10e6);
        TestnetMerklDistributor(distributor).setRoot(keccak256(abi.encode(recipient, token, uint256(10e6))));
        vm.expectRevert(TestnetMerklDistributor.InvalidClaim.selector);
        vm.prank(makeAddr("unauthorized merkl caller"));
        _claim(distributor, recipient, token, 10e6);
        vm.prank(recipient);
        _claim(distributor, recipient, token, 10e6);
        assertEq(IERC20(token).balanceOf(recipient), 10e6);
    }

    function _cow() internal returns (CowFixture memory f) {
        f.sell = _token(18);
        f.buy = _token(6);
        f.settlement = address(new TestnetCowSettlement());
        f.owner = makeAddr("order owner");
        f.solver = makeAddr("funded solver");
        f.receiver = makeAddr("signed order receiver");
        f.order = GPv2Order.Data({
            sellToken: IERC20(f.sell),
            buyToken: IERC20(f.buy),
            receiver: f.receiver,
            sellAmount: 100e18,
            buyAmount: 200e6,
            validTo: uint32(vm.getBlockTimestamp() + 1 days),
            appData: keccak256("core model order"),
            feeAmount: 3e18,
            kind: keccak256("sell"),
            partiallyFillable: true,
            sellTokenBalance: keccak256("erc20"),
            buyTokenBalance: keccak256("erc20")
        });
        f.uid = _uid(f);
        TestnetToken(f.sell).mint(f.owner, 103e18);
        TestnetToken(f.buy).mint(f.solver, 200e6 + 2);
        address relayer = TestnetCowSettlement(f.settlement).vaultRelayer();
        vm.prank(f.owner);
        IERC20(f.sell).approve(relayer, type(uint256).max);
        vm.prank(f.owner);
        TestnetCowSettlement(f.settlement).setPreSignature(f.uid, true);
        vm.prank(f.solver);
        IERC20(f.buy).approve(f.settlement, type(uint256).max);
    }

    function _uid(CowFixture memory f) internal view returns (bytes memory) {
        return abi.encodePacked(
            _digest(f.order, TestnetCowSettlement(f.settlement).domainSeparator()), f.owner, f.order.validTo
        );
    }

    function _digest(GPv2Order.Data memory order, bytes32 domain) internal pure returns (bytes32) {
        // Independent Solidity encoding validates the production library's assembly digest at the consuming boundary.
        bytes32 typeHash = keccak256(
            "Order(address sellToken,address buyToken,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,string kind,bool partiallyFillable,string sellTokenBalance,string buyTokenBalance)"
        );
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                domain,
                keccak256(
                    abi.encode(
                        typeHash,
                        order.sellToken,
                        order.buyToken,
                        order.receiver,
                        order.sellAmount,
                        order.buyAmount,
                        order.validTo,
                        order.appData,
                        order.feeAmount,
                        order.kind,
                        order.partiallyFillable,
                        order.sellTokenBalance,
                        order.buyTokenBalance
                    )
                )
            )
        );
    }

    function _claim(address distributor, address recipient, address token, uint256 cumulative) internal {
        address[] memory users = new address[](1);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        users[0] = recipient;
        tokens[0] = token;
        amounts[0] = cumulative;
        proofs[0] = new bytes32[](0);
        TestnetMerklDistributor(distributor).claim(users, tokens, amounts, proofs);
    }
}

/// @title CoreAsyncHandler
/// @notice Drives two independent controllers through funded native requests and partial claims.
contract CoreAsyncHandler is Test {
    address public immutable asset;
    address public immutable vault;
    address public immutable alice;
    address public immutable bob;
    uint256 public paid;

    constructor() {
        asset = address(new TestnetToken("Invariant asset", "INV", 6, address(this)));
        address feed = address(new TestnetPriceFeed(address(this), "Invariant NAV", 18, type(uint48).max, 1e18));
        vault = address(new TestnetAsyncVault(address(this), asset, feed, 0, "Invariant shares", "INVS"));
        alice = address(0x1001);
        bob = address(0x1002);
        TestnetToken(asset).mint(address(this), 300e6);
        IERC20(asset).approve(vault, 300e6);
        TestnetAsyncVault(vault).mint(alice, 100e18);
        TestnetAsyncVault(vault).mint(bob, 200e18);
    }

    function request(uint256 actor, uint128 rawShares) public {
        address controller = actor % 2 == 0 ? alice : bob;
        uint256 held = IERC20(vault).balanceOf(controller);
        if (
            held == 0 || TestnetAsyncVault(vault).pending(controller) > 0
                || TestnetAsyncVault(vault).claimable(controller) > 0
        ) return;
        vm.prank(controller);
        TestnetAsyncVault(vault).requestRedeem(bound(uint256(rawShares), 1, held), controller, controller);
    }

    function fulfill(uint256 actor) public {
        address controller = actor % 2 == 0 ? alice : bob;
        if (TestnetAsyncVault(vault).pending(controller) == 0) return;
        TestnetAsyncVault(vault).fulfill(controller);
    }

    function claim(uint256 actor, uint128 rawShares) public {
        address controller = actor % 2 == 0 ? alice : bob;
        uint256 available = TestnetAsyncVault(vault).claimable(controller);
        if (available == 0) return;
        vm.prank(controller);
        paid += TestnetAsyncVault(vault).redeem(bound(uint256(rawShares), 1, available), controller, controller);
    }
}

/// @title CoreAsyncInvariantTest
/// @notice Checks funding conservation and segregated claims across arbitrary request/fulfill/claim sequences.
contract CoreAsyncInvariantTest is StdInvariant, Test {
    address internal _handler;

    function setUp() public {
        vm.warp(1_790_000_000);
        _handler = address(new CoreAsyncHandler());
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = CoreAsyncHandler.request.selector;
        selectors[1] = CoreAsyncHandler.fulfill.selector;
        selectors[2] = CoreAsyncHandler.claim.selector;
        targetSelector(FuzzSelector({addr: _handler, selectors: selectors}));
        targetContract(_handler);
    }

    function invariantFundedCashAndReservedClaimsRemainConserved() public view {
        address vault = CoreAsyncHandler(_handler).vault();
        address asset = CoreAsyncHandler(_handler).asset();
        address alice = CoreAsyncHandler(_handler).alice();
        address bob = CoreAsyncHandler(_handler).bob();
        assertEq(IERC20(asset).balanceOf(vault) + CoreAsyncHandler(_handler).paid(), 300e6);
        assertEq(
            TestnetAsyncVault(vault).reservedAssets(),
            TestnetAsyncVault(vault).claimableAssets(alice) + TestnetAsyncVault(vault).claimableAssets(bob)
        );
        assertLe(TestnetAsyncVault(vault).reservedAssets(), IERC20(asset).balanceOf(vault));
        assertEq(
            IERC20(vault).balanceOf(vault),
            TestnetAsyncVault(vault).pending(alice) + TestnetAsyncVault(vault).pending(bob)
                + TestnetAsyncVault(vault).claimable(alice) + TestnetAsyncVault(vault).claimable(bob)
        );
        assertEq(
            IERC20(vault).totalSupply(),
            IERC20(vault).balanceOf(alice) + IERC20(vault).balanceOf(bob) + IERC20(vault).balanceOf(vault)
        );
    }
}
