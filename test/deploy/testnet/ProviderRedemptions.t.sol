// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IAccount} from "src/interfaces/ll-adapter/IAccount.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

import {
    TestnetProviderDeploymentScript,
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
    }

    function setUp() public {
        vm.warp(1_790_000_000);
    }

    function testOpenEdenRequiresCustodyAndFundedSettlement() public {
        Profile memory p = _deploy();
        uint256 expected = IAccount(p.account).totalAssets();
        IAccount(p.account).sync();
        assertEq(IERC20(p.token).balanceOf(p.account), 0);
        assertEq(IERC20(p.asset).balanceOf(p.account), 0);
        assertEq(IAccount(p.account).totalAssets(), expected);
        assertEq(IERC20(p.token).balanceOf(p.endpoint), p.tokenAmount);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        TestnetOpenEdenExpress(p.endpoint).lock(0);
        (,, uint256 payout) = TestnetOpenEdenExpress(p.endpoint).previewRedeem(p.tokenAmount);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert();
        TestnetOpenEdenExpress(p.endpoint).settle(0, payout);
        assertEq(IERC20(p.asset).balanceOf(p.account), 0);
        _fund(p, payout);
        TestnetOpenEdenExpress(p.endpoint).settle(0, payout);
        IAccount(p.account).sync();

        assertEq(IERC20(p.token).totalSupply(), 0);
        assertEq(IERC20(p.asset).balanceOf(p.endpoint), 0);
        assertEq(IERC20(p.asset).balanceOf(p.account), payout);
        assertEq(IAccount(p.account).totalAssets(), payout);
        IERC20(p.asset).transferFrom(p.account, address(this), payout);
        assertEq(IAccount(p.account).totalAssets(), 0);
    }

    function testOpenEdenFinalQueuePriceRemainsLockedAfterFreshPriceChanges() public {
        Profile memory p = _deploy();
        IAccount(p.account).sync();
        assertEq(TestnetOpenEdenExpress(p.endpoint).pendingRedeemInfo(p.account), p.tokenAmount);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        TestnetOpenEdenExpress(p.endpoint).lock(0);
        (,, uint256 expected) = TestnetOpenEdenExpress(p.endpoint).previewRedeem(p.tokenAmount);
        assertEq(TestnetOpenEdenExpress(p.endpoint).getRedeemQueueLength(), 1);
        assertEq(TestnetOpenEdenExpress(p.endpoint).pendingRedeemInfo(p.account), 0);
        assertEq(TestnetOpenEdenExpress(p.endpoint).redeemInfo(p.account), p.tokenAmount);
        TestnetPriceFeed(TestnetOpenEdenExpress(p.endpoint).priceOracle()).publish(2e18);
        assertEq(IAccount(p.account).totalAssets(), expected);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _fund(p, expected);
        TestnetOpenEdenExpress(p.endpoint).settle(0, expected);
        assertEq(TestnetOpenEdenExpress(p.endpoint).getRedeemQueueLength(), 0);
        assertEq(TestnetOpenEdenExpress(p.endpoint).redeemInfo(p.account), 0);
        assertEq(IAccount(p.account).totalAssets(), expected);
    }

    function testOpenEdenSettlementAndShareIssuanceRejectNonOwners() public {
        address stranger = makeAddr("unauthorized issuer");
        Profile memory p = _deploy();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        TestnetToken(p.token).mint(stranger, 1);
        IAccount(p.account).sync();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        TestnetOpenEdenExpress(p.endpoint).lock(0);
    }

    function testOpenEdenOracleRejectsStalePricesAndRecoversAfterPublication() public {
        Profile memory p = _deploy();
        uint256 expected = IAccount(p.account).totalAssets();
        vm.warp(vm.getBlockTimestamp() + 30 hours + 1);
        vm.expectRevert();
        IAccount(p.account).totalAssets();
        (, int256 price,,,) = TestnetPriceFeed(p.feed).latestRoundData();
        TestnetPriceFeed(p.feed).publish(price);
        assertEq(IAccount(p.account).totalAssets(), expected);
    }

    function _deploy() internal returns (Profile memory p) {
        p.asset = address(new TestnetToken("Testnet USDC", "USDC", 6, address(this)));
        address factory = address(new MigratablesFactory(address(this)));
        address cow = address(new TestnetCowSettlement());
        address implementation;
        (p.token, p.oracle, p.endpoint, implementation) =
            new TestnetProviderDeploymentScript(address(this), false).deploy(factory, cow, p.asset);
        p.feed = TestnetOpenEdenExpress(p.endpoint).priceOracle();
        MigratablesFactory(factory).whitelist(implementation);
        address vault = address(new ProviderRedemptionVault(p.asset));
        p.account = MigratablesFactory(factory).create(1, address(this), abi.encode(vault, address(this)));
        p.tokenAmount = 10 * 10 ** IERC20Metadata(p.token).decimals();
        TestnetToken(p.token).mint(p.account, p.tokenAmount);
    }

    function _fund(Profile memory p, uint256 amount) internal {
        TestnetToken(p.asset).mint(address(this), amount);
        IERC20(p.asset).transfer(p.endpoint, amount);
    }
}
