// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {AaveHealthFactor} from "src/contracts/merkle-adapter/automations/health-factors/AaveHealthFactor.sol";
import {
    MorphoBlueHealthFactor
} from "src/contracts/merkle-adapter/automations/health-factors/MorphoBlueHealthFactor.sol";
import {
    MorphoMidnightHealthFactor
} from "src/contracts/merkle-adapter/automations/health-factors/MorphoMidnightHealthFactor.sol";
import {EulerHealthFactor} from "src/contracts/merkle-adapter/automations/health-factors/EulerHealthFactor.sol";
import {
    Id,
    IMorpho as IMorphoBlue,
    IMorphoBase,
    MarketParams,
    Market,
    Position
} from "morpho-blue/src/interfaces/IMorpho.sol";
import {IIrm as IMorphoBlueIrm} from "morpho-blue/src/interfaces/IIrm.sol";
import {MorphoStorageLib} from "morpho-blue/src/libraries/periphery/MorphoStorageLib.sol";
import {
    IMorphoBlueHealthFactor
} from "src/interfaces/merkle-adapter/automations/health-factors/IMorphoBlueHealthFactor.sol";
import {IMorphoMidnight} from "src/interfaces/merkle-adapter/automations/health-factors/IMorphoMidnight.sol";
import {IEulerHealthVault} from "src/interfaces/merkle-adapter/automations/health-factors/IEulerHealthVault.sol";
import {IHealthFactorOracle} from "src/interfaces/merkle-adapter/automations/health-factors/IHealthFactorOracle.sol";
import {IAaveHealthPool} from "src/interfaces/merkle-adapter/automations/health-factors/IAaveHealthFactor.sol";

contract BorrowHealthFactorsTest is Test {
    address internal constant PROTOCOL = address(0x1234);
    address internal constant ACCOUNT = address(0x5678);
    address internal constant ORACLE = address(0x9012);
    address internal constant IRM = address(0x3456);
    address internal constant SECOND_ORACLE = address(0x7890);
    bytes32 internal blueId;
    bytes32 internal constant ID = keccak256("market");

    MorphoBlueHealthFactor internal blue;
    address internal aave;
    MorphoMidnightHealthFactor internal midnight;
    EulerHealthFactor internal euler;
    MarketParams internal blueParams;
    Market internal blueMarket;
    Position internal bluePosition;
    IMorphoMidnight.Market internal midnightMarket;

    function setUp() public {
        vm.warp(1000);
        blue = new MorphoBlueHealthFactor();
        aave = address(new AaveHealthFactor());
        midnight = new MorphoMidnightHealthFactor();
        euler = new EulerHealthFactor();
        vm.etch(PROTOCOL, hex"00");
        vm.etch(ORACLE, hex"00");
        vm.etch(SECOND_ORACLE, hex"00");
        vm.etch(IRM, hex"00");
        blueParams = MarketParams(address(1), address(2), ORACLE, IRM, 0.5e18);
        blueMarket = Market(2_000_000, 2e12, 999_999, 999_999_000_000, 1000, 0);
        bluePosition = Position(0, 1e12, 4_000_000);
        _mockBlue();
        vm.mockCall(ORACLE, abi.encodeCall(IHealthFactorOracle.price, ()), abi.encode(1e36));

        midnightMarket.chainId = 1;
        midnightMarket.midnight = PROTOCOL;
        midnightMarket.loanToken = address(1);
        midnightMarket.maturity = 2000;
        midnightMarket.collateralParams.push(IMorphoMidnight.CollateralParams(address(2), 0.5e18, 0, ORACLE));
        midnightMarket.collateralParams.push(IMorphoMidnight.CollateralParams(address(3), 0.8e18, 0, SECOND_ORACLE));
        _mockMidnight();
        vm.mockCall(PROTOCOL, abi.encodeCall(IMorphoMidnight.debt, (ID, ACCOUNT)), abi.encode(uint128(100)));
        vm.mockCall(PROTOCOL, abi.encodeCall(IMorphoMidnight.collateralBitmap, (ID, ACCOUNT)), abi.encode(uint128(3)));
        vm.mockCall(PROTOCOL, abi.encodeCall(IMorphoMidnight.collateral, (ID, ACCOUNT, 0)), abi.encode(uint128(200)));
        vm.mockCall(PROTOCOL, abi.encodeCall(IMorphoMidnight.collateral, (ID, ACCOUNT, 1)), abi.encode(uint128(100)));
        vm.mockCall(SECOND_ORACLE, abi.encodeCall(IHealthFactorOracle.price, ()), abi.encode(2e36));
    }

    /// forge-config: default.isolate = true
    function test_AaveReturnsOnlyTheSixthPoolValue() public {
        vm.mockCall(
            PROTOCOL,
            abi.encodeCall(IAaveHealthPool.getUserAccountData, (ACCOUNT)),
            abi.encode(uint256(11), uint256(22), uint256(33), uint256(44), uint256(55), uint256(1.73e18))
        );
        assertEq(AaveHealthFactor(aave).getHealthFactor(PROTOCOL, ACCOUNT), 1.73e18);
        vm.snapshotGasLastCall("AaveHealthFactor", "getHealthFactor");
    }

    function testFuzz_AavePreservesTheExactReportedHealthFactor(uint256 healthFactor) public {
        vm.mockCall(
            PROTOCOL,
            abi.encodeCall(IAaveHealthPool.getUserAccountData, (ACCOUNT)),
            abi.encode(uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), healthFactor)
        );
        assertEq(AaveHealthFactor(aave).getHealthFactor(PROTOCOL, ACCOUNT), healthFactor);
    }

    function test_AavePreservesZeroDebtMaximum() public {
        vm.mockCall(
            PROTOCOL,
            abi.encodeCall(IAaveHealthPool.getUserAccountData, (ACCOUNT)),
            abi.encode(uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), type(uint256).max)
        );
        assertEq(AaveHealthFactor(aave).getHealthFactor(PROTOCOL, ACCOUNT), type(uint256).max);
    }

    function test_AaveBubblesPoolFailureAndRejectsShortTuple() public {
        bytes memory query = abi.encodeCall(IAaveHealthPool.getUserAccountData, (ACCOUNT));
        vm.mockCallRevert(PROTOCOL, query, "pool failure");
        vm.expectRevert(bytes("pool failure"));
        AaveHealthFactor(aave).getHealthFactor(PROTOCOL, ACCOUNT);
        vm.clearMockedCalls();
        vm.mockCall(PROTOCOL, query, abi.encode(type(uint256).max));
        vm.expectRevert();
        AaveHealthFactor(aave).getHealthFactor(PROTOCOL, ACCOUNT);
    }

    /// forge-config: default.isolate = true
    function test_BlueVirtualSharesAndLiquidationLtv() public {
        assertEq(blue.getHealthFactor(PROTOCOL, blueId, ACCOUNT), 2e18);
        vm.snapshotGasLastCall("MorphoBlueHealthFactor", "getHealthFactor");
    }

    function test_BluePreviewsAllThreeInterestTerms() public {
        blueMarket.lastUpdate = 999;
        _mockBlue();
        vm.mockCall(IRM, abi.encodeCall(IMorphoBlueIrm.borrowRateView, (blueParams, blueMarket)), abi.encode(0.3e18));
        // 999999 * (0.3 + 0.045 + 0.0045) floors to 349499 additional assets.
        assertEq(blue.getHealthFactor(PROTOCOL, blueId, ACCOUNT), uint256(2_000_000e18) / 1_349_499);
    }

    function test_BlueRejectsInterestOverflowAsProtocolDoes() public {
        blueMarket.totalBorrowAssets = type(uint128).max - 1;
        blueMarket.totalSupplyAssets = type(uint128).max - 1;
        blueMarket.lastUpdate = 999;
        _mockBlue();
        vm.mockCall(IRM, abi.encodeCall(IMorphoBlueIrm.borrowRateView, (blueParams, blueMarket)), abi.encode(0.3e18));
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        blue.getHealthFactor(PROTOCOL, blueId, ACCOUNT);
    }

    function test_BlueZeroDebtDoesNotReadOracleOrIrm() public {
        bluePosition.borrowShares = 0;
        blueMarket.lastUpdate = 999;
        _mockBlue();
        vm.mockCallRevert(ORACLE, abi.encodeCall(IHealthFactorOracle.price, ()), "oracle failure");
        assertEq(blue.getHealthFactor(PROTOCOL, blueId, ACCOUNT), type(uint256).max);
    }

    function test_BlueRoundsDebtUpAndCapacityDown() public {
        bluePosition.borrowShares = 1;
        bluePosition.collateral = 3;
        _mockBlue();
        assertEq(blue.getHealthFactor(PROTOCOL, blueId, ACCOUNT), 1e18);
    }

    function test_BlueZeroIrmSkipsInterest() public {
        blueParams.irm = address(0);
        blueMarket.lastUpdate = 1;
        _mockBlue();
        assertEq(blue.getHealthFactor(PROTOCOL, blueId, ACCOUNT), 2e18);
    }

    function test_BlueRejectsUncreatedMarket() public {
        blueMarket.lastUpdate = 0;
        _mockBlue();
        vm.expectRevert(IMorphoBlueHealthFactor.InvalidMarket.selector);
        blue.getHealthFactor(PROTOCOL, blueId, ACCOUNT);
    }

    function test_BlueBubblesOracleFailure() public {
        vm.mockCallRevert(ORACLE, abi.encodeCall(IHealthFactorOracle.price, ()), "oracle failure");
        vm.expectRevert(bytes("oracle failure"));
        blue.getHealthFactor(PROTOCOL, blueId, ACCOUNT);
    }

    function test_BluePreservesUpstreamCollateralOverflow() public {
        vm.mockCall(ORACLE, abi.encodeCall(IHealthFactorOracle.price, ()), abi.encode(type(uint256).max));
        vm.expectRevert(stdError.arithmeticError);
        blue.getHealthFactor(PROTOCOL, blueId, ACCOUNT);
    }

    function test_BlueBubblesIrmFailure() public {
        blueMarket.lastUpdate = 999;
        _mockBlue();
        vm.mockCallRevert(IRM, abi.encodeCall(IMorphoBlueIrm.borrowRateView, (blueParams, blueMarket)), "irm failure");
        vm.expectRevert(bytes("irm failure"));
        blue.getHealthFactor(PROTOCOL, blueId, ACCOUNT);
    }

    function testFuzz_BlueHealthDecreasesWithDebt(uint128 shares) public {
        bluePosition.borrowShares = uint128(bound(shares, 1e12, 100e12));
        _mockBlue();
        assertGt(blue.getHealthFactor(PROTOCOL, blueId, ACCOUNT), 0);
        assertLe(blue.getHealthFactor(PROTOCOL, blueId, ACCOUNT), 2e18);
    }

    function test_BlueZeroBorrowAssetsSkipsIrm() public {
        blueMarket.totalBorrowAssets = 0;
        blueMarket.lastUpdate = 1;
        _mockBlue();
        assertEq(blue.getHealthFactor(PROTOCOL, blueId, ACCOUNT), 2_000_000e18);
    }

    /// forge-config: default.isolate = true
    function test_MidnightSumsDifferentCollateralFactors() public {
        assertEq(midnight.getHealthFactor(PROTOCOL, ID, ACCOUNT), 2.6e18);
        vm.snapshotGasLastCall("MorphoMidnightHealthFactor", "getHealthFactor");
    }

    function test_MidnightSkipsInactiveOracle() public {
        vm.mockCall(PROTOCOL, abi.encodeCall(IMorphoMidnight.collateralBitmap, (ID, ACCOUNT)), abi.encode(uint128(2)));
        vm.mockCallRevert(ORACLE, abi.encodeCall(IHealthFactorOracle.price, ()), "inactive oracle");
        assertEq(midnight.getHealthFactor(PROTOCOL, ID, ACCOUNT), 1.6e18);
    }

    function test_MidnightZeroDebtAfterMaturity() public {
        vm.warp(2001);
        vm.mockCall(PROTOCOL, abi.encodeCall(IMorphoMidnight.debt, (ID, ACCOUNT)), abi.encode(uint128(0)));
        assertEq(midnight.getHealthFactor(PROTOCOL, ID, ACCOUNT), type(uint256).max);
    }

    function test_MidnightMaturityBoundary() public {
        vm.warp(2000);
        assertEq(midnight.getHealthFactor(PROTOCOL, ID, ACCOUNT), 2.6e18);
        vm.warp(2001);
        assertEq(midnight.getHealthFactor(PROTOCOL, ID, ACCOUNT), 0);
    }

    function test_MidnightRoundsEachCollateralDown() public {
        vm.mockCall(PROTOCOL, abi.encodeCall(IMorphoMidnight.collateral, (ID, ACCOUNT, 0)), abi.encode(uint128(3)));
        vm.mockCall(PROTOCOL, abi.encodeCall(IMorphoMidnight.collateral, (ID, ACCOUNT, 1)), abi.encode(uint128(1)));
        assertEq(midnight.getHealthFactor(PROTOCOL, ID, ACCOUNT), 0.02e18);
    }

    function test_MidnightZeroCollateral() public {
        vm.mockCall(PROTOCOL, abi.encodeCall(IMorphoMidnight.collateralBitmap, (ID, ACCOUNT)), abi.encode(uint128(0)));
        assertEq(midnight.getHealthFactor(PROTOCOL, ID, ACCOUNT), 0);
    }

    function test_MidnightHighestCollateralBit() public {
        for (uint256 i = 2; i < 128; ++i) {
            midnightMarket.collateralParams
                .push(IMorphoMidnight.CollateralParams(address(uint160(i + 2)), 0.5e18, 0, ORACLE));
        }
        _mockMidnight();
        vm.mockCall(
            PROTOCOL, abi.encodeCall(IMorphoMidnight.collateralBitmap, (ID, ACCOUNT)), abi.encode(uint128(1) << 127)
        );
        vm.mockCall(PROTOCOL, abi.encodeCall(IMorphoMidnight.collateral, (ID, ACCOUNT, 127)), abi.encode(uint128(200)));
        assertEq(midnight.getHealthFactor(PROTOCOL, ID, ACCOUNT), 1e18);
    }

    function testFuzz_MidnightValuesOnlyActiveCollateral(uint128 collateralBitmap) public {
        delete midnightMarket.collateralParams;
        uint256 expectedCapacity;
        for (uint256 i; i < 128; ++i) {
            uint256 price = i % 2 == 0 ? 1e36 : 2e36;
            uint256 lltv = (i % 3 + 1) * 0.25e18;
            uint128 amount = uint128(3 * i + 1);
            midnightMarket.collateralParams
                .push(
                    IMorphoMidnight.CollateralParams(
                        address(uint160(i + 2)), lltv, 0, i % 2 == 0 ? ORACLE : SECOND_ORACLE
                    )
                );
            if (collateralBitmap & (uint128(1) << i) != 0) {
                vm.mockCall(PROTOCOL, abi.encodeCall(IMorphoMidnight.collateral, (ID, ACCOUNT, i)), abi.encode(amount));
                expectedCapacity += (uint256(amount) * price / 1e36) * lltv / 1e18;
            } else {
                vm.mockCallRevert(
                    PROTOCOL, abi.encodeCall(IMorphoMidnight.collateral, (ID, ACCOUNT, i)), "inactive collateral"
                );
            }
        }
        _mockMidnight();
        vm.mockCall(
            PROTOCOL, abi.encodeCall(IMorphoMidnight.collateralBitmap, (ID, ACCOUNT)), abi.encode(collateralBitmap)
        );
        assertEq(midnight.getHealthFactor(PROTOCOL, ID, ACCOUNT), expectedCapacity * 1e18 / 100);
    }

    function test_MidnightBubblesOracleFailure() public {
        vm.mockCallRevert(ORACLE, abi.encodeCall(IHealthFactorOracle.price, ()), "oracle failure");
        vm.expectRevert(bytes("oracle failure"));
        midnight.getHealthFactor(PROTOCOL, ID, ACCOUNT);
    }

    function test_MidnightPreservesUpstreamCollateralOverflow() public {
        vm.mockCall(ORACLE, abi.encodeCall(IHealthFactorOracle.price, ()), abi.encode(type(uint256).max));
        vm.expectRevert(stdError.arithmeticError);
        midnight.getHealthFactor(PROTOCOL, ID, ACCOUNT);
    }

    /// forge-config: default.isolate = true
    function test_EulerUsesLiquidationRatherThanBorrowingLtv() public {
        vm.mockCall(
            PROTOCOL, abi.encodeCall(IEulerHealthVault.accountLiquidity, (ACCOUNT, false)), abi.encode(100, 100)
        );
        vm.mockCall(PROTOCOL, abi.encodeCall(IEulerHealthVault.accountLiquidity, (ACCOUNT, true)), abi.encode(180, 100));
        assertEq(euler.getHealthFactor(PROTOCOL, ACCOUNT), 1.8e18);
        vm.snapshotGasLastCall("EulerHealthFactor", "getHealthFactor");
    }

    function test_EulerZeroDebt() public {
        vm.mockCall(PROTOCOL, abi.encodeCall(IEulerHealthVault.accountLiquidity, (ACCOUNT, true)), abi.encode(0, 0));
        assertEq(euler.getHealthFactor(PROTOCOL, ACCOUNT), type(uint256).max);
    }

    function test_EulerFullPrecisionAndRoundDown() public {
        vm.mockCall(
            PROTOCOL,
            abi.encodeCall(IEulerHealthVault.accountLiquidity, (ACCOUNT, true)),
            abi.encode(1 << 240, 3 << 240)
        );
        assertEq(euler.getHealthFactor(PROTOCOL, ACCOUNT), uint256(1e18) / 3);
    }

    function test_EulerBubblesInvalidController() public {
        vm.mockCallRevert(
            PROTOCOL, abi.encodeCall(IEulerHealthVault.accountLiquidity, (ACCOUNT, true)), "controller failure"
        );
        vm.expectRevert(bytes("controller failure"));
        euler.getHealthFactor(PROTOCOL, ACCOUNT);
    }

    function _mockBlue() internal {
        blueId = keccak256(abi.encode(blueParams));
        vm.mockCall(PROTOCOL, abi.encodeCall(IMorphoBlue.idToMarketParams, (Id.wrap(blueId))), abi.encode(blueParams));
        vm.mockCall(PROTOCOL, abi.encodeCall(IMorphoBlue.market, (Id.wrap(blueId))), abi.encode(blueMarket));
        vm.mockCall(
            PROTOCOL, abi.encodeCall(IMorphoBlue.position, (Id.wrap(blueId), ACCOUNT)), abi.encode(bluePosition)
        );
        bytes32[] memory slots = new bytes32[](1);
        slots[0] = MorphoStorageLib.positionBorrowSharesAndCollateralSlot(Id.wrap(blueId), ACCOUNT);
        bytes32[] memory values = new bytes32[](1);
        values[0] = bytes32(uint256(bluePosition.borrowShares) | (uint256(bluePosition.collateral) << 128));
        vm.mockCall(PROTOCOL, abi.encodeCall(IMorphoBase.extSloads, (slots)), abi.encode(values));
    }

    function _mockMidnight() internal {
        vm.mockCall(PROTOCOL, abi.encodeCall(IMorphoMidnight.toMarket, (ID)), abi.encode(midnightMarket));
    }
}
