// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ExecutorLiquidityLens} from "src/contracts/merkle-adapter/automations/ExecutorLiquidityLens.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {MarketParams, Market} from "morpho-blue/src/interfaces/IMorpho.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract ExecutorLiquidityLensTest is Test {
    using Math for uint256;

    ExecutorLiquidityLens internal lens;
    address internal constant POOL = address(0x100);
    address internal constant ASSET = address(0x200);
    address internal constant ACCOUNT = address(0x300);
    address internal constant ATOKEN = address(0x400);
    address internal constant ORACLE = address(0x600);
    address internal constant MORPHO = address(0x700);
    address internal constant VAULT = address(0x800);

    function setUp() public {
        lens = ExecutorLiquidityLens(new ImmutableFactory(type(ExecutorLiquidityLens).creationCode).create(""));
    }

    /// forge-config: default.isolate = true
    function test_AaveWithdrawProtectsDebtAndPoolLiquidity() public {
        _aave(1e8, 6, 1000e6, 1000e6, 1000e8, 400e8);
        _mock(POOL, abi.encodeWithSignature("getUserConfiguration(address)", ACCOUNT), abi.encode(2));
        uint256 amount = lens.aaveWithdraw(POOL, ASSET, ACCOUNT);
        vm.snapshotGasLastCall("ExecutorLiquidityLens", "aaveWithdraw");
        assertGt(amount, 499e6);
        assertLt(amount, 500e6);
        assertGe((1000e8 - amount.mulDiv(1e8, 1e6)).mulDiv(8000, 10_000), 400e8);
        _mock(POOL, abi.encodeWithSignature("getVirtualUnderlyingBalance(address)", ASSET), abi.encode(uint128(100e6)));
        assertEq(lens.aaveWithdraw(POOL, ASSET, ACCOUNT), 100e6);
    }

    /// forge-config: default.isolate = true
    function test_AaveWithdrawRejectsInsolventNonCollateralExit() public {
        _aave(1e8, 6, 1000e6, 1000e6, 450e8, 400e8);
        _mock(
            POOL,
            abi.encodeWithSignature("getUserAccountData(address)", ACCOUNT),
            abi.encode(450e8, 400e8, 0, 8000, 7000, 0.9e18)
        );
        uint256 amount = lens.aaveWithdraw(POOL, ASSET, ACCOUNT);
        vm.snapshotGasLastCall("ExecutorLiquidityLens", "aaveWithdraw_insolvent");
        assertEq(amount, 0);
        _mock(
            POOL,
            abi.encodeWithSignature("getUserAccountData(address)", ACCOUNT),
            abi.encode(600e8, 400e8, 0, 8000, 7000, 1.2e18)
        );
        amount = lens.aaveWithdraw(POOL, ASSET, ACCOUNT);
        vm.snapshotGasLastCall("ExecutorLiquidityLens", "aaveWithdraw_nonCollateral");
        assertEq(amount, 1000e6);
    }

    function testFuzz_AaveWithdrawPreservesSolvency(uint64 debtSeed) public {
        uint256 debt = bound(debtSeed, 1, 800e8);
        _aave(1e8, 6, 1000e6, 1000e6, 1000e8, debt);
        _mock(POOL, abi.encodeWithSignature("getUserConfiguration(address)", ACCOUNT), abi.encode(2));
        uint256 amount = lens.aaveWithdraw(POOL, ASSET, ACCOUNT);
        assertGe((1000e8 - amount.mulDiv(1e8, 1e6)).mulDiv(8000, 10_000), debt);
    }

    function test_AaveUnsupportedModePausedAndInactiveReturnZero() public {
        _aave(1e8, 6, 10_000e6, 10_000e6, 1000e8, 0);
        _mock(POOL, abi.encodeWithSignature("getUserEMode(address)", ACCOUNT), abi.encode(1));
        assertEq(lens.aaveWithdraw(POOL, ASSET, ACCOUNT), 0);
        _mock(POOL, abi.encodeWithSignature("getUserEMode(address)", ACCOUNT), abi.encode(0));
        uint256 configuration = _aaveConfiguration(6) | (uint256(1) << 60);
        _mock(POOL, abi.encodeWithSignature("getConfiguration(address)", ASSET), abi.encode(configuration));
        assertEq(lens.aaveWithdraw(POOL, ASSET, ACCOUNT), 0);
        configuration = _aaveConfiguration(6) & ~(uint256(1) << 56);
        _mock(POOL, abi.encodeWithSignature("getConfiguration(address)", ASSET), abi.encode(configuration));
        assertEq(lens.aaveWithdraw(POOL, ASSET, ACCOUNT), 0);
    }

    function testFuzz_MorphoVaultAccrualIncludesFeeShareDilution(uint32 elapsedSeed, uint64 rateSeed, uint64 feeSeed)
        public
    {
        uint256 elapsed = bound(elapsedSeed, 0, 365 days);
        uint256 rate = bound(rateSeed, 0, 1e11);
        uint256 fee = bound(feeSeed, 0, 0.25e18);
        vm.warp(365 days + 1);
        address exit = address(0x900);
        address irm = address(0x901);
        MarketParams memory params =
            MarketParams({loanToken: ASSET, collateralToken: address(2), oracle: ORACLE, irm: irm, lltv: 8e17});
        bytes32 id = keccak256(abi.encode(params));
        Market memory market = Market({
            totalSupplyAssets: 1_000_000e6,
            totalSupplyShares: 1_000_000e12,
            totalBorrowAssets: 500_000e6,
            totalBorrowShares: 500_000e12,
            lastUpdate: uint128(block.timestamp - elapsed),
            fee: uint128(fee)
        });
        _vault(type(uint128).max, 0, exit);
        _mock(VAULT, abi.encodeWithSignature("liquidityData()"), abi.encode(abi.encode(params)));
        _mock(exit, abi.encodeWithSignature("morpho()"), abi.encode(MORPHO));
        _mock(exit, abi.encodeWithSignature("supplyShares(bytes32)", id), abi.encode(10_000e12));
        _mock(MORPHO, abi.encodeWithSignature("market(bytes32)", id), abi.encode(market));
        _mock(
            irm,
            abi.encodeWithSignature(
                "borrowRateView((address,address,address,address,uint256),(uint128,uint128,uint128,uint128,uint128,uint128))",
                params,
                market
            ),
            abi.encode(rate)
        );
        _mock(ASSET, abi.encodeWithSignature("balanceOf(address)", MORPHO), abi.encode(500_000e6));

        // Independent arithmetic for the previous implementation, including fee share dilution.
        uint256 first = rate * elapsed;
        uint256 second = first.mulDiv(first, 2e18);
        uint256 interest = uint256(500_000e6).mulDiv(first + second + second.mulDiv(first, 3e18), 1e18);
        uint256 feeAssets = interest.mulDiv(fee, 1e18);
        uint256 feeShares = feeAssets.mulDiv(1_000_000e12 + 1e6, 1_000_000e6 + interest - feeAssets + 1);
        uint256 expected = uint256(10_000e12).mulDiv(1_000_000e6 + interest + 1, 1_000_000e12 + feeShares + 1e6);
        assertEq(lens.morphoVaultWithdraw(VAULT, ACCOUNT), Math.min(expected, 500_000e6));
    }

    /// forge-config: default.isolate = true
    function test_MorphoV2UsesIdleAndExactExitMarketNotWholeAdapterAssets() public {
        address liquidityAdapter = address(0x900);
        MarketParams memory params =
            MarketParams({loanToken: ASSET, collateralToken: address(2), oracle: ORACLE, irm: address(0), lltv: 8e17});
        bytes32 id = keccak256(abi.encode(params));
        _vault(100e6, 10e6, liquidityAdapter);
        _mock(VAULT, abi.encodeWithSignature("liquidityData()"), abi.encode(abi.encode(params)));
        _mock(liquidityAdapter, abi.encodeWithSignature("morpho()"), abi.encode(MORPHO));
        _mock(liquidityAdapter, abi.encodeWithSignature("supplyShares(bytes32)", id), abi.encode(50e12));
        _mock(
            MORPHO,
            abi.encodeWithSignature("market(bytes32)", id),
            abi.encode(
                Market({
                    totalSupplyAssets: 100e6,
                    totalSupplyShares: 100e12,
                    totalBorrowAssets: 80e6,
                    totalBorrowShares: 80e12,
                    lastUpdate: uint128(block.timestamp),
                    fee: 0
                })
            )
        );
        _mock(ASSET, abi.encodeWithSignature("balanceOf(address)", MORPHO), abi.encode(500e6));
        uint256 amount = lens.morphoVaultWithdraw(VAULT, ACCOUNT);
        vm.snapshotGasLastCall("ExecutorLiquidityLens", "morphoVaultWithdraw");
        assertEq(amount, 30e6);
        _mock(VAULT, abi.encodeWithSignature("canReceiveAssets(address)", ACCOUNT), abi.encode(false));
        assertEq(lens.morphoVaultWithdraw(VAULT, ACCOUNT), 0);
    }

    function test_MorphoV2ZeroSharesSkipsPreviewAndAdapter() public {
        _vault(100e6, 10e6, address(0x900));
        _mock(VAULT, abi.encodeWithSignature("balanceOf(address)", ACCOUNT), abi.encode(0));
        assertEq(lens.morphoVaultWithdraw(VAULT, ACCOUNT), 0);
    }

    function test_MorphoV2UnknownAdapterOnlyCountsIdle() public {
        address exit = address(0x900);
        _vault(100e6, 10e6, exit);
        _mock(VAULT, abi.encodeWithSignature("liquidityData()"), abi.encode(bytes("")));
        vm.mockCallRevert(exit, abi.encodeWithSignature("morpho()"), "not a market adapter");
        vm.mockCallRevert(exit, abi.encodeWithSignature("morphoVaultV1()"), "not a vault adapter");
        assertEq(lens.morphoVaultWithdraw(VAULT, ACCOUNT), 10e6);
    }

    function test_MorphoV2WrapsNativeV1MaxWithdraw() public {
        address exit = address(0x900);
        address inner = address(0x901);
        _vault(100e6, 10e6, exit);
        _mock(VAULT, abi.encodeWithSignature("liquidityData()"), abi.encode(bytes("")));
        vm.mockCallRevert(exit, abi.encodeWithSignature("morpho()"), "not a market adapter");
        _mock(exit, abi.encodeWithSignature("morphoVaultV1()"), abi.encode(inner));
        vm.mockCallRevert(inner, abi.encodeWithSignature("liquidityAdapter()"), "not V2");
        _mock(inner, abi.encodeWithSignature("maxWithdraw(address)", exit), abi.encode(30e6));
        assertEq(lens.morphoVaultWithdraw(VAULT, ACCOUNT), 40e6);
    }

    function test_MorphoV2NestedVaultEnforcesExitGates() public {
        address exit = address(0x900);
        address inner = address(0x901);
        _vault(100e6, 10e6, exit);
        _mock(VAULT, abi.encodeWithSignature("liquidityData()"), abi.encode(bytes("")));
        vm.mockCallRevert(exit, abi.encodeWithSignature("morpho()"), "not a market adapter");
        _mock(exit, abi.encodeWithSignature("morphoVaultV1()"), abi.encode(inner));
        _mock(inner, abi.encodeWithSignature("liquidityAdapter()"), abi.encode(address(0)));
        _mock(inner, abi.encodeWithSignature("canSendShares(address)", exit), abi.encode(true));
        _mock(inner, abi.encodeWithSignature("canReceiveAssets(address)", exit), abi.encode(true));
        _mock(inner, abi.encodeWithSignature("balanceOf(address)", exit), abi.encode(30e6));
        _mock(inner, abi.encodeWithSignature("previewRedeem(uint256)", 30e6), abi.encode(30e6));
        _mock(inner, abi.encodeWithSignature("asset()"), abi.encode(ASSET));
        _mock(ASSET, abi.encodeWithSignature("balanceOf(address)", inner), abi.encode(40e6));
        assertEq(lens.morphoVaultWithdraw(VAULT, ACCOUNT), 40e6);
        _mock(inner, abi.encodeWithSignature("canReceiveAssets(address)", exit), abi.encode(false));
        assertEq(lens.morphoVaultWithdraw(VAULT, ACCOUNT), 10e6);
    }

    function test_MissingProtocolReadReverts() public view {
        (bool ok, bytes memory response) =
            address(lens).staticcall(abi.encodeWithSignature("morphoVaultWithdraw(address,address)", VAULT, ACCOUNT));
        // Missing protocol reads fail closed instead of returning a fabricated scalar capacity.
        assertFalse(ok);
        assertEq(response.length, 0);
    }

    function test_AaveExpensiveLowDecimalCollateralReservesNativeRounding() public {
        _aave(60_000e8, 8, 1e8, 1e8, 60_000e8, 24_000e8);
        _mock(POOL, abi.encodeWithSignature("getUserConfiguration(address)", ACCOUNT), abi.encode(2));
        uint256 amount = lens.aaveWithdraw(POOL, ASSET, ACCOUNT);
        assertLt(amount, 5e7);
        uint256 remainingCollateralBase = 60_000e8 - (amount + 4).mulDiv(60_000e8, 1e8);
        assertGe(remainingCollateralBase.mulDiv(8000, 10_000), 24_000e8);
    }

    function _aave(uint256 price, uint256 decimals, uint256 owned, uint256 cash, uint256 collateral, uint256 debt)
        internal
    {
        _mock(POOL, abi.encodeWithSignature("getUserEMode(address)", ACCOUNT), abi.encode(0));
        _mock(
            POOL, abi.encodeWithSignature("getConfiguration(address)", ASSET), abi.encode(_aaveConfiguration(decimals))
        );
        _mock(POOL, abi.encodeWithSignature("getUserConfiguration(address)", ACCOUNT), abi.encode(0));
        _mock(POOL, abi.encodeWithSignature("getReserveAddressById(uint16)", uint16(0)), abi.encode(ASSET));
        _mock(POOL, abi.encodeWithSignature("getReserveAToken(address)", ASSET), abi.encode(ATOKEN));
        _mock(POOL, abi.encodeWithSignature("getVirtualUnderlyingBalance(address)", ASSET), abi.encode(uint128(cash)));
        _mock(POOL, abi.encodeWithSignature("getReserveNormalizedIncome(address)", ASSET), abi.encode(12e26));
        _mock(POOL, abi.encodeWithSignature("ADDRESSES_PROVIDER()"), abi.encode(ORACLE));
        _mock(
            POOL,
            abi.encodeWithSignature("getUserAccountData(address)", ACCOUNT),
            abi.encode(collateral, debt, collateral * 7 / 10, 8000, 7000, 8e18)
        );
        _mock(ORACLE, abi.encodeWithSignature("getPriceOracle()"), abi.encode(ORACLE));
        _mock(ORACLE, abi.encodeWithSignature("getAssetPrice(address)", ASSET), abi.encode(price));
        _mock(ASSET, abi.encodeWithSignature("balanceOf(address)", ATOKEN), abi.encode(cash));
        _mock(ATOKEN, abi.encodeWithSignature("balanceOf(address)", ACCOUNT), abi.encode(owned));
    }

    function _aaveConfiguration(uint256 decimals) internal pure returns (uint256) {
        return 7000 | (uint256(8000) << 16) | (decimals << 48) | (uint256(1) << 56) | (uint256(1) << 58);
    }

    function _vault(uint256 owned, uint256 idle, address adapter) internal {
        _mock(VAULT, abi.encodeWithSignature("canSendShares(address)", ACCOUNT), abi.encode(true));
        _mock(VAULT, abi.encodeWithSignature("canReceiveAssets(address)", ACCOUNT), abi.encode(true));
        _mock(VAULT, abi.encodeWithSignature("balanceOf(address)", ACCOUNT), abi.encode(100e18));
        _mock(VAULT, abi.encodeWithSignature("previewRedeem(uint256)", 100e18), abi.encode(owned));
        _mock(VAULT, abi.encodeWithSignature("asset()"), abi.encode(ASSET));
        _mock(VAULT, abi.encodeWithSignature("liquidityAdapter()"), abi.encode(adapter));
        _mock(ASSET, abi.encodeWithSignature("balanceOf(address)", VAULT), abi.encode(idle));
    }

    function _mock(address target, bytes memory data, bytes memory result) internal {
        vm.mockCall(target, data, result);
    }
}
