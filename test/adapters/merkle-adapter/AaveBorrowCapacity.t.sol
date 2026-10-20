// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {AaveV3Liquidity} from "src/contracts/merkle-adapter/automations/liquidity/AaveV3Liquidity.sol";

import {IAaveV3Liquidity} from "src/interfaces/merkle-adapter/automations/liquidity/IAaveV3Liquidity.sol";

contract AaveBorrowCapacityTest is Test {
    address constant POOL = address(0x100);
    address constant ASSET = address(0x200);
    address constant ACCOUNT = address(0x300);
    address constant ATOKEN = address(0x400);
    address constant PROVIDER = address(0x500);
    address constant ORACLE = address(0x600);
    address constant DEBT = address(0x700);
    address internal capacity;

    function setUp() public {
        capacity = address(new AaveV3Liquidity());
        _mock(POOL, abi.encodeWithSignature("getUserEMode(address)", ACCOUNT), abi.encode(0));
        _mock(POOL, abi.encodeWithSignature("getConfiguration(address)", ASSET), abi.encode(_configuration()));
        _mock(POOL, abi.encodeWithSignature("getUserConfiguration(address)", ACCOUNT), abi.encode(0));
        _account(1000e8, 100e8, 600e8);
        _mock(POOL, abi.encodeWithSignature("getReserveAToken(address)", ASSET), abi.encode(ATOKEN));
        _mock(ASSET, abi.encodeWithSignature("balanceOf(address)", ATOKEN), abi.encode(1000e6));
        _mock(POOL, abi.encodeWithSignature("getVirtualUnderlyingBalance(address)", ASSET), abi.encode(900e6));
        _mock(POOL, abi.encodeWithSignature("ADDRESSES_PROVIDER()"), abi.encode(PROVIDER));
        _mock(PROVIDER, abi.encodeWithSignature("getPriceOracle()"), abi.encode(ORACLE));
        _mock(ORACLE, abi.encodeWithSignature("getAssetPrice(address)", ASSET), abi.encode(1e8));
        _mock(POOL, abi.encodeWithSignature("getReserveVariableDebtToken(address)", ASSET), abi.encode(DEBT));
        _mock(DEBT, abi.encodeWithSignature("totalSupply()"), abi.encode(0));
    }

    /// forge-config: default.isolate = true
    function test_GasStandardBorrowCapacity() public {
        uint256 amount = IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18);
        vm.snapshotGasLastCall("AaveBorrowCapacity", "standard");
        assertEq(amount, 540e6 - 1);
    }

    /// forge-config: default.isolate = true
    function test_GasEModeBorrowCapacity() public {
        _mock(POOL, abi.encodeWithSignature("getUserEMode(address)", ACCOUNT), abi.encode(1));
        _mock(
            POOL,
            abi.encodeWithSignature("getEModeCategoryBorrowableBitmap(uint8)", uint8(1)),
            abi.encode(uint128(1 << 7))
        );
        _mock(POOL, abi.encodeWithSignature("getReserveAddressById(uint16)", uint16(7)), abi.encode(ASSET));
        uint256 amount = IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18);
        vm.snapshotGasLastCall("AaveBorrowCapacity", "emode");
        assertEq(amount, 540e6 - 1);
    }

    function test_HealthHeadroomUsesGlobalDebtAndConfiguredFloor() public view {
        // 1000 * 80% / 1.25 - 100 = 540, minus one raw debt unit for indexed rounding.
        assertEq(IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18), 540e6 - 1);
    }

    function test_SelectedBorrowPlusOneRespectsHealthFloor() public view {
        uint256 amount = IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18);
        uint256 debtAfter = 100e8 + (amount + 1) * 1e8 / 1e6;
        assertGe(uint256(800e8) * 1e18 / debtAfter, 1.25e18);
    }

    function test_SelectedBorrowPlusOneRespectsNativeLtvHeadroom() public {
        _account(1000e8, 100e8, 123e8);
        uint256 amount = IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18);
        assertLe((amount + 1) * 1e8 / 1e6, 123e8);
    }

    function test_SelectedBorrowPlusOneRespectsReserveBorrowCap() public {
        _mock(
            POOL, abi.encodeWithSignature("getConfiguration(address)", ASSET), abi.encode(_configuration() | (50 << 80))
        );
        _mock(DEBT, abi.encodeWithSignature("totalSupply()"), abi.encode(47e6 + 1));
        uint256 amount = IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18);
        assertLe(47e6 + 1 + amount + 1, 50e6);
    }

    function test_FractionalBaseConversionPreservesHealthWithOneDebtUnitRounding() public {
        uint256 oldDebt = 100e6 + 1;
        uint256 price = 123_456_789;
        _account(1000e8, oldDebt * price / 1e6, 600e8);
        _mock(ORACLE, abi.encodeWithSignature("getAssetPrice(address)", ASSET), abi.encode(price));
        uint256 amount = IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18);
        uint256 debtAfter = (oldDebt + amount + 1) * price / 1e6;
        assertGe(uint256(800e8) * 1e18 / debtAfter, 1.25e18);
    }

    function test_NativeLtvAndCashAlsoCapBorrow() public {
        _account(1000e8, 100e8, 123e8);
        assertEq(IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18), 123e6 - 1);
        _mock(POOL, abi.encodeWithSignature("getVirtualUnderlyingBalance(address)", ASSET), abi.encode(12e6));
        assertEq(IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18), 12e6);
        _mock(ASSET, abi.encodeWithSignature("balanceOf(address)", ATOKEN), abi.encode(7e6));
        assertEq(IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18), 7e6);
    }

    function test_ReserveBorrowCapAndIntegerConversion() public {
        _mock(
            POOL, abi.encodeWithSignature("getConfiguration(address)", ASSET), abi.encode(_configuration() | (50 << 80))
        );
        _mock(DEBT, abi.encodeWithSignature("totalSupply()"), abi.encode(47e6 + 1));
        assertEq(IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18), 3e6 - 2);
        _mock(ORACLE, abi.encodeWithSignature("getAssetPrice(address)", ASSET), abi.encode(3e8));
        _account(1000e8, 100e8, 1e8 + 1);
        assertEq(IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18), 333_332);
    }

    function test_UnsupportedOrUnavailableReturnsZero() public {
        _mock(POOL, abi.encodeWithSignature("getUserEMode(address)", ACCOUNT), abi.encode(1));
        _mock(
            POOL, abi.encodeWithSignature("getEModeCategoryBorrowableBitmap(uint8)", uint8(1)), abi.encode(uint128(0))
        );
        assertEq(IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18), 0);
        _mock(POOL, abi.encodeWithSignature("getUserEMode(address)", ACCOUNT), abi.encode(0));
        _account(100e8, 100e8, 0);
        assertEq(IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18), 0);
    }

    function test_EModeAdmitsOnlyBorrowableCategoryAssets() public {
        _mock(POOL, abi.encodeWithSignature("getUserEMode(address)", ACCOUNT), abi.encode(1));
        _mock(
            POOL,
            abi.encodeWithSignature("getEModeCategoryBorrowableBitmap(uint8)", uint8(1)),
            abi.encode(uint128(1 << 7))
        );
        _mock(POOL, abi.encodeWithSignature("getReserveAddressById(uint16)", uint16(7)), abi.encode(ASSET));
        assertEq(IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18), 540e6 - 1);
        _mock(POOL, abi.encodeWithSignature("getReserveAddressById(uint16)", uint16(7)), abi.encode(address(0x999)));
        assertEq(IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18), 0);
    }

    function test_EModeUsesNativeEffectiveThresholdForZeroBaseLtvCollateral() public {
        _mock(POOL, abi.encodeWithSignature("getUserEMode(address)", ACCOUNT), abi.encode(2));
        _mock(
            POOL,
            abi.encodeWithSignature("getEModeCategoryBorrowableBitmap(uint8)", uint8(2)),
            abi.encode(uint128(1 << 127))
        );
        _mock(POOL, abi.encodeWithSignature("getReserveAddressById(uint16)", uint16(127)), abi.encode(ASSET));
        _mock(POOL, abi.encodeWithSignature("getUserConfiguration(address)", ACCOUNT), abi.encode(2));
        _mock(POOL, abi.encodeWithSignature("getReserveAddressById(uint16)", uint16(0)), abi.encode(address(0x999)));
        _mock(POOL, abi.encodeWithSignature("getConfiguration(address)", address(0x999)), abi.encode(0));
        _mock(
            POOL,
            abi.encodeWithSignature("getUserAccountData(address)", ACCOUNT),
            abi.encode(1000e8, 100e8, 800e8, 9000, 8500, 9e18)
        );
        assertEq(IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18), 620e6 - 1);
    }

    function test_EModeRequiredBitmapFailureReverts() public {
        _mock(POOL, abi.encodeWithSignature("getUserEMode(address)", ACCOUNT), abi.encode(1));
        vm.mockCallRevert(POOL, abi.encodeWithSignature("getEModeCategoryBorrowableBitmap(uint8)", uint8(1)), "");
        vm.expectRevert();
        IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18);
    }

    function test_FailedRequiredReadReverts() public {
        vm.mockCallRevert(ORACLE, abi.encodeWithSignature("getAssetPrice(address)", ASSET), "");
        vm.expectRevert();
        IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18);
    }

    function test_ReserveFlagsAndSiloedBorrowingReturnZero() public {
        uint256[5] memory configurations = [
            _configuration() & ~(uint256(1) << 56),
            _configuration() & ~(uint256(1) << 58),
            _configuration() | (1 << 57),
            _configuration() | (1 << 60),
            _configuration() | (1 << 62)
        ];
        for (uint256 i; i < configurations.length; ++i) {
            _mock(POOL, abi.encodeWithSignature("getConfiguration(address)", ASSET), abi.encode(configurations[i]));
            assertEq(IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18), 0);
        }
    }

    function test_IsolatedCollateralReturnsZero() public {
        _mock(POOL, abi.encodeWithSignature("getUserConfiguration(address)", ACCOUNT), abi.encode(2));
        _mock(POOL, abi.encodeWithSignature("getReserveAddressById(uint16)", 0), abi.encode(ASSET));
        _mock(
            POOL, abi.encodeWithSignature("getConfiguration(address)", ASSET), abi.encode(_configuration() | (1 << 212))
        );
        assertEq(IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18), 0);
    }

    function test_ZeroPriceAndExhaustedBorrowCapReturnZero() public {
        _mock(ORACLE, abi.encodeWithSignature("getAssetPrice(address)", ASSET), abi.encode(0));
        assertEq(IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18), 0);
        _mock(ORACLE, abi.encodeWithSignature("getAssetPrice(address)", ASSET), abi.encode(1e8));
        _mock(
            POOL, abi.encodeWithSignature("getConfiguration(address)", ASSET), abi.encode(_configuration() | (50 << 80))
        );
        _mock(DEBT, abi.encodeWithSignature("totalSupply()"), abi.encode(51e6));
        assertEq(IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18), 0);
    }

    function test_InvalidHealthFloorAndUnsupportedDecimalsRevert() public {
        vm.expectRevert();
        IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1e18 - 1);
        uint256 configuration = (_configuration() & ~(uint256(0xff) << 48)) | (37 << 48);
        _mock(POOL, abi.encodeWithSignature("getConfiguration(address)", ASSET), abi.encode(configuration));
        vm.expectRevert();
        IAaveV3Liquidity(capacity).maxBorrow(POOL, ASSET, ACCOUNT, 1.25e18);
    }

    function _account(uint256 collateral, uint256 debt, uint256 available) internal {
        _mock(
            POOL,
            abi.encodeWithSignature("getUserAccountData(address)", ACCOUNT),
            abi.encode(collateral, debt, available, 8000, 7500, 2e18)
        );
    }

    function _configuration() internal pure returns (uint256) {
        return 7500 | (8000 << 16) | (6 << 48) | (1 << 56) | (1 << 58);
    }

    function _mock(address target, bytes memory data, bytes memory result) internal {
        vm.mockCall(target, data, result);
    }
}
