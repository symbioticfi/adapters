// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {
    AaveV3Liquidity,
    ILiquidityAaveOracle,
    ILiquidityAavePool,
    ILiquidityAaveProvider
} from "src/contracts/merkle-adapter/automations/liquidity/AaveV3Liquidity.sol";

import {PercentageMath} from "src/contracts/merkle-adapter/automations/liquidity/PercentageMath.sol";

import {IAaveV3Pool} from "src/interfaces/aave_v3_adapter/IAaveV3AdapterDependencies.sol";
import {
    AAVE_BORROWING_MASK,
    IAaveV3Liquidity
} from "src/interfaces/merkle-adapter/automations/liquidity/IAaveV3Liquidity.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract AaveLiquidityOptimizationTest is Test {
    address internal constant POOL = address(0x100);
    address internal constant ASSET = address(0x200);
    address internal constant ACCOUNT = address(0x300);
    address internal constant ATOKEN = address(0x400);
    address internal constant ORACLE = address(0x600);

    address internal optimized;
    address internal legacy;

    function setUp() public {
        optimized = address(new AaveV3Liquidity());
        legacy = address(new AaveLiquidityLegacy());
        _mockReserve(_configuration(6, 8000), 1000e6, 1000e6, 400e8, 3);
    }

    function test_SupplyOnlySkipsPortfolioOracleAndIncomeReads() public {
        _mock(POOL, abi.encodeCall(ILiquidityAavePool.getUserConfiguration, (ACCOUNT)), abi.encode(2));
        _unusedValuationReadsRevert();
        vm.mockCallRevert(POOL, abi.encodeCall(ILiquidityAavePool.getUserAccountData, (ACCOUNT)), hex"12345678");
        assertEq(IAaveV3Liquidity(optimized).liquidityWithBorrow(POOL, ASSET, ACCOUNT), 1000e6);
    }

    function test_AllCollateralBitsWithoutBorrowingSkipPortfolioValuation() public {
        _mock(
            POOL, abi.encodeCall(ILiquidityAavePool.getUserConfiguration, (ACCOUNT)), abi.encode(~AAVE_BORROWING_MASK)
        );
        vm.mockCallRevert(POOL, abi.encodeCall(ILiquidityAavePool.getUserAccountData, (ACCOUNT)), hex"12345678");
        assertEq(IAaveV3Liquidity(optimized).liquidityWithBorrow(POOL, ASSET, ACCOUNT), 1000e6);
    }

    function testFuzz_EveryBorrowingBitStillChecksHealth(uint8 reserveSeed) public {
        uint256 reserve = uint256(reserveSeed) % 128;
        _mock(
            POOL,
            abi.encodeCall(ILiquidityAavePool.getUserConfiguration, (ACCOUNT)),
            abi.encode(uint256(1) << (2 * reserve))
        );
        _mock(
            POOL,
            abi.encodeCall(ILiquidityAavePool.getUserAccountData, (ACCOUNT)),
            abi.encode(1000e8, 900e8, 0, 8000, 7000, 0.9e18)
        );
        _unusedValuationReadsRevert();
        assertEq(IAaveV3Liquidity(optimized).liquidityWithBorrow(POOL, ASSET, ACCOUNT), 0);
    }

    function test_ZeroBalanceSkipsBitmapAndValuation() public {
        _mock(ATOKEN, abi.encodeCall(IERC20.balanceOf, (ACCOUNT)), abi.encode(0));
        _unusedValuationReadsRevert();
        vm.mockCallRevert(POOL, abi.encodeCall(ILiquidityAavePool.getUserConfiguration, (ACCOUNT)), hex"12345678");
        assertEq(IAaveV3Liquidity(optimized).liquidityWithBorrow(POOL, ASSET, ACCOUNT), 0);
    }

    function test_InactiveAndPausedSkipReserveAndValuationReads() public {
        _unusedValuationReadsRevert();
        vm.mockCallRevert(POOL, abi.encodeCall(ILiquidityAavePool.getReserveAToken, (ASSET)), hex"12345678");
        _mock(
            POOL,
            abi.encodeCall(ILiquidityAavePool.getConfiguration, (ASSET)),
            abi.encode(_configuration(6, 8000) & ~(uint256(1) << 56))
        );
        assertEq(IAaveV3Liquidity(optimized).liquidityWithBorrow(POOL, ASSET, ACCOUNT), 0);
        _mock(
            POOL,
            abi.encodeCall(ILiquidityAavePool.getConfiguration, (ASSET)),
            abi.encode(_configuration(6, 8000) | (uint256(1) << 60))
        );
        assertEq(IAaveV3Liquidity(optimized).liquidityWithBorrow(POOL, ASSET, ACCOUNT), 0);
    }

    function test_HealthyNonCollateralSkipsOracleAndIncome() public {
        _mock(POOL, abi.encodeCall(ILiquidityAavePool.getUserConfiguration, (ACCOUNT)), abi.encode(1));
        _unusedValuationReadsRevert();
        assertEq(IAaveV3Liquidity(optimized).liquidityWithBorrow(POOL, ASSET, ACCOUNT), 1000e6);
    }

    function test_ZeroBaseDebtWithBorrowingFlagSkipsOracleAndIncome() public {
        _mockReserve(_configuration(6, 8000), 1000e6, 1000e6, 0, 3);
        _unusedValuationReadsRevert();
        assertEq(IAaveV3Liquidity(optimized).liquidityWithBorrow(POOL, ASSET, ACCOUNT), 1000e6);
    }

    function test_RestrictedPositionsStillReturnZero() public {
        _unusedValuationReadsRevert();
        uint256[3] memory configurations = [
            _configuration(6, 8000) | (uint256(1) << 212),
            _configuration(6, 8000) | (uint256(1) << 62),
            _configuration(6, 8000) & ~uint256(0xffff)
        ];
        for (uint256 i; i < configurations.length; ++i) {
            _mock(POOL, abi.encodeCall(ILiquidityAavePool.getConfiguration, (ASSET)), abi.encode(configurations[i]));
            assertEq(IAaveV3Liquidity(optimized).liquidityWithBorrow(POOL, ASSET, ACCOUNT), 0);
        }
    }

    function test_RestrictionsOnOtherReservesStillReturnZero() public {
        address secondAsset = address(0x201);
        _mock(POOL, abi.encodeCall(ILiquidityAavePool.getReserveAddressById, (1)), abi.encode(secondAsset));
        _unusedValuationReadsRevert();
        uint256[3] memory configurations = [
            _configuration(6, 8000) | (uint256(1) << 212),
            _configuration(6, 8000) & ~uint256(0xffff),
            _configuration(6, 8000) | (uint256(1) << 62)
        ];
        for (uint256 i; i < configurations.length; ++i) {
            _mock(
                POOL, abi.encodeCall(ILiquidityAavePool.getConfiguration, (secondAsset)), abi.encode(configurations[i])
            );
            _mock(POOL, abi.encodeCall(ILiquidityAavePool.getUserConfiguration, (ACCOUNT)), abi.encode(i < 2 ? 11 : 6));
            assertEq(IAaveV3Liquidity(optimized).liquidityWithBorrow(POOL, ASSET, ACCOUNT), 0);
        }
    }

    function test_RequiredOracleAndIncomeFailuresStillRevert() public {
        vm.mockCallRevert(ORACLE, abi.encodeCall(ILiquidityAaveOracle.getAssetPrice, (ASSET)), hex"12345678");
        vm.expectRevert(bytes4(0x12345678));
        IAaveV3Liquidity(optimized).liquidityWithBorrow(POOL, ASSET, ACCOUNT);
        _mock(ORACLE, abi.encodeCall(ILiquidityAaveOracle.getAssetPrice, (ASSET)), abi.encode(1e8));
        vm.mockCallRevert(POOL, abi.encodeCall(ILiquidityAavePool.getReserveNormalizedIncome, (ASSET)), hex"12345678");
        vm.expectRevert(bytes4(0x12345678));
        IAaveV3Liquidity(optimized).liquidityWithBorrow(POOL, ASSET, ACCOUNT);
    }

    function test_RequiredValuationRejectsUnsupportedDecimals() public {
        _mock(POOL, abi.encodeCall(ILiquidityAavePool.getConfiguration, (ASSET)), abi.encode(_configuration(37, 8000)));
        vm.expectRevert();
        IAaveV3Liquidity(optimized).liquidityWithBorrow(POOL, ASSET, ACCOUNT);
    }

    function test_ZeroPriceSkipsIncome() public {
        _mock(ORACLE, abi.encodeCall(ILiquidityAaveOracle.getAssetPrice, (ASSET)), abi.encode(0));
        vm.mockCallRevert(POOL, abi.encodeCall(ILiquidityAavePool.getReserveNormalizedIncome, (ASSET)), hex"12345678");
        assertEq(IAaveV3Liquidity(optimized).liquidityWithBorrow(POOL, ASSET, ACCOUNT), 0);
    }

    function testFuzz_BorrowingMatchesLegacy(
        uint128 owned,
        uint128 cash,
        uint64 debtSeed,
        uint8 decimalsSeed,
        uint16 thresholdSeed,
        uint64 priceSeed,
        uint64 incomeSeed,
        bool collateral
    ) public {
        _mockReserve(
            _configuration(uint256(decimalsSeed) % 37, uint256(thresholdSeed) % 10_001),
            owned,
            cash,
            bound(debtSeed, 1, 800e8),
            collateral ? 3 : 1
        );
        _mock(ORACLE, abi.encodeCall(ILiquidityAaveOracle.getAssetPrice, (ASSET)), abi.encode(uint256(priceSeed) + 1));
        _mock(
            POOL,
            abi.encodeCall(ILiquidityAavePool.getReserveNormalizedIncome, (ASSET)),
            abi.encode(1e27 + uint256(incomeSeed) * 1e9)
        );
        assertEq(
            IAaveV3Liquidity(optimized).liquidityWithBorrow(POOL, ASSET, ACCOUNT),
            IAaveV3Liquidity(legacy).liquidityWithBorrow(POOL, ASSET, ACCOUNT)
        );
    }

    function testFuzz_SupplyOnlyMatchesLegacy(uint128 owned, uint128 cash) public {
        _mockReserve(_configuration(6, 8000), owned, cash, 0, 2);
        assertEq(
            IAaveV3Liquidity(optimized).liquidityWithBorrow(POOL, ASSET, ACCOUNT),
            IAaveV3Liquidity(legacy).liquidityWithBorrow(POOL, ASSET, ACCOUNT)
        );
    }

    /// forge-config: default.isolate = true
    function test_GasSupplyOnly() public {
        _mockReserve(_configuration(6, 8000), 1000e6, 1000e6, 0, 2);
        _compareGas("supplyOnly");
    }

    /// forge-config: default.isolate = true
    function test_GasCollateralSupportingDebt() public {
        _compareGas("collateralSupportingDebt");
    }

    function _compareGas(string memory name) internal {
        uint256 snapshot = vm.snapshotState();
        uint256 expected = IAaveV3Liquidity(legacy).liquidityWithBorrow(POOL, ASSET, ACCOUNT);
        uint256 beforeGas = vm.snapshotGasLastCall("AaveLiquidityOptimization", string.concat(name, "Legacy"));
        assertTrue(vm.revertToState(snapshot));
        uint256 actual = IAaveV3Liquidity(optimized).liquidityWithBorrow(POOL, ASSET, ACCOUNT);
        uint256 afterGas = vm.snapshotGasLastCall("AaveLiquidityOptimization", name);
        assertEq(actual, expected);
        assertLt(afterGas, beforeGas);
        emit log_named_uint("Legacy gas", beforeGas);
        emit log_named_uint("Optimized gas", afterGas);
    }

    function _mockReserve(uint256 configuration, uint256 owned, uint128 cash, uint256 debt, uint256 user) internal {
        _mock(POOL, abi.encodeCall(ILiquidityAavePool.getUserEMode, (ACCOUNT)), abi.encode(0));
        _mock(POOL, abi.encodeCall(ILiquidityAavePool.getConfiguration, (ASSET)), abi.encode(configuration));
        _mock(POOL, abi.encodeCall(ILiquidityAavePool.getUserConfiguration, (ACCOUNT)), abi.encode(user));
        _mock(POOL, abi.encodeCall(ILiquidityAavePool.getReserveAddressById, (0)), abi.encode(ASSET));
        _mock(POOL, abi.encodeCall(ILiquidityAavePool.getReserveAToken, (ASSET)), abi.encode(ATOKEN));
        _mock(POOL, abi.encodeCall(ILiquidityAavePool.getVirtualUnderlyingBalance, (ASSET)), abi.encode(cash));
        _mock(POOL, abi.encodeCall(ILiquidityAavePool.getReserveNormalizedIncome, (ASSET)), abi.encode(12e26));
        _mock(POOL, abi.encodeCall(ILiquidityAavePool.ADDRESSES_PROVIDER, ()), abi.encode(ORACLE));
        _mock(
            POOL,
            abi.encodeCall(ILiquidityAavePool.getUserAccountData, (ACCOUNT)),
            abi.encode(1000e8, debt, 0, 8000, 7000, 2e18)
        );
        _mock(ORACLE, abi.encodeCall(ILiquidityAaveProvider.getPriceOracle, ()), abi.encode(ORACLE));
        _mock(ORACLE, abi.encodeCall(ILiquidityAaveOracle.getAssetPrice, (ASSET)), abi.encode(1e8));
        _mock(ASSET, abi.encodeCall(IERC20.balanceOf, (ATOKEN)), abi.encode(cash));
        _mock(ATOKEN, abi.encodeCall(IERC20.balanceOf, (ACCOUNT)), abi.encode(owned));
    }

    function _unusedValuationReadsRevert() internal {
        vm.mockCallRevert(POOL, abi.encodeCall(ILiquidityAavePool.getReserveNormalizedIncome, (ASSET)), hex"12345678");
        vm.mockCallRevert(POOL, abi.encodeCall(ILiquidityAavePool.ADDRESSES_PROVIDER, ()), hex"12345678");
    }

    function _configuration(uint256 decimals, uint256 threshold) internal pure returns (uint256) {
        return 7000 | (threshold << 16) | (decimals << 48) | (uint256(1) << 56) | (uint256(1) << 58);
    }

    function _mock(address target, bytes memory data, bytes memory response) internal {
        vm.mockCall(target, data, response);
    }
}

/// @dev Frozen pre-optimization implementation for behavior and gas comparisons.
contract AaveLiquidityLegacy is IAaveV3Liquidity {
    function maxBorrow(address, address, address, uint256) external pure returns (uint256) {
        revert();
    }
    using Math for uint256;
    using PercentageMath for uint256;

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IAaveV3Liquidity
    function liquidity(address pool, address asset, address account) public view returns (uint256) {
        return Math.min(
            IERC20(ILiquidityAavePool(pool).getReserveAToken(asset)).balanceOf(account),
            ILiquidityAavePool(pool).getVirtualUnderlyingBalance(asset)
        );
    }

    /// @inheritdoc IAaveV3Liquidity
    function liquidityWithBorrow(address pool, address asset, address account) public view returns (uint256 amount) {
        if (ILiquidityAavePool(pool).getUserEMode(account) > 0) return 0;
        AaveReserve memory r = _aaveReserve(pool, asset);
        if (!_aaveActive(r.configuration)) return 0;
        amount = Math.min(IERC20(r.aToken).balanceOf(account), r.cash);
        if (amount == 0) return 0;
        (uint256 collateral, uint256 debt,, uint256 threshold,, uint256 health) =
            ILiquidityAavePool(pool).getUserAccountData(account);
        if (debt == 0) return amount;
        if (health < 1e18) return 0;
        (bool used, bool restricted) = _aaveUserFlags(pool, account, asset);
        if (restricted) return 0;
        if (!used) return amount;
        uint256 reserveThreshold = (r.configuration >> 16) & 0xffff;
        if (reserveThreshold == 0 || r.price == 0) return 0;
        uint256 weighted = collateral.percentMulFloor(threshold);
        // V3.3/V3.4 truncate the post-withdraw weighted threshold to whole basis points.
        // Reserve one basis point of collateral plus two base units for the remaining conversion rounding.
        uint256 spare = weighted.saturatingSub(debt).saturatingSub(Math.ceilDiv(collateral, 10_000) + 2);
        uint256 capacity = spare.percentDivFloor(reserveThreshold).mulDiv(r.unit, r.price);
        return Math.min(amount, capacity.saturatingSub(r.incomeRounding));
    }

    /* INTERNAL FUNCTIONS */

    function _aaveReserve(address pool, address asset) internal view returns (AaveReserve memory r) {
        r.configuration = ILiquidityAavePool(pool).getConfiguration(asset);
        uint256 decimals = (r.configuration >> 48) & 0xff;
        if (decimals > 36) revert();
        r.unit = 10 ** decimals;
        r.incomeRounding = 2 * Math.ceilDiv(ILiquidityAavePool(pool).getReserveNormalizedIncome(asset), 1e27);
        r.aToken = ILiquidityAavePool(pool).getReserveAToken(asset);
        r.cash =
            Math.min(IERC20(asset).balanceOf(r.aToken), ILiquidityAavePool(pool).getVirtualUnderlyingBalance(asset));
        r.price = ILiquidityAaveOracle(
                ILiquidityAaveProvider(ILiquidityAavePool(pool).ADDRESSES_PROVIDER()).getPriceOracle()
            )
            .getAssetPrice(asset);
    }

    function _aaveActive(uint256 configuration) internal pure returns (bool) {
        return configuration & (1 << 56) > 0 && configuration & (1 << 60) == 0;
    }

    function _aaveUserFlags(address pool, address account, address asset)
        internal
        view
        returns (bool used, bool restricted)
    {
        uint256 user = ILiquidityAavePool(pool).getUserConfiguration(account);
        for (uint16 i; user > 0 && i < 128; ++i) {
            uint256 flags = user & 3;
            user >>= 2;
            if (flags == 0) continue;
            address reserve = ILiquidityAavePool(pool).getReserveAddressById(i);
            uint256 configuration = ILiquidityAavePool(pool).getConfiguration(reserve);
            if (flags & 2 > 0) {
                if (reserve == asset) used = true;
                // Isolation and zero-LTV collateral need protocol-specific unwind ordering.
                if (configuration >> 212 & ((1 << 40) - 1) > 0 || configuration & 0xffff == 0) restricted = true;
            }
            if (flags & 1 > 0 && configuration & (1 << 62) > 0) restricted = true;
        }
        if (ILiquidityAavePool(pool).getConfiguration(asset) & (1 << 62) > 0) restricted = true;
    }
}

interface IAaveOptimizationBorrow {
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address account)
        external;
}

/// @dev Only the initial WETH funding is synthetic; Aave supply, borrowing, valuation and withdrawal use mainnet code.
contract AaveLiquidityOptimizationMainnetTest is Test {
    address internal constant POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant ACCOUNT = address(0xaa7e);
    address internal optimized;
    address internal legacy;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "ETH_RPC_URL is required for the Aave optimization integration");
            return;
        }
        vm.createSelectFork(rpc, 25_892_000);
        optimized = address(new AaveV3Liquidity());
        legacy = address(new AaveLiquidityLegacy());
        deal(WETH, ACCOUNT, 10e18);
        vm.startPrank(ACCOUNT);
        IERC20(WETH).approve(POOL, 10e18);
        IAaveV3Pool(POOL).supply(WETH, 10e18, ACCOUNT, 0);
        vm.stopPrank();
    }

    /// forge-config: default.isolate = true
    function test_MainnetSupplyOnlyCapacityMatchesLegacyAndWithdraws() public {
        _compareAndWithdraw("mainnetSupplyOnly");
    }

    /// forge-config: default.isolate = true
    function test_MainnetDebtCapacityMatchesLegacyAndPreservesHealth() public {
        vm.prank(ACCOUNT);
        IAaveOptimizationBorrow(POOL).borrow(USDC, 1000e6, 2, 0, ACCOUNT);
        _compareAndWithdraw("mainnetCollateralSupportingDebt");
        (,,,,, uint256 health) = ILiquidityAavePool(POOL).getUserAccountData(ACCOUNT);
        assertGe(health, 1e18);
    }

    function _compareAndWithdraw(string memory name) internal {
        uint256 snapshot = vm.snapshotState();
        uint256 expected = IAaveV3Liquidity(legacy).liquidityWithBorrow(POOL, WETH, ACCOUNT);
        uint256 beforeGas = vm.snapshotGasLastCall("AaveLiquidityOptimization", string.concat(name, "Legacy"));
        assertTrue(vm.revertToState(snapshot));
        uint256 actual = IAaveV3Liquidity(optimized).liquidityWithBorrow(POOL, WETH, ACCOUNT);
        uint256 afterGas = vm.snapshotGasLastCall("AaveLiquidityOptimization", name);
        assertEq(actual, expected);
        assertGt(actual, 0);
        assertLt(afterGas, beforeGas);
        emit log_named_uint("Legacy gas", beforeGas);
        emit log_named_uint("Optimized gas", afterGas);
        vm.prank(ACCOUNT);
        assertEq(IAaveV3Pool(POOL).withdraw(WETH, actual, ACCOUNT), actual);
        assertEq(IERC20(WETH).balanceOf(ACCOUNT), actual);
    }
}
