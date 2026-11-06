// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {AssetoOracle} from "../../../../../src/contracts/merkle-adapter/connectors/oracles/AssetoOracle.sol";
import {ERC4626Oracle} from "../../../../../src/contracts/merkle-adapter/connectors/oracles/ERC4626Oracle.sol";
import {MakinaOracle} from "../../../../../src/contracts/merkle-adapter/connectors/oracles/MakinaOracle.sol";
import {NoonOracle} from "../../../../../src/contracts/merkle-adapter/connectors/oracles/NoonOracle.sol";
import {OpenEdenOracle} from "../../../../../src/contracts/merkle-adapter/connectors/oracles/OpenEdenOracle.sol";
import {
    OpenEdenTBILLOracle
} from "../../../../../src/contracts/merkle-adapter/connectors/oracles/OpenEdenTBILLOracle.sol";
import {SaidOracle} from "../../../../../src/contracts/merkle-adapter/connectors/oracles/SaidOracle.sol";

import {IOpenEdenExpress} from "../../../../../src/interfaces/ll-adapter/openeden/IOpenEdenExpress.sol";
import {IOracle} from "../../../../../src/interfaces/ll-adapter/IOracle.sol";

import {Test} from "forge-std/Test.sol";

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
    address public immutable collateral;
    uint256 public immutable expectedUsn;
    uint256 public immutable result;

    constructor(address newCollateral, uint256 newExpectedUsn, uint256 newResult) {
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
    function testHybondQuotesNetRedemptionProceeds() public {
        address usdc = address(new OracleConversionMock(6, address(0), 0));
        address hybond = address(new OracleConversionMock(18, address(0), 0));
        address express = makeAddr("OpenEden Express");
        vm.mockCall(express, abi.encodeCall(IOpenEdenExpress.redeemAsset, ()), abi.encode(usdc));
        vm.mockCall(
            express, abi.encodeCall(IOpenEdenExpress.previewRedeem, (1e18)), abi.encode(1735, 1_735_797, 1_734_062)
        );
        OpenEdenOracle oracle = new OpenEdenOracle(1, 2e18, hybond, express);
        assertEq(oracle.getPrice(), 1_734_062e12);

        vm.mockCall(
            express, abi.encodeCall(IOpenEdenExpress.previewRedeem, (1e18)), abi.encode(3471, 1_735_797, 1_732_326)
        );
        assertEq(oracle.getPrice(), 1_732_326e12);
    }

    function testHybondRejectsZeroNetProceeds() public {
        address usdc = address(new OracleConversionMock(6, address(0), 0));
        address hybond = address(new OracleConversionMock(18, address(0), 0));
        address express = makeAddr("OpenEden Express");
        vm.mockCall(express, abi.encodeCall(IOpenEdenExpress.redeemAsset, ()), abi.encode(usdc));
        vm.mockCall(
            express, abi.encodeCall(IOpenEdenExpress.previewRedeem, (1e18)), abi.encode(1_735_797, 1_735_797, 0)
        );
        OpenEdenOracle oracle = new OpenEdenOracle(1, 2e18, hybond, express);
        vm.expectRevert(IOracle.InvalidPrice.selector);
        oracle.getPrice();
    }

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

    function testERC4626NormalizesShareAndAssetDecimals() public {
        address underlying = address(new OracleConversionMock(20, address(0), 0));
        address vault = address(new OracleConversionMock(8, underlying, 123_456_789_012_345_678_901));
        assertEq(new ERC4626Oracle(1e18, 2e18, vault).getPrice(), 1_234_567_890_123_456_789);
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
        address handler = address(new NoonRedemptionMock(usdc, 1_234_780_455_251_701_504, 1_222_432));
        NoonOracle oracle = new NoonOracle(1e18, 2e18, shares, handler, usdc);
        assertEq(oracle.getPrice(), 1_222_432e12);
    }

    function testNoonRejectsZeroRedemptionQuote() public {
        address usdc = address(new OracleConversionMock(6, address(0), 0));
        address usn = makeAddr("USN");
        address shares = address(new OracleConversionMock(18, usn, 1e18));
        address handler = address(new NoonRedemptionMock(usdc, 1e18, 0));
        NoonOracle oracle = new NoonOracle(1, 2e18, shares, handler, usdc);
        vm.expectRevert(IOracle.InvalidPrice.selector);
        oracle.getPrice();
    }

    function testQuoteScalingRejectsMultiplicationOverflow() public {
        address underlying = address(new OracleConversionMock(18, address(0), 0));
        address token = address(new OracleConversionMock(18, underlying, 1 << 220));
        ERC4626Oracle vault = new ERC4626Oracle(1, type(uint256).max, token);
        OpenEdenTBILLOracle tbill = new OpenEdenTBILLOracle(1, type(uint256).max, token);
        address handler = address(new NoonRedemptionMock(underlying, 1 << 220, 1 << 220));
        NoonOracle noon = new NoonOracle(1, type(uint256).max, token, handler, underlying);

        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        tbill.getPrice();
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        noon.getPrice();
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        vault.getPrice();
    }
}
