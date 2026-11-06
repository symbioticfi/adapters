// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {AsyncRedeemOracle} from "../../../src/contracts/ll-adapter/oracles/AsyncRedeemOracle.sol";
import {AssetoOracle} from "../../../src/contracts/ll-adapter/oracles/AssetoOracle.sol";
import {CompositeOracle} from "../../../src/contracts/ll-adapter/oracles/CompositeOracle.sol";
import {MakinaOracle} from "../../../src/contracts/ll-adapter/oracles/MakinaOracle.sol";
import {NoonRedemptionOracle} from "../../../src/contracts/ll-adapter/oracles/NoonRedemptionOracle.sol";
import {OpenEdenTBILLOracle} from "../../../src/contracts/ll-adapter/oracles/OpenEdenTBILLOracle.sol";
import {SaidOracle} from "../../../src/contracts/ll-adapter/oracles/SaidOracle.sol";

import {ICompositeOracle} from "../../../src/interfaces/ll-adapter/oracles/ICompositeOracle.sol";
import {INoonRedemptionOracle} from "../../../src/interfaces/ll-adapter/oracles/INoonRedemptionOracle.sol";
import {IOracle} from "../../../src/interfaces/ll-adapter/IOracle.sol";

import {Test} from "forge-std/Test.sol";

contract OraclePriceMock {
    uint256 public price;

    constructor(uint256 newPrice) {
        price = newPrice;
    }

    function getPrice() external view returns (uint256) {
        return price;
    }
}

contract OracleConversionMock {
    uint8 public immutable decimals;
    address public immutable asset;
    uint256 public conversion;

    constructor(uint8 newDecimals, address newAsset, uint256 newConversion) {
        decimals = newDecimals;
        asset = newAsset;
        conversion = newConversion;
    }

    function underlying() external view returns (address) {
        return asset;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        require(shares == 10 ** decimals, "whole share required");
        return conversion;
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }
}

contract NoonRedemptionMock {
    address public immutable usnToken;
    address public immutable collateral;
    uint256 public immutable expectedUsn;
    uint256 public immutable result;

    constructor(address newUsnToken, address newCollateral, uint256 newExpectedUsn, uint256 newResult) {
        usnToken = newUsnToken;
        collateral = newCollateral;
        expectedUsn = newExpectedUsn;
        result = newResult;
    }

    function calculateCollateralAmount(address token, uint256 amount) external view returns (uint256) {
        require(token == collateral && amount == expectedUsn, "incorrect redemption quote");
        return result;
    }
}

contract OracleCoverageTest is Test {
    function testSaidUsesLossAdjustedAssets() public {
        address underlying = address(new OracleConversionMock(6, address(0), 0));
        address vault = address(new OracleConversionMock(18, underlying, 2_000_000));
        vm.mockCall(vault, abi.encodeWithSignature("convertToAssetsWithLoss(uint256)", 1e18), abi.encode(1_750_000));
        assertEq(new SaidOracle(1, 2e18, vault).getPrice(), 1.75e18);
    }

    function testAssetoReturnsPublishedPriceAndTimestamp() public {
        address pricer = makeAddr("Asseto pricer");
        vm.mockCall(pricer, abi.encodeWithSignature("getLatestPrice()"), abi.encode(1.12e18));
        vm.mockCall(pricer, abi.encodeWithSignature("latestPriceId()"), abi.encode(7));
        vm.mockCall(pricer, abi.encodeWithSignature("prices(uint256)", 7), abi.encode(1.12e18, 1234));
        (uint256 price, uint48 updatedAt) = new AssetoOracle(1, 2e18, pricer).getPriceData();
        assertEq(price, 1.12e18);
        assertEq(updatedAt, 1234);
    }

    function testMakinaNormalizesPriceAndRejectsStaleOrFutureAccounting() public {
        address source = makeAddr("Makina source");
        address machine = makeAddr("Makina machine");
        vm.warp(1000);
        vm.mockCall(source, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
        vm.mockCall(source, abi.encodeWithSignature("getSharePrice()"), abi.encode(112_345_678));
        vm.mockCall(machine, abi.encodeWithSignature("lastGlobalAccountingTime()"), abi.encode(950));
        MakinaOracle oracle = new MakinaOracle(1, 2e18, source, machine, 100);
        assertEq(oracle.getPrice(), 1_123_456_780_000_000_000);

        vm.mockCall(machine, abi.encodeWithSignature("lastGlobalAccountingTime()"), abi.encode(899));
        vm.expectRevert(IOracle.InvalidPrice.selector);
        oracle.getPrice();

        vm.mockCall(machine, abi.encodeWithSignature("lastGlobalAccountingTime()"), abi.encode(1001));
        vm.expectRevert(IOracle.InvalidPrice.selector);
        oracle.getPrice();
    }

    function testCompositeConvertsBtcPriceToUsdc() public {
        CompositeOracle oracle = new CompositeOracle(
            1,
            type(uint256).max,
            address(new OraclePriceMock(1.05e18)),
            address(new OraclePriceMock(75_000e18)),
            address(new OraclePriceMock(0.99e18))
        );
        assertEq(oracle.getPrice(), uint256(78_750e18) * 1e18 / 0.99e18);
    }

    function testCompositeUsdSourceNeedsOnlyPaymentConversion() public {
        CompositeOracle oracle = new CompositeOracle(
            1, type(uint256).max, address(new OraclePriceMock(1.1e18)), address(0), address(new OraclePriceMock(0.8e18))
        );
        assertEq(oracle.getPrice(), 1.375e18);
    }

    function testCompositeIdentity() public {
        CompositeOracle oracle =
            new CompositeOracle(1, 2e18, address(new OraclePriceMock(1e18)), address(0), address(0));
        assertEq(oracle.getPrice(), 1e18);
    }

    function testCompositeRejectsZeroSourceAddress() public {
        vm.expectRevert(ICompositeOracle.InvalidSource.selector);
        new CompositeOracle(1, 2e18, address(0), address(0), address(0));
    }

    function testCompositeRejectsZeroQuotePrice() public {
        CompositeOracle oracle = new CompositeOracle(
            1, 2e18, address(new OraclePriceMock(1e18)), address(0), address(new OraclePriceMock(0))
        );
        vm.expectRevert(IOracle.InvalidPrice.selector);
        oracle.getPrice();
    }

    function testCompositeRejectsZeroConversion() public {
        CompositeOracle oracle = new CompositeOracle(
            1, 2e18, address(new OraclePriceMock(1e18)), address(new OraclePriceMock(0)), address(0)
        );
        vm.expectRevert(IOracle.InvalidPrice.selector);
        oracle.getPrice();
    }

    function testCompositePropagatesSourceFailure() public {
        address source = makeAddr("source");
        vm.mockCallRevert(source, abi.encodeCall(IOracle.getPrice, ()), "unavailable");
        CompositeOracle oracle = new CompositeOracle(1, 2e18, source, address(0), address(0));
        vm.expectRevert(bytes("unavailable"));
        oracle.getPrice();
    }

    function testCompositeFullPrecisionProduct() public {
        CompositeOracle oracle = new CompositeOracle(
            1, type(uint256).max, address(new OraclePriceMock(1 << 220)), address(new OraclePriceMock(1e18)), address(0)
        );
        assertEq(oracle.getPrice(), 1 << 220);
    }

    function testFuzzCompositeRoundsDown(uint112 source, uint112 conversion, uint112 quote) public {
        vm.assume(source > 0 && conversion > 0);
        uint256 denominator = bound(quote, 1e18, type(uint112).max);
        uint256 expected = (uint256(source) * conversion / 1e18) * 1e18 / denominator;
        vm.assume(expected > 0);
        CompositeOracle oracle = new CompositeOracle(
            1,
            type(uint256).max,
            address(new OraclePriceMock(source)),
            address(new OraclePriceMock(conversion)),
            address(new OraclePriceMock(denominator))
        );
        assertEq(oracle.getPrice(), expected);
    }

    function testTbillSixDecimalUnderlying() public {
        address usdc = address(new OracleConversionMock(6, address(0), 0));
        address token = address(new OracleConversionMock(6, usdc, 1_162_651));
        assertEq(new OpenEdenTBILLOracle(1e18, 2e18, token).getPrice(), 1_162_651e12);
    }

    function testTbillNormalizesDifferentDecimals() public {
        address underlying = address(new OracleConversionMock(18, address(0), 0));
        address token = address(new OracleConversionMock(8, underlying, 1_234_567_890_123_456_789));
        assertEq(new OpenEdenTBILLOracle(1e18, 2e18, token).getPrice(), 1_234_567_890_123_456_789);
    }

    function testTbillRejectsZeroPrice() public {
        address usdc = address(new OracleConversionMock(6, address(0), 0));
        OpenEdenTBILLOracle oracle = new OpenEdenTBILLOracle(1, 2e18, address(new OracleConversionMock(6, usdc, 0)));
        vm.expectRevert(IOracle.InvalidPrice.selector);
        oracle.getPrice();
    }

    function testNoonPricesBothLegsInPaymentToken() public {
        address usdc = address(new OracleConversionMock(6, address(0), 0));
        address usn = makeAddr("USN");
        address shares = address(new OracleConversionMock(18, usn, 1_234_780_455_251_701_504));
        address handler = address(new NoonRedemptionMock(usn, usdc, 1_234_780_455_251_701_504, 1_222_432));
        NoonRedemptionOracle oracle = new NoonRedemptionOracle(1e18, 2e18, shares, handler, usdc);
        assertEq(oracle.getPrice(), 1_222_432e12);
    }

    function testNoonRejectsWrongUnderlying() public {
        address shares = address(new OracleConversionMock(18, makeAddr("other token"), 1e18));
        address handler = address(new NoonRedemptionMock(makeAddr("USN"), address(0), 1e18, 1e6));
        vm.expectRevert(INoonRedemptionOracle.InvalidUnderlying.selector);
        new NoonRedemptionOracle(1, 2e18, shares, handler, address(0));
    }

    function testNoonRejectsZeroRedemptionQuote() public {
        address usdc = address(new OracleConversionMock(6, address(0), 0));
        address usn = makeAddr("USN");
        address shares = address(new OracleConversionMock(18, usn, 1e18));
        address handler = address(new NoonRedemptionMock(usn, usdc, 1e18, 0));
        NoonRedemptionOracle oracle = new NoonRedemptionOracle(1, 2e18, shares, handler, usdc);
        vm.expectRevert(IOracle.InvalidPrice.selector);
        oracle.getPrice();
    }

    function testAsyncRedeemFullPrecisionScaling() public {
        address underlying = address(new OracleConversionMock(18, address(0), 0));
        address vault = address(new OracleConversionMock(18, underlying, 1 << 220));
        AsyncRedeemOracle oracle = new AsyncRedeemOracle(1, type(uint256).max, vault, vault);
        assertEq(oracle.getPrice(), 1 << 220);
    }
}
