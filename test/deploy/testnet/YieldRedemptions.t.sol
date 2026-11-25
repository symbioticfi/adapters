// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {FigureAccount} from "../../../src/contracts/ll-adapter/FigureAccount.sol";
import {
    ITestnetYieldVault,
    TestnetFigureYieldVault,
    TestnetParetoCDO,
    TestnetParetoQueue,
    TestnetYieldDeploymentScript,
    TestnetYieldVault
} from "../../../script/deploy/testnet/protocols/TestnetYieldRedemptions.sol";
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

    function testDeploymentPreservesSourceCooldownsAndOracleBounds() public {
        uint8[3] memory profiles = [uint8(0), 1, 10];
        for (uint256 i; i < profiles.length; ++i) {
            uint8 profile = profiles[i];
            (, address oracle,, address account) = _deploy(profile, _DEPOSIT);
            if (profile < 2) assertEq(ICooldownAccount(account).COOLDOWN(), profile == 0 ? 18 hours : 1 days);
            assertEq(Oracle(oracle).MIN_PRICE(), 0.5e18);
            assertEq(Oracle(oracle).MAX_PRICE(), 2.5e18);
        }
    }

    function testEveryNativeYieldProfileFundedRequestSettlementAndReplayProtection() public {
        uint8[3] memory profiles = [uint8(0), 1, 10];
        for (uint256 i; i < profiles.length; ++i) {
            uint8 profile = profiles[i];
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
        (address token,,, address account) = _deploy(10, _DEPOSIT);
        vm.prank(account);
        vm.expectRevert();
        IERC4626(token).withdraw(1e6, account, account);
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
        } else {
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
