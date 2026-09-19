// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ExecutorLiquidityLens} from "src/contracts/periphery/ExecutorLiquidityLens.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {ILiquidityAavePool} from "src/contracts/periphery/liquidity/AaveLiquidity.sol";
import {MarketParams, Market, Position} from "morpho-blue/src/interfaces/IMorpho.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract LensAskOracle {
    function getQuotes(uint256 amount, address, address) external pure returns (uint256, uint256) {
        return (amount * 2, amount * 3);
    }
}

contract ExecutorLiquidityLensTest is Test {
    using Math for uint256;

    ExecutorLiquidityLens internal lens;
    address internal constant POOL = address(0x100);
    address internal constant ASSET = address(0x200);
    address internal constant ACCOUNT = address(0x300);
    address internal constant ATOKEN = address(0x400);
    address internal constant DEBT = address(0x500);
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
    function test_BorrowCapabilityUsesEachHealthQueryCurrentMinimum() public {
        _aave(1e8, 6, 10_000e6, 10_000e6, 1000e8, 100e8);
        bytes32 first = keccak256("first health query");
        bytes32 second = keccak256("second health query");
        _mock(ACCOUNT, abi.encodeWithSignature("minHealthFactor(bytes32)", first), abi.encode(1.2e18));
        _mock(ACCOUNT, abi.encodeWithSignature("minHealthFactor(bytes32)", second), abi.encode(2e18));
        uint256 beforeCapacity = lens.borrowCapability(ACCOUNT, POOL, ASSET, first);
        vm.snapshotGasLastCall("ExecutorLiquidityLens", "borrowCapability");
        uint256 directCapacity = lens.aaveBorrow(POOL, ASSET, ACCOUNT, 1.2e18);
        vm.snapshotGasLastCall("ExecutorLiquidityLens", "aaveBorrow");
        assertEq(beforeCapacity, directCapacity);
        assertLt(lens.borrowCapability(ACCOUNT, POOL, ASSET, second), beforeCapacity);
        _mock(ACCOUNT, abi.encodeWithSignature("minHealthFactor(bytes32)", first), abi.encode(2e18));
        assertEq(
            lens.borrowCapability(ACCOUNT, POOL, ASSET, first), lens.borrowCapability(ACCOUNT, POOL, ASSET, second)
        );
        _mock(ACCOUNT, abi.encodeWithSignature("minHealthFactor(bytes32)", first), abi.encode(0));
        uint256 disabledCapacity = lens.borrowCapability(ACCOUNT, POOL, ASSET, first);
        vm.snapshotGasLastCall("ExecutorLiquidityLens", "borrowCapability_unsetMinimum");
        assertEq(disabledCapacity, 0);
    }

    /// forge-config: default.isolate = true
    function test_WithdrawCapabilityUsesLiveMinimumAndDisablesUnsetQueries() public {
        _aave(1e8, 6, 1000e6, 1000e6, 1000e8, 400e8);
        _mock(POOL, abi.encodeWithSignature("getUserConfiguration(address)", ACCOUNT), abi.encode(2));
        bytes32 healthFactorId = keccak256("health query");
        _mock(ACCOUNT, abi.encodeWithSignature("minHealthFactor(bytes32)", healthFactorId), abi.encode(1.2e18));
        uint256 beforeCapacity = lens.withdrawCapability(ACCOUNT, POOL, ASSET, healthFactorId);
        vm.snapshotGasLastCall("ExecutorLiquidityLens", "withdrawCapability");
        assertGt(beforeCapacity, 399e6);
        assertLt(beforeCapacity, 400e6);
        _mock(ACCOUNT, abi.encodeWithSignature("minHealthFactor(bytes32)", healthFactorId), abi.encode(1.8e18));
        uint256 afterCapacity = lens.withdrawCapability(ACCOUNT, POOL, ASSET, healthFactorId);
        assertGt(afterCapacity, 99e6);
        assertLt(afterCapacity, 100e6);
        _mock(ACCOUNT, abi.encodeWithSignature("minHealthFactor(bytes32)", healthFactorId), abi.encode(0));
        uint256 disabledCapacity = lens.withdrawCapability(ACCOUNT, POOL, ASSET, healthFactorId);
        vm.snapshotGasLastCall("ExecutorLiquidityLens", "withdrawCapability_unsetMinimum");
        assertEq(disabledCapacity, 0);
    }

    /// forge-config: default.isolate = true
    function test_WithdrawCapabilityRejectsNonCollateralExitBelowMinimum() public {
        _aave(1e8, 6, 1000e6, 1000e6, 550e8, 400e8);
        bytes32 healthFactorId = keccak256("health query");
        _mock(ACCOUNT, abi.encodeWithSignature("minHealthFactor(bytes32)", healthFactorId), abi.encode(1.2e18));
        _mock(
            POOL,
            abi.encodeWithSignature("getUserAccountData(address)", ACCOUNT),
            abi.encode(550e8, 400e8, 0, 8000, 7000, 1.1e18)
        );
        uint256 amount = lens.withdrawCapability(ACCOUNT, POOL, ASSET, healthFactorId);
        vm.snapshotGasLastCall("ExecutorLiquidityLens", "withdrawCapability_belowMinimum");
        assertEq(amount, 0);
        _mock(
            POOL,
            abi.encodeWithSignature("getUserAccountData(address)", ACCOUNT),
            abi.encode(600e8, 400e8, 0, 8000, 7000, 1.2e18)
        );
        amount = lens.withdrawCapability(ACCOUNT, POOL, ASSET, healthFactorId);
        vm.snapshotGasLastCall("ExecutorLiquidityLens", "withdrawCapability_nonCollateral");
        assertEq(amount, 1000e6);
    }

    function testFuzz_WithdrawCapabilityRoundsRequiredDebtUp(uint64 minimumSeed, uint64 debtSeed) public {
        uint256 minimum = bound(minimumSeed, 1e18, 5e18);
        uint256 debt = bound(debtSeed, 1, 100e8);
        _aave(1e8, 6, 1000e6, 1000e6, 1000e8, debt);
        _mock(POOL, abi.encodeWithSignature("getUserConfiguration(address)", ACCOUNT), abi.encode(2));
        bytes32 healthFactorId = keccak256("health query");
        _mock(ACCOUNT, abi.encodeWithSignature("minHealthFactor(bytes32)", healthFactorId), abi.encode(minimum));
        uint256 amount = lens.withdrawCapability(ACCOUNT, POOL, ASSET, healthFactorId);
        assertGe(
            (1000e8 - amount.mulDiv(1e8, 1e6)).mulDiv(8000, 10_000), debt.mulDiv(minimum, 1e18, Math.Rounding.Ceil)
        );
    }

    function testFuzz_AaveBorrowNativeUnitsAndHealthBound(uint64 availableSeed, uint64 minimumSeed) public {
        uint256 available = bound(availableSeed, 1e8, 700e8);
        uint256 minimum = bound(minimumSeed, 1e18, 5e18);
        _aave(2e8, 6, 10_000e6, 10_000e6, 1000e8, 100e8);
        _mock(
            POOL,
            abi.encodeWithSignature("getUserAccountData(address)", ACCOUNT),
            abi.encode(1000e8, 100e8, available, 8000, 7000, 8e18)
        );
        uint256 amount = lens.aaveBorrow(POOL, ASSET, ACCOUNT, minimum);
        assertLe(amount.mulDiv(2e8, 1e6), available);
        assertLe((100e8 + (amount + 4).mulDiv(2e8, 1e6)).mulDiv(minimum, 1e18), 800e8);
    }

    function test_AaveUnsupportedModesPausedAndCapReturnZero() public {
        _aave(1e8, 6, 10_000e6, 10_000e6, 1000e8, 0);
        _mock(POOL, abi.encodeWithSignature("getUserEMode(address)", ACCOUNT), abi.encode(1));
        assertEq(lens.aaveBorrow(POOL, ASSET, ACCOUNT, 1e18), 0);
        assertEq(lens.aaveWithdraw(POOL, ASSET, ACCOUNT), 0);
        _mock(POOL, abi.encodeWithSignature("getUserEMode(address)", ACCOUNT), abi.encode(0));
        uint256 configuration = _aaveConfiguration(6) | (uint256(1) << 60);
        _mock(POOL, abi.encodeWithSignature("getConfiguration(address)", ASSET), abi.encode(configuration));
        assertEq(lens.aaveBorrow(POOL, ASSET, ACCOUNT, 1e18), 0);
        configuration = _aaveConfiguration(6) | (uint256(1000) << 80);
        _mock(POOL, abi.encodeWithSignature("getConfiguration(address)", ASSET), abi.encode(configuration));
        _mock(DEBT, abi.encodeWithSignature("totalSupply()"), abi.encode(1000e6));
        assertEq(lens.aaveBorrow(POOL, ASSET, ACCOUNT, 1e18), 0);
    }

    function testFuzz_MorphoBorrowIncludesRoundedDebtShares(uint128 collateralSeed, uint128 cashSeed) public {
        uint256 collateral = bound(collateralSeed, 1e6, 1000e18);
        uint256 cash = bound(cashSeed, 1, 1_000_000e6);
        MarketParams memory params = MarketParams(ASSET, address(2), ORACLE, address(0), 8e17);
        bytes32 id = keccak256(abi.encode(params));
        Market memory market = Market(uint128(cash + 10e6), 10e12, 10e6, 10e12, uint128(block.timestamp), 0);
        _mock(MORPHO, abi.encodeWithSignature("idToMarketParams(bytes32)", id), abi.encode(params));
        _mock(MORPHO, abi.encodeWithSignature("market(bytes32)", id), abi.encode(market));
        _mock(
            MORPHO,
            abi.encodeWithSignature("position(bytes32,address)", id, ACCOUNT),
            abi.encode(Position(0, 5e12, uint128(collateral)))
        );
        _mock(ORACLE, abi.encodeWithSignature("price()"), abi.encode(2000e24));
        _mock(ASSET, abi.encodeWithSignature("balanceOf(address)", MORPHO), abi.encode(cash));
        uint256 amount = lens.morphoBorrow(MORPHO, id, ACCOUNT);
        assertLe(amount, cash);
        if (amount > 0) {
            uint256 minted = amount.mulDiv(10e12 + 1e6, 10e6 + 1, Math.Rounding.Ceil);
            uint256 finalDebt = (5e12 + minted).mulDiv(10e6 + amount + 1, 10e12 + minted + 1e6, Math.Rounding.Ceil);
            assertLe(finalDebt, collateral.mulDiv(2000e24, 1e36).mulDiv(8e17, 1e18));
        }
    }

    function test_CheckedCapacitiesHonorPositiveMinimumBelowOne() public {
        _aave(1e8, 6, 1000e6, 1000e6, 1000e8, 400e8);
        _mock(POOL, abi.encodeWithSignature("getUserConfiguration(address)", ACCOUNT), abi.encode(2));
        bytes32 healthFactorId = keccak256("health query");
        _mock(ACCOUNT, abi.encodeWithSignature("minHealthFactor(bytes32)", healthFactorId), abi.encode(0.9e18));
        assertEq(
            lens.borrowCapability(ACCOUNT, POOL, ASSET, healthFactorId), lens.aaveBorrow(POOL, ASSET, ACCOUNT, 1e18)
        );
        assertEq(lens.withdrawCapability(ACCOUNT, POOL, ASSET, healthFactorId), lens.aaveWithdraw(POOL, ASSET, ACCOUNT));
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
        MarketParams memory params = MarketParams(ASSET, address(2), ORACLE, irm, 8e17);
        bytes32 id = keccak256(abi.encode(params));
        Market memory market =
            Market(1_000_000e6, 1_000_000e12, 500_000e6, 500_000e12, uint128(block.timestamp - elapsed), uint128(fee));
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
    function test_MorphoBorrowCapabilityTracksCurrentMinimumAndUnsetPolicy() public {
        MarketParams memory params = MarketParams(ASSET, address(2), ORACLE, address(0), 8e17);
        bytes32 id = keccak256(abi.encode(params));
        bytes32 healthFactorId = keccak256("morpho health query");
        _mock(MORPHO, abi.encodeWithSignature("idToMarketParams(bytes32)", id), abi.encode(params));
        _mock(
            MORPHO,
            abi.encodeWithSignature("market(bytes32)", id),
            abi.encode(Market(100_000e6, 100_000e12, 0, 0, uint128(block.timestamp), 0))
        );
        _mock(
            MORPHO, abi.encodeWithSignature("position(bytes32,address)", id, ACCOUNT), abi.encode(Position(0, 0, 10e18))
        );
        _mock(ORACLE, abi.encodeWithSignature("price()"), abi.encode(2000e24));
        _mock(ASSET, abi.encodeWithSignature("balanceOf(address)", MORPHO), abi.encode(100_000e6));
        _mock(ACCOUNT, abi.encodeWithSignature("minHealthFactor(bytes32)", healthFactorId), abi.encode(1.2e18));
        uint256 beforeCapacity = lens.morphoBorrowCapability(ACCOUNT, MORPHO, id, healthFactorId);
        vm.snapshotGasLastCall("ExecutorLiquidityLens", "morphoBorrowCapability");
        assertLe(beforeCapacity, uint256(16_000e6) * 1e18 / 1.2e18);
        _mock(ACCOUNT, abi.encodeWithSignature("minHealthFactor(bytes32)", healthFactorId), abi.encode(2e18));
        assertLt(lens.morphoBorrowCapability(ACCOUNT, MORPHO, id, healthFactorId), beforeCapacity);
        _mock(ACCOUNT, abi.encodeWithSignature("minHealthFactor(bytes32)", healthFactorId), abi.encode(0.9e18));
        uint256 directCapacity = lens.morphoBorrow(MORPHO, id, ACCOUNT);
        vm.snapshotGasLastCall("ExecutorLiquidityLens", "morphoBorrow");
        assertEq(lens.morphoBorrowCapability(ACCOUNT, MORPHO, id, healthFactorId), directCapacity);
        _mock(ACCOUNT, abi.encodeWithSignature("minHealthFactor(bytes32)", healthFactorId), abi.encode(0));
        uint256 disabledCapacity = lens.morphoBorrowCapability(ACCOUNT, MORPHO, id, healthFactorId);
        vm.snapshotGasLastCall("ExecutorLiquidityLens", "morphoBorrowCapability_unsetMinimum");
        assertEq(disabledCapacity, 0);
    }

    /// forge-config: default.isolate = true
    function test_MorphoV2UsesIdleAndExactExitMarketNotWholeAdapterAssets() public {
        address liquidityAdapter = address(0x900);
        MarketParams memory params = MarketParams(ASSET, address(2), ORACLE, address(0), 8e17);
        bytes32 id = keccak256(abi.encode(params));
        _vault(100e6, 10e6, liquidityAdapter);
        _mock(VAULT, abi.encodeWithSignature("liquidityData()"), abi.encode(abi.encode(params)));
        _mock(liquidityAdapter, abi.encodeWithSignature("morpho()"), abi.encode(MORPHO));
        _mock(liquidityAdapter, abi.encodeWithSignature("supplyShares(bytes32)", id), abi.encode(50e12));
        _mock(
            MORPHO,
            abi.encodeWithSignature("market(bytes32)", id),
            abi.encode(Market(100e6, 100e12, 80e6, 80e12, uint128(block.timestamp), 0))
        );
        _mock(ASSET, abi.encodeWithSignature("balanceOf(address)", MORPHO), abi.encode(500e6));
        uint256 amount = lens.morphoVaultWithdraw(VAULT, ACCOUNT);
        vm.snapshotGasLastCall("ExecutorLiquidityLens", "morphoVaultWithdraw");
        assertEq(amount, 30e6);
        _mock(VAULT, abi.encodeWithSignature("canReceiveAssets(address)", ACCOUNT), abi.encode(false));
        assertEq(lens.morphoVaultWithdraw(VAULT, ACCOUNT), 0);
    }

    /// forge-config: default.isolate = true
    function test_EulerRequiresControllerAndChecksAskSideHealthAndCaps() public {
        _euler();
        uint256 amount = lens.eulerBorrow(VAULT, ACCOUNT);
        vm.snapshotGasLastCall("ExecutorLiquidityLens", "eulerBorrow");
        assertEq(amount, 700e6 - 2);
        _mock(VAULT, abi.encodeWithSignature("hookConfig()"), abi.encode(address(0), uint32(1 << 6)));
        assertEq(lens.eulerBorrow(VAULT, ACCOUNT), 0);
        _mock(VAULT, abi.encodeWithSignature("hookConfig()"), abi.encode(address(0), uint32(0)));
        _mock(VAULT, abi.encodeWithSignature("caps()"), abi.encode(uint16(0), uint16((100 << 6) | 8)));
        assertEq(lens.eulerBorrow(VAULT, ACCOUNT), 0);
    }

    function test_MissingProtocolReadReverts() public view {
        (bool ok, bytes memory response) =
            address(lens).staticcall(abi.encodeWithSignature("morphoVaultWithdraw(address,address)", VAULT, ACCOUNT));
        // Missing protocol reads fail closed instead of returning a fabricated scalar capacity.
        assertFalse(ok);
        assertEq(response.length, 0);
    }

    function test_EulerUsesAskRatherThanBidPriceAndReturnsOneWord() public {
        _euler();
        address oracle = address(new LensAskOracle());
        _mock(VAULT, abi.encodeWithSignature("unitOfAccount()"), abi.encode(address(0xbeef)));
        _mock(VAULT, abi.encodeWithSignature("oracle()"), abi.encode(oracle));
        (bool ok, bytes memory response) =
            address(lens).staticcall(abi.encodeWithSignature("eulerBorrow(address,address)", VAULT, ACCOUNT));
        assertTrue(ok);
        assertEq(response.length, 32);
        uint256 amount = abi.decode(response, (uint256));
        assertEq(amount, 166_666_665);
        assertLt((100e6 + amount + 1) * 3, 800e6);
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
        _mock(POOL, abi.encodeWithSignature("getReserveVariableDebtToken(address)", ASSET), abi.encode(DEBT));
        _mock(POOL, abi.encodeWithSignature("getVirtualUnderlyingBalance(address)", ASSET), abi.encode(uint128(cash)));
        _mock(POOL, abi.encodeWithSignature("getReserveNormalizedIncome(address)", ASSET), abi.encode(12e26));
        _mock(POOL, abi.encodeWithSignature("getReserveNormalizedVariableDebt(address)", ASSET), abi.encode(15e26));
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
        _mock(ATOKEN, abi.encodeWithSignature("totalSupply()"), abi.encode(owned));
        _mock(DEBT, abi.encodeWithSignature("totalSupply()"), abi.encode(0));
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

    function _euler() internal {
        address[] memory controllers = new address[](1);
        controllers[0] = VAULT;
        _mock(VAULT, abi.encodeWithSignature("EVC()"), abi.encode(POOL));
        _mock(POOL, abi.encodeWithSignature("getControllers(address)", ACCOUNT), abi.encode(controllers));
        _mock(VAULT, abi.encodeWithSignature("hookConfig()"), abi.encode(address(0), uint32(0)));
        _mock(VAULT, abi.encodeWithSignature("caps()"), abi.encode(uint16(0), uint16(0)));
        _mock(VAULT, abi.encodeWithSignature("totalBorrows()"), abi.encode(100e6));
        _mock(VAULT, abi.encodeWithSignature("cash()"), abi.encode(1000e6));
        _mock(
            VAULT, abi.encodeWithSignature("accountLiquidity(address,bool)", ACCOUNT, false), abi.encode(800e6, 100e6)
        );
        _mock(VAULT, abi.encodeWithSignature("asset()"), abi.encode(ASSET));
        _mock(VAULT, abi.encodeWithSignature("unitOfAccount()"), abi.encode(ASSET));
        _mock(VAULT, abi.encodeWithSignature("oracle()"), abi.encode(ORACLE));
        _mock(VAULT, abi.encodeWithSignature("debtOf(address)", ACCOUNT), abi.encode(100e6));
    }

    function _mock(address target, bytes memory data, bytes memory result) internal {
        vm.mockCall(target, data, result);
    }
}
