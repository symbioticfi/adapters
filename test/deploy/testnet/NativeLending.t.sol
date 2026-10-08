// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {AaveV4Liquidity} from "src/contracts/merkle-adapter/automations/liquidity/AaveV4Liquidity.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";

import {
    IMorpho,
    Id,
    MarketParams,
    Market as BlueMarket,
    Position as BluePosition
} from "morpho-blue/src/interfaces/IMorpho.sol";

import {CALLBACK_SUCCESS} from "morpho-midnight/src/libraries/ConstantsLib.sol";
import {IMidnight, Market, Offer} from "morpho-midnight/src/interfaces/IMidnight.sol";
import {TickLib} from "morpho-midnight/src/libraries/TickLib.sol";

import {
    TestnetAaveV4,
    TestnetCollateralOracle,
    TestnetMidnightLender,
    TestnetNativeLendingScript
} from "script/deploy/testnet/protocols/TestnetNativeLending.sol";
import {TestnetMidnight} from "script/deploy/testnet/protocols/upstream/TestnetMidnight.sol";
import {TestnetMorpho} from "script/deploy/testnet/protocols/upstream/TestnetMorpho.sol";
import {TestnetToken} from "script/deploy/testnet/protocols/TestnetAssets.sol";

/// @title NativeLendingTest
/// @notice Verifies the source-pinned native engines, exact offer ratification, and funded Hub/Spoke reader boundary.
contract NativeLendingTest is Test {
    TestnetNativeLendingScript.Deployment internal _deployed;
    MarketParams internal _blue;
    Market internal _midnight;
    address internal _asset;
    address internal _collateral;
    address internal _borrower;
    address internal _attacker;

    function setUp() public {
        vm.warp(1_800_000_000);
        _borrower = makeAddr("native borrower");
        _attacker = makeAddr("unauthorized taker");
        _asset = address(new TestnetToken("Loan asset", "LOAN", 18, address(this)));
        _collateral = address(new TestnetToken("Collateral", "COLL", 18, address(this)));
        address deployer = address(new TestnetNativeLendingScript(address(this), false));
        _deployed = TestnetNativeLendingScript(deployer).deploy(_asset, _collateral, 1e36);
        _blue = abi.decode(_deployed.blueParams, (MarketParams));
        _midnight = abi.decode(_deployed.midnightParams, (Market));
        TestnetToken(_asset).mint(address(this), 10_000 ether);
        TestnetToken(_collateral).mint(_borrower, 1000 ether);
    }

    function test_DeploymentReturnsExactCanonicalAbiAndCreatesOwnerBoundMarkets() public view {
        assertEq(_deployed.blueId, keccak256(abi.encode(_blue)));
        assertEq(_blue.loanToken, _asset);
        assertEq(_blue.collateralToken, _collateral);
        assertEq(_blue.irm, _deployed.irm);
        assertEq(_blue.oracle, _deployed.oracle);
        assertEq(_blue.lltv, 0.75e18);
        assertEq(TestnetMorpho(_deployed.blue).owner(), address(this));
        assertEq(TestnetMidnight(_deployed.midnight).configurator(), address(this));
        assertEq(TestnetMidnightLender(_deployed.midnightLender).owner(), address(this));
        assertEq(TestnetMidnight(_deployed.midnight).toMarket(_deployed.midnightId).loanToken, _asset);
        assertEq(
            keccak256(abi.encode(TestnetMidnight(_deployed.midnight).toMarket(_deployed.midnightId))),
            keccak256(_deployed.midnightParams)
        );
        assertEq(_midnight.midnight, _deployed.midnight);
        assertEq(_midnight.maturity, block.timestamp + 30 days);
        assertEq(_midnight.collateralParams[0].oracle, _deployed.oracle);
        assertGt(_deployed.aaveV4.code.length, 0);
    }

    function test_DeploymentRuntimeFitsStrictChainLimits() public view {
        assertLe(_deployed.blue.code.length, 24_576);
        assertLe(_deployed.midnight.code.length, 24_576);
        assertLe(_deployed.midnightLender.code.length, 24_576);
        assertLe(_deployed.oracle.code.length, 24_576);
        assertLe(_deployed.irm.code.length, 24_576);
        assertLe(_deployed.aaveV4.code.length, 24_576);
    }

    function test_BlueLoanDenominationHandlesSixDecimalAssetsAgainstEighteenDecimalCollateral() public {
        address asset = address(new TestnetToken("Six decimal loan", "USD", 6, address(this)));
        address deployer = address(new TestnetNativeLendingScript(address(this), false));
        TestnetNativeLendingScript.Deployment memory deployed =
            TestnetNativeLendingScript(deployer).deploy(asset, _collateral, 1e24);
        MarketParams memory blue = abi.decode(deployed.blueParams, (MarketParams));
        TestnetToken(asset).mint(address(this), 1000e6);
        IERC20(asset).approve(deployed.blue, 1000e6);
        TestnetMorpho(deployed.blue).supply(blue, 1000e6, 0, address(this), "");
        vm.startPrank(_borrower);
        IERC20(_collateral).approve(deployed.blue, 200 ether);
        TestnetMorpho(deployed.blue).supplyCollateral(blue, 200 ether, _borrower, "");
        TestnetMorpho(deployed.blue).borrow(blue, 100e6, 0, _borrower, _borrower);
        vm.expectRevert(bytes("insufficient collateral"));
        TestnetMorpho(deployed.blue).borrow(blue, 51e6, 0, _borrower, _borrower);
        vm.stopPrank();
        assertEq(IERC20(asset).balanceOf(_borrower), 100e6);
        assertEq(IERC20(asset).balanceOf(deployed.blue), 900e6);
    }

    function test_BlueRealBorrowAccruesInterestAndRepaysActualTokens() public {
        _blueBorrow(100 ether);
        assertEq(IERC20(_asset).balanceOf(_borrower), 100 ether);
        assertEq(IERC20(_asset).balanceOf(_deployed.blue), 900 ether);
        BlueMarket memory beforeAccrual = IMorpho(_deployed.blue).market(Id.wrap(_deployed.blueId));
        vm.warp(block.timestamp + 30 days);
        TestnetMorpho(_deployed.blue).accrueInterest(_blue);
        BlueMarket memory afterAccrual = IMorpho(_deployed.blue).market(Id.wrap(_deployed.blueId));
        assertGt(afterAccrual.totalBorrowAssets, beforeAccrual.totalBorrowAssets);
        assertGt(afterAccrual.totalSupplyAssets, beforeAccrual.totalSupplyAssets);
        assertEq(afterAccrual.totalBorrowShares, beforeAccrual.totalBorrowShares);

        BluePosition memory position = IMorpho(_deployed.blue).position(Id.wrap(_deployed.blueId), _borrower);
        IERC20(_asset).approve(_deployed.blue, type(uint256).max);
        (uint256 repaid,) = TestnetMorpho(_deployed.blue).repay(_blue, 0, position.borrowShares, _borrower, "");
        assertGt(repaid, 100 ether);
        assertEq(IMorpho(_deployed.blue).position(Id.wrap(_deployed.blueId), _borrower).borrowShares, 0);
        assertEq(IERC20(_asset).balanceOf(_deployed.blue), 900 ether + repaid);
    }

    function test_BlueOracleMoveLiquidatesUnhealthyPositionWithBackedTransfers() public {
        _blueBorrow(100 ether);
        vm.expectRevert(bytes("position is healthy"));
        TestnetMorpho(_deployed.blue).liquidate(_blue, _borrower, 50 ether, 0, "");
        TestnetCollateralOracle(_deployed.oracle).setPrice(0.5e36);
        IERC20(_asset).approve(_deployed.blue, type(uint256).max);
        uint256 cashBefore = IERC20(_asset).balanceOf(_deployed.blue);
        BluePosition memory positionBefore = IMorpho(_deployed.blue).position(Id.wrap(_deployed.blueId), _borrower);
        (uint256 seized, uint256 repaid) = TestnetMorpho(_deployed.blue).liquidate(_blue, _borrower, 50 ether, 0, "");
        assertEq(seized, 50 ether);
        assertGt(repaid, 0);
        assertEq(IERC20(_collateral).balanceOf(address(this)), seized);
        assertEq(IERC20(_asset).balanceOf(_deployed.blue), cashBefore + repaid);
        BluePosition memory positionAfter = IMorpho(_deployed.blue).position(Id.wrap(_deployed.blueId), _borrower);
        assertLt(positionAfter.borrowShares, positionBefore.borrowShares);
        assertEq(positionAfter.collateral, positionBefore.collateral - seized);
    }

    function test_BlueEnforcesCallerCollateralAndLiquidCash() public {
        _blueBorrow(100 ether);
        vm.prank(_attacker);
        vm.expectRevert(bytes("unauthorized"));
        TestnetMorpho(_deployed.blue).borrow(_blue, 1 ether, 0, _borrower, _attacker);
        vm.prank(_borrower);
        vm.expectRevert(bytes("insufficient collateral"));
        TestnetMorpho(_deployed.blue).borrow(_blue, 51 ether, 0, _borrower, _borrower);
        vm.expectRevert(bytes("insufficient liquidity"));
        TestnetMorpho(_deployed.blue).withdraw(_blue, 901 ether, 0, address(this), address(this));
        assertEq(IERC20(_asset).balanceOf(_attacker), 0);
        assertEq(IERC20(_asset).balanceOf(_deployed.blue), 900 ether);
    }

    function test_MidnightFundedLoanRepaysAndLenderWithdrawsRealCash() public {
        Offer memory offer = _fundOffer(200 ether);
        uint256 lenderCashBefore = IERC20(_asset).balanceOf(_deployed.midnightLender);
        vm.prank(_borrower);
        (uint256 paid, uint256 received) =
            TestnetMidnight(_deployed.midnight).take(offer, "", 100 ether, _borrower, _borrower, address(0), "");
        assertGt(received, 98 ether);
        assertEq(paid, received);
        assertEq(IERC20(_asset).balanceOf(_borrower), received);
        assertEq(IERC20(_asset).balanceOf(_deployed.midnightLender), lenderCashBefore - paid);
        assertEq(TestnetMidnight(_deployed.midnight).debt(_deployed.midnightId, _borrower), 100 ether);
        assertEq(TestnetMidnight(_deployed.midnight).credit(_deployed.midnightId, _deployed.midnightLender), 100 ether);
        assertEq(TestnetMidnight(_deployed.midnight).withdrawable(_deployed.midnightId), 0);

        TestnetToken(_asset).mint(_borrower, 100 ether - received);
        vm.startPrank(_borrower);
        IERC20(_asset).approve(_deployed.midnight, 100 ether);
        TestnetMidnight(_deployed.midnight).repay(_midnight, 100 ether, _borrower, address(0), "");
        vm.stopPrank();
        assertEq(TestnetMidnight(_deployed.midnight).debt(_deployed.midnightId, _borrower), 0);
        assertEq(TestnetMidnight(_deployed.midnight).withdrawable(_deployed.midnightId), 100 ether);
        TestnetMidnightLender(_deployed.midnightLender).withdraw(_midnight, 100 ether, _deployed.midnightLender);
        assertEq(IERC20(_asset).balanceOf(_deployed.midnightLender), lenderCashBefore - paid + 100 ether);
        assertEq(TestnetMidnight(_deployed.midnight).credit(_deployed.midnightId, _deployed.midnightLender), 0);
    }

    function test_MidnightRatifierRejectsOfferMutationWrongTakerAndDirectCall() public {
        Offer memory offer = _fundOffer(200 ether);
        vm.prank(_attacker);
        vm.expectRevert();
        TestnetMidnightLender(_deployed.midnightLender).withdrawCash(_asset, 1 ether, _attacker);
        vm.expectRevert(TestnetMidnightLender.InvalidOffer.selector);
        TestnetMidnightLender(_deployed.midnightLender).isRatified(offer, "", _borrower);
        vm.prank(_deployed.midnight);
        assertEq(TestnetMidnightLender(_deployed.midnightLender).isRatified(offer, "", _borrower), CALLBACK_SUCCESS);

        vm.prank(_attacker);
        vm.expectRevert(TestnetMidnightLender.InvalidOffer.selector);
        TestnetMidnight(_deployed.midnight).take(offer, "", 1 ether, _attacker, _attacker, address(0), "");
        offer.maxAssets += 1;
        vm.prank(_borrower);
        vm.expectRevert(TestnetMidnightLender.InvalidOffer.selector);
        TestnetMidnight(_deployed.midnight).take(offer, "", 1 ether, _borrower, _borrower, address(0), "");
        assertEq(IERC20(_asset).balanceOf(_borrower), 0);
        assertEq(TestnetMidnight(_deployed.midnight).debt(_deployed.midnightId, _borrower), 0);
    }

    function test_MidnightOfferConsumptionCapsRepeatedBorrowing() public {
        Offer memory offer = _fundOffer(100 ether);
        vm.startPrank(_borrower);
        TestnetMidnight(_deployed.midnight).take(offer, "", 90 ether, _borrower, _borrower, address(0), "");
        vm.expectRevert(IMidnight.ConsumedAssets.selector);
        TestnetMidnight(_deployed.midnight).take(offer, "", 20 ether, _borrower, _borrower, address(0), "");
        vm.stopPrank();
        assertEq(TestnetMidnight(_deployed.midnight).debt(_deployed.midnightId, _borrower), 90 ether);
        assertLt(TestnetMidnight(_deployed.midnight).consumed(_deployed.midnightLender, offer.group), 100 ether);
    }

    function test_MidnightRejectsUnfundedLoanAndInsufficientCollateralAtomically() public {
        Offer memory offer = _fundOffer(200 ether);
        TestnetMidnightLender(_deployed.midnightLender).withdrawCash(_asset, 200 ether, address(this));
        vm.prank(_borrower);
        vm.expectRevert();
        TestnetMidnight(_deployed.midnight).take(offer, "", 100 ether, _borrower, _borrower, address(0), "");
        assertEq(TestnetMidnight(_deployed.midnight).debt(_deployed.midnightId, _borrower), 0);
        assertEq(TestnetMidnight(_deployed.midnight).consumed(_deployed.midnightLender, offer.group), 0);
        IERC20(_asset).transfer(_deployed.midnightLender, 200 ether);
        vm.prank(_borrower);
        vm.expectRevert(IMidnight.SellerIsLiquidatable.selector);
        TestnetMidnight(_deployed.midnight).take(offer, "", 151 ether, _borrower, _borrower, address(0), "");
        assertEq(IERC20(_asset).balanceOf(_borrower), 0);
    }

    function test_MidnightMaturityBlocksNewDebtButAllowsFullRepayment() public {
        Offer memory offer = _fundOffer(200 ether);
        offer.expiry = _midnight.maturity + 1 days;
        TestnetMidnightLender(_deployed.midnightLender).approveOffer(offer, _borrower);
        vm.prank(_borrower);
        TestnetMidnight(_deployed.midnight).take(offer, "", 100 ether, _borrower, _borrower, address(0), "");
        vm.warp(_midnight.maturity + 1);
        vm.prank(_borrower);
        vm.expectRevert(IMidnight.CannotIncreaseDebtPostMaturity.selector);
        TestnetMidnight(_deployed.midnight).take(offer, "", 1 ether, _borrower, _borrower, address(0), "");
        TestnetToken(_asset).mint(_borrower, 100 ether);
        vm.startPrank(_borrower);
        IERC20(_asset).approve(_deployed.midnight, 100 ether);
        TestnetMidnight(_deployed.midnight).repay(_midnight, 100 ether, _borrower, address(0), "");
        vm.stopPrank();
        assertEq(TestnetMidnight(_deployed.midnight).debt(_deployed.midnightId, _borrower), 0);
        assertEq(IERC20(_asset).balanceOf(_deployed.midnight), 100 ether);
    }

    function test_AaveV4ReaderUsesFundedSharesCashAndDonationRate() public {
        address reader = address(new AaveV4Liquidity());
        IERC20(_asset).approve(_deployed.aaveV4, 200 ether);
        TestnetAaveV4(_deployed.aaveV4).supply(0, 200 ether, address(this));
        assertEq(AaveV4Liquidity(reader).liquidity(_deployed.aaveV4, 0, address(this)), 200 ether);
        assertEq(AaveV4Liquidity(reader).liquidity(_deployed.aaveV4, 0, _attacker), 0);
        IERC20(_asset).transfer(_deployed.aaveV4, 20 ether);
        uint256 cash = IERC20(_asset).balanceOf(_deployed.aaveV4);
        uint256 claim = AaveV4Liquidity(reader).liquidity(_deployed.aaveV4, 0, address(this));
        assertGt(claim, 200 ether);
        assertLe(claim, cash);
        TestnetAaveV4(_deployed.aaveV4).withdraw(0, claim, address(this));
        assertEq(TestnetAaveV4(_deployed.aaveV4).suppliedShares(address(this)), 0);
        assertEq(AaveV4Liquidity(reader).liquidity(_deployed.aaveV4, 0, address(this)), 0);
        assertLe(IERC20(_asset).balanceOf(_deployed.aaveV4), 1);
    }

    function test_AaveV4RejectsUnownedSharesAndUnsupportedReserve() public {
        IERC20(_asset).approve(_deployed.aaveV4, 200 ether);
        TestnetAaveV4(_deployed.aaveV4).supply(0, 200 ether, address(this));
        vm.prank(_attacker);
        vm.expectRevert(TestnetAaveV4.InvalidReserve.selector);
        TestnetAaveV4(_deployed.aaveV4).withdraw(0, 1 ether, _attacker);
        vm.expectRevert(TestnetAaveV4.InvalidReserve.selector);
        TestnetAaveV4(_deployed.aaveV4).getReserve(1);
        assertEq(IERC20(_asset).balanceOf(_deployed.aaveV4), 200 ether);
    }

    function testFuzz_AaveV4CashAndSharesRemainFundedThroughPartialWithdraw(uint128 assets, uint128 withdrawn) public {
        assets = uint128(bound(assets, 1, 1000 ether));
        withdrawn = uint128(bound(withdrawn, 1, assets));
        IERC20(_asset).approve(_deployed.aaveV4, assets);
        TestnetAaveV4(_deployed.aaveV4).supply(0, assets, address(this));
        TestnetAaveV4(_deployed.aaveV4).withdraw(0, withdrawn, address(this));
        assertEq(IERC20(_asset).balanceOf(_deployed.aaveV4), assets - withdrawn);
        assertEq(TestnetAaveV4(_deployed.aaveV4).getUserSuppliedAssets(0, address(this)), assets - withdrawn);
    }

    function _blueBorrow(uint256 amount) internal {
        IERC20(_asset).approve(_deployed.blue, 1000 ether);
        TestnetMorpho(_deployed.blue).supply(_blue, 1000 ether, 0, address(this), "");
        vm.startPrank(_borrower);
        IERC20(_collateral).approve(_deployed.blue, 200 ether);
        TestnetMorpho(_deployed.blue).supplyCollateral(_blue, 200 ether, _borrower, "");
        TestnetMorpho(_deployed.blue).borrow(_blue, amount, 0, _borrower, _borrower);
        vm.stopPrank();
    }

    function _fundOffer(uint128 maxAssets) internal returns (Offer memory offer) {
        IERC20(_asset).transfer(_deployed.midnightLender, maxAssets);
        vm.startPrank(_borrower);
        IERC20(_collateral).approve(_deployed.midnight, 200 ether);
        TestnetMidnight(_deployed.midnight).supplyCollateral(_midnight, 0, 200 ether, _borrower);
        vm.stopPrank();
        offer = Offer({
            market: _midnight,
            buy: true,
            maker: _deployed.midnightLender,
            start: block.timestamp,
            expiry: _midnight.maturity,
            tick: TickLib.priceToTick(0.99e18, TestnetMidnight(_deployed.midnight).tickSpacing(_deployed.midnightId)),
            group: keccak256("funded native loan"),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: _deployed.midnightLender,
            reduceOnly: false,
            maxUnits: 0,
            maxAssets: maxAssets,
            continuousFeeCap: type(uint256).max
        });
        TestnetMidnightLender(_deployed.midnightLender).approveOffer(offer, _borrower);
    }
}
