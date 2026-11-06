// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {AaveV3Liquidity} from "src/contracts/merkle-adapter/automations/liquidity/AaveV3Liquidity.sol";
import {AaveV4Liquidity} from "src/contracts/merkle-adapter/automations/liquidity/AaveV4Liquidity.sol";
import {MorphoLiquidity} from "src/contracts/merkle-adapter/automations/liquidity/MorphoLiquidity.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {OP_SUB} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {MarketParams, Market} from "morpho-blue/src/interfaces/IMorpho.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract LiquiditySourcesTest is Test {
    using ExecutingRecipe for ExecutingRecipe.Builder;
    using Math for uint256;

    AaveV3Liquidity internal aaveV3;
    AaveV4Liquidity internal aaveV4;
    MorphoLiquidity internal morpho;
    address internal constant POOL = address(0x100);
    address internal constant ASSET = address(0x200);
    address internal constant ACCOUNT = address(0x300);
    address internal constant ATOKEN = address(0x400);
    address internal constant ORACLE = address(0x600);
    address internal constant MORPHO = address(0x700);
    address internal constant VAULT = address(0x800);
    address internal constant SPOKE = address(0x900);
    address internal constant HUB = address(0xa00);

    function setUp() public {
        aaveV3 = AaveV3Liquidity(new ImmutableFactory(type(AaveV3Liquidity).creationCode).create(""));
        aaveV4 = AaveV4Liquidity(new ImmutableFactory(type(AaveV4Liquidity).creationCode).create(""));
        morpho = MorphoLiquidity(new ImmutableFactory(type(MorphoLiquidity).creationCode).create(""));
    }

    /// forge-config: default.isolate = true
    function test_AaveZeroNeedSkipsProtocolReads() public {
        assertEq(aaveV3.liquidity(POOL, ASSET, ACCOUNT, 0), 0);
        vm.snapshotGasLastCall("AaveV3Liquidity", "liquidity_zeroNeed");
    }

    /// forge-config: default.isolate = true
    function test_AaveBorrowZeroNeedSkipsProtocolReads() public {
        assertEq(aaveV3.liquidityWithBorrow(POOL, ASSET, ACCOUNT, 0), 0);
        vm.snapshotGasLastCall("AaveV3Liquidity", "liquidityWithBorrow_zeroNeed");
    }

    /// forge-config: default.isolate = true
    function test_AaveV4ZeroNeedSkipsProtocolReads() public {
        assertEq(aaveV4.liquidity(SPOKE, 3, ACCOUNT, 0), 0);
        vm.snapshotGasLastCall("AaveV4Liquidity", "liquidity_zeroNeed");
    }

    /// forge-config: default.isolate = true
    function test_MorphoZeroNeedSkipsProtocolReads() public {
        assertEq(morpho.liquidity(VAULT, ACCOUNT, 0), 0);
        vm.snapshotGasLastCall("MorphoLiquidity", "liquidity_zeroNeed");
    }

    function testFuzz_AaveNeededAmountCapsLiquidity(uint128 balance, uint128 cash, uint256 needed) public {
        _aave(1e8, 6, balance, cash, 1000e8, 0);
        assertEq(aaveV3.liquidity(POOL, ASSET, ACCOUNT, needed), Math.min(needed, Math.min(balance, cash)));
    }

    function testFuzz_AaveBorrowNeededAmountCapsSolventLiquidity(uint256 needed) public {
        _aave(1e8, 6, 1000e6, 1000e6, 1000e8, 400e8);
        _mock(POOL, abi.encodeWithSignature("getUserConfiguration(address)", ACCOUNT), abi.encode(3));
        uint256 capacity = aaveV3.liquidityWithBorrow(POOL, ASSET, ACCOUNT);
        assertEq(aaveV3.liquidityWithBorrow(POOL, ASSET, ACCOUNT, needed), Math.min(needed, capacity));
    }

    function testFuzz_AaveV4NeededAmountCapsLiquidity(uint128 supply, uint128 cash, uint128 added, uint256 needed)
        public
    {
        _aaveV4(supply, cash, added);
        assertEq(aaveV4.liquidity(SPOKE, 3, ACCOUNT, needed), Math.min(needed, Math.min(supply, Math.min(cash, added))));
    }

    function testFuzz_MorphoNeededAmountCapsLiquidity(uint128 owned, uint128 idle, uint256 needed) public {
        _vault(owned, idle, address(0));
        assertEq(morpho.liquidity(VAULT, ACCOUNT, needed), Math.min(needed, Math.min(owned, idle)));
    }

    function test_PositiveNeedPreservesReadFailures() public {
        vm.expectRevert();
        aaveV3.liquidity(POOL, ASSET, ACCOUNT, 1);
        vm.expectRevert();
        aaveV3.liquidityWithBorrow(POOL, ASSET, ACCOUNT, 1);
        vm.expectRevert();
        aaveV4.liquidity(SPOKE, 3, ACCOUNT, 1);
        vm.expectRevert();
        morpho.liquidity(VAULT, ACCOUNT, 1);
    }

    function test_RecipeSkipsUnusedVenueReadsWhenFirstSourceCoversNeed() public {
        _vault(100e6, 100e6, address(0));
        // Aave addresses have neither code nor mocked responses: an external read would revert.
        uint256[] memory values = _fundingResults();
        assertEq(values[0], 100e6);
        assertEq(values[2], 0);
        assertEq(values[4], 0);
    }

    function test_RecipePassesRemainingNeedInCommittedOrder() public {
        _vault(60e6, 60e6, address(0));
        _aave(1e8, 6, 30e6, 30e6, 1000e8, 0);
        _aaveV4(100e6, 100e6, 100e6);
        uint256[] memory values = _fundingResults();
        assertEq(values[0], 60e6);
        assertEq(values[2], 30e6);
        assertEq(values[4], 10e6);
    }

    function testFuzz_AaveWithdrawUsesOnlyAdapterLiquidityReads(uint256 balance, uint128 cash) public {
        _mock(POOL, abi.encodeWithSignature("getReserveAToken(address)", ASSET), abi.encode(ATOKEN));
        _mock(POOL, abi.encodeWithSignature("getVirtualUnderlyingBalance(address)", ASSET), abi.encode(cash));
        _mock(ATOKEN, abi.encodeWithSignature("balanceOf(address)", ACCOUNT), abi.encode(balance));
        // No debt, configuration, oracle or underlying-token reads are available.
        assertEq(aaveV3.liquidity(POOL, ASSET, ACCOUNT), Math.min(balance, cash));
    }

    /// forge-config: default.isolate = true
    function test_AaveWithdrawUsesVirtualLiquidityWithoutHealthChecks() public {
        _aave(1e8, 6, 1000e6, 1000e6, 1000e8, 400e8);
        _mock(POOL, abi.encodeWithSignature("getUserEMode(address)", ACCOUNT), abi.encode(1));
        _mock(ASSET, abi.encodeWithSignature("balanceOf(address)", ATOKEN), abi.encode(0));
        _mock(POOL, abi.encodeWithSignature("getVirtualUnderlyingBalance(address)", ASSET), abi.encode(uint128(100e6)));
        uint256 amount = aaveV3.liquidity(POOL, ASSET, ACCOUNT);
        vm.snapshotGasLastCall("AaveV3Liquidity", "liquidity");
        assertEq(amount, 100e6);
        amount = aaveV3.liquidity(POOL, ASSET, ACCOUNT, 50e6);
        vm.snapshotGasLastCall("AaveV3Liquidity", "liquidity_needed");
        assertEq(amount, 50e6);
    }

    /// forge-config: default.isolate = true
    function test_AaveWithdrawProtectsDebtAndPoolLiquidity() public {
        _aave(1e8, 6, 1000e6, 1000e6, 1000e8, 400e8);
        _mock(POOL, abi.encodeWithSignature("getUserConfiguration(address)", ACCOUNT), abi.encode(3));
        uint256 amount = aaveV3.liquidityWithBorrow(POOL, ASSET, ACCOUNT);
        vm.snapshotGasLastCall("AaveV3Liquidity", "liquidityWithBorrow");
        assertGt(amount, 499e6);
        assertLt(amount, 500e6);
        assertGe((1000e8 - amount.mulDiv(1e8, 1e6)).mulDiv(8000, 10_000), 400e8);
        amount = aaveV3.liquidityWithBorrow(POOL, ASSET, ACCOUNT, 100e6);
        vm.snapshotGasLastCall("AaveV3Liquidity", "liquidityWithBorrow_needed");
        assertEq(amount, 100e6);
        _mock(POOL, abi.encodeWithSignature("getVirtualUnderlyingBalance(address)", ASSET), abi.encode(uint128(100e6)));
        assertEq(aaveV3.liquidityWithBorrow(POOL, ASSET, ACCOUNT), 100e6);
    }

    /// forge-config: default.isolate = true
    function test_AaveWithdrawRejectsInsolventNonCollateralExit() public {
        _aave(1e8, 6, 1000e6, 1000e6, 450e8, 400e8);
        _mock(
            POOL,
            abi.encodeWithSignature("getUserAccountData(address)", ACCOUNT),
            abi.encode(450e8, 400e8, 0, 8000, 7000, 0.9e18)
        );
        uint256 amount = aaveV3.liquidityWithBorrow(POOL, ASSET, ACCOUNT);
        vm.snapshotGasLastCall("AaveV3Liquidity", "liquidityWithBorrow_insolvent");
        assertEq(amount, 0);
        _mock(
            POOL,
            abi.encodeWithSignature("getUserAccountData(address)", ACCOUNT),
            abi.encode(600e8, 400e8, 0, 8000, 7000, 1.2e18)
        );
        amount = aaveV3.liquidityWithBorrow(POOL, ASSET, ACCOUNT);
        vm.snapshotGasLastCall("AaveV3Liquidity", "liquidityWithBorrow_nonCollateral");
        assertEq(amount, 1000e6);
    }

    function testFuzz_AaveWithdrawPreservesSolvency(uint64 debtSeed) public {
        uint256 debt = bound(debtSeed, 1, 800e8);
        _aave(1e8, 6, 1000e6, 1000e6, 1000e8, debt);
        _mock(POOL, abi.encodeWithSignature("getUserConfiguration(address)", ACCOUNT), abi.encode(3));
        uint256 amount = aaveV3.liquidityWithBorrow(POOL, ASSET, ACCOUNT);
        assertGe((1000e8 - amount.mulDiv(1e8, 1e6)).mulDiv(8000, 10_000), debt);
    }

    function test_AaveMixedCollateralPreservesRoundedHealth() public {
        _aave(1e8, 6, 1000e6, 1000e6, 2000e8, 1200e8);
        _mock(POOL, abi.encodeWithSignature("getUserConfiguration(address)", ACCOUNT), abi.encode(11));
        address secondAsset = address(0x201);
        _mock(POOL, abi.encodeWithSignature("getReserveAddressById(uint16)", uint16(1)), abi.encode(secondAsset));
        _mock(
            POOL,
            abi.encodeWithSignature("getConfiguration(address)", secondAsset),
            abi.encode((_aaveConfiguration(6) & ~(uint256(0xffff) << 16)) | (uint256(8500) << 16))
        );
        _mock(
            POOL,
            abi.encodeWithSignature("getUserAccountData(address)", ACCOUNT),
            abi.encode(2000e8, 1200e8, 0, 8250, 7000, 1.375e18)
        );
        uint256 amount = aaveV3.liquidityWithBorrow(POOL, ASSET, ACCOUNT);
        uint256 remaining = 1000e8 - amount.mulDiv(1e8, 1e6);
        uint256 collateral = remaining + 1000e8;
        // Aave V3.3/V3.4 truncate the new aggregate threshold before computing health.
        uint256 threshold = (remaining * 8000 + 1000e8 * 8500) / collateral;
        uint256 weighted = (collateral * threshold + 5000) / 10_000;
        assertGe(weighted, 1200e8);
    }

    function test_AaveUnsupportedModePausedAndInactiveReturnZero() public {
        _aave(1e8, 6, 10_000e6, 10_000e6, 1000e8, 0);
        _mock(POOL, abi.encodeWithSignature("getUserEMode(address)", ACCOUNT), abi.encode(1));
        assertEq(aaveV3.liquidityWithBorrow(POOL, ASSET, ACCOUNT), 0);
        _mock(POOL, abi.encodeWithSignature("getUserEMode(address)", ACCOUNT), abi.encode(0));
        uint256 configuration = _aaveConfiguration(6) | (uint256(1) << 60);
        _mock(POOL, abi.encodeWithSignature("getConfiguration(address)", ASSET), abi.encode(configuration));
        assertEq(aaveV3.liquidityWithBorrow(POOL, ASSET, ACCOUNT), 0);
        configuration = _aaveConfiguration(6) & ~(uint256(1) << 56);
        _mock(POOL, abi.encodeWithSignature("getConfiguration(address)", ASSET), abi.encode(configuration));
        assertEq(aaveV3.liquidityWithBorrow(POOL, ASSET, ACCOUNT), 0);
    }

    /// forge-config: default.isolate = true
    function test_AaveV4WithdrawCapsSupplyHubAndSpokeLiquidity() public {
        _aaveV4(1000e6, 2000e6, 1500e6);
        uint256 amount = aaveV4.liquidity(SPOKE, 3, ACCOUNT);
        vm.snapshotGasLastCall("AaveV4Liquidity", "liquidity");
        assertEq(amount, 1000e6);
        amount = aaveV4.liquidity(SPOKE, 3, ACCOUNT, 500e6);
        vm.snapshotGasLastCall("AaveV4Liquidity", "liquidity_needed");
        assertEq(amount, 500e6);
        _mock(HUB, abi.encodeWithSignature("getAssetLiquidity(uint256)", 7), abi.encode(800e6));
        assertEq(aaveV4.liquidity(SPOKE, 3, ACCOUNT), 800e6);
        _mock(HUB, abi.encodeWithSignature("getSpokeAddedAssets(uint256,address)", 7, SPOKE), abi.encode(600e6));
        assertEq(aaveV4.liquidity(SPOKE, 3, ACCOUNT), 600e6);
        _mock(SPOKE, abi.encodeWithSignature("getUserSuppliedAssets(uint256,address)", 3, ACCOUNT), abi.encode(0));
        assertEq(aaveV4.liquidity(SPOKE, 3, ACCOUNT), 0);
    }

    function testFuzz_AaveV4WithdrawUsesOnlyAccountAndHubLiquidity(uint128 supply, uint128 cash, uint128 added) public {
        _aaveV4(supply, cash, added);
        // Debt, collateral, oracle and ERC-20 balance reads are intentionally unavailable.
        uint256 amount = aaveV4.liquidity(SPOKE, 3, ACCOUNT);
        assertLe(amount, supply);
        assertLe(amount, cash);
        assertLe(amount, added);
        assertTrue(amount == supply || amount == cash || amount == added);
    }

    function test_AaveV4WithdrawBubblesFailedLiquidityRead() public {
        _aaveV4(1000e6, 2000e6, 1500e6);
        vm.mockCallRevert(HUB, abi.encodeWithSignature("getAssetLiquidity(uint256)", 7), hex"12345678");
        vm.expectRevert(bytes4(0x12345678));
        aaveV4.liquidity(SPOKE, 3, ACCOUNT);
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

        // Independent Morpho interest and fee-share dilution calculation.
        uint256 first = rate * elapsed;
        uint256 second = first.mulDiv(first, 2e18);
        uint256 interest = uint256(500_000e6).mulDiv(first + second + second.mulDiv(first, 3e18), 1e18);
        uint256 feeAssets = interest.mulDiv(fee, 1e18);
        uint256 feeShares = feeAssets.mulDiv(1_000_000e12 + 1e6, 1_000_000e6 + interest - feeAssets + 1);
        uint256 expected = uint256(10_000e12).mulDiv(1_000_000e6 + interest + 1, 1_000_000e12 + feeShares + 1e6);
        assertEq(morpho.liquidity(VAULT, ACCOUNT), Math.min(expected, 500_000e6));
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
        uint256 amount = morpho.liquidity(VAULT, ACCOUNT);
        vm.snapshotGasLastCall("MorphoLiquidity", "liquidity");
        assertEq(amount, 30e6);
        amount = morpho.liquidity(VAULT, ACCOUNT, 20e6);
        vm.snapshotGasLastCall("MorphoLiquidity", "liquidity_needed");
        assertEq(amount, 20e6);
        _mock(VAULT, abi.encodeWithSignature("canReceiveAssets(address)", ACCOUNT), abi.encode(false));
        assertEq(morpho.liquidity(VAULT, ACCOUNT), 0);
    }

    function test_MorphoV2ZeroSharesSkipsPreviewAndAdapter() public {
        _vault(100e6, 10e6, address(0x900));
        _mock(VAULT, abi.encodeWithSignature("balanceOf(address)", ACCOUNT), abi.encode(0));
        assertEq(morpho.liquidity(VAULT, ACCOUNT), 0);
    }

    function test_MorphoV2UnknownAdapterOnlyCountsIdle() public {
        address exit = address(0x900);
        _vault(100e6, 10e6, exit);
        _mock(VAULT, abi.encodeWithSignature("liquidityData()"), abi.encode(bytes("")));
        vm.mockCallRevert(exit, abi.encodeWithSignature("morpho()"), "not a market adapter");
        vm.mockCallRevert(exit, abi.encodeWithSignature("morphoVaultV1()"), "not a vault adapter");
        assertEq(morpho.liquidity(VAULT, ACCOUNT), 10e6);
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
        assertEq(morpho.liquidity(VAULT, ACCOUNT), 40e6);
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
        assertEq(morpho.liquidity(VAULT, ACCOUNT), 40e6);
        _mock(inner, abi.encodeWithSignature("canReceiveAssets(address)", exit), abi.encode(false));
        assertEq(morpho.liquidity(VAULT, ACCOUNT), 10e6);
    }

    function test_MissingProtocolReadReverts() public view {
        (bool ok, bytes memory response) =
            address(morpho).staticcall(abi.encodeWithSignature("liquidity(address,address)", VAULT, ACCOUNT));
        // Missing protocol reads fail closed instead of returning a fabricated scalar capacity.
        assertFalse(ok);
        assertEq(response.length, 0);
    }

    function test_AaveExpensiveLowDecimalCollateralReservesNativeRounding() public {
        _aave(60_000e8, 8, 1e8, 1e8, 60_000e8, 24_000e8);
        _mock(POOL, abi.encodeWithSignature("getUserConfiguration(address)", ACCOUNT), abi.encode(3));
        uint256 amount = aaveV3.liquidityWithBorrow(POOL, ASSET, ACCOUNT);
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
        _mock(POOL, abi.encodeWithSignature("getUserConfiguration(address)", ACCOUNT), abi.encode(debt > 0 ? 1 : 0));
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

    function _fundingResults() internal returns (uint256[] memory) {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(5);
        uint256 first = builder.read(
            ExecutingRecipe.Read({
                target: address(morpho),
                data: abi.encodeWithSignature("liquidity(address,address,uint256)", VAULT, ACCOUNT, 100e6),
                offset: 0
            })
        );
        uint256 remaining = builder.binary(OP_SUB, 100e6, first);
        uint256[] memory bindings = new uint256[](1);
        bindings[0] = ExecutingRecipe.binding(100, remaining);
        uint256 second = builder.readQuery(
            ExecutingRecipe.Query({
                target: address(aaveV3),
                data: abi.encodeWithSignature("liquidity(address,address,address,uint256)", POOL, ASSET, ACCOUNT, 0),
                bindings: bindings,
                offset: 0
            })
        );
        remaining = builder.binary(OP_SUB, remaining, second);
        bindings = new uint256[](1);
        bindings[0] = ExecutingRecipe.binding(100, remaining);
        builder.readQuery(
            ExecutingRecipe.Query({
                target: address(aaveV4),
                data: abi.encodeWithSignature("liquidity(address,uint256,address,uint256)", SPOKE, 3, ACCOUNT, 0),
                bindings: bindings,
                offset: 0
            })
        );
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        RecipeExecutor executor = new RecipeExecutor(address(this), ACCOUNT);
        executor.setCaller(address(this));
        executor.setRecipe(recipe.queries, recipe.steps);
        // Caller inputs cannot override the result-bound shortfalls.
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = type(uint256).max;
        return executor.execute(recipe.queries, recipe.steps, inputs, new bytes[](0));
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

    function _aaveV4(uint256 supply, uint256 cash, uint256 added) internal {
        _mock(SPOKE, abi.encodeWithSignature("getReserve(uint256)", 3), abi.encode(ASSET, HUB, 7, 6, 0, 0, 0));
        _mock(SPOKE, abi.encodeWithSignature("getUserSuppliedAssets(uint256,address)", 3, ACCOUNT), abi.encode(supply));
        _mock(HUB, abi.encodeWithSignature("getAssetLiquidity(uint256)", 7), abi.encode(cash));
        _mock(HUB, abi.encodeWithSignature("getSpokeAddedAssets(uint256,address)", 7, SPOKE), abi.encode(added));
    }

    function _mock(address target, bytes memory data, bytes memory result) internal {
        vm.mockCall(target, data, result);
    }
}
