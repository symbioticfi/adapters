// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ExecutorLiquidityLens} from "src/contracts/periphery/ExecutorLiquidityLens.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {MarketParams} from "morpho-blue/src/interfaces/IMorpho.sol";
import {
    MorphoBlueHealthFactor
} from "src/contracts/merkle-adapter/capabilities/borrow-capability/MorphoBlueHealthFactor.sol";

import {IGuardedCallsCapability} from "src/interfaces/merkle-adapter/capabilities/IGuardedCallsCapability.sol";
import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    GuardedCallsMainnetTest,
    IGuardedCallsCapabilityAavePool
} from "test/adapters/merkle-adapter/GuardedCallsMainnet.t.sol";
import {BorrowTestCall} from "test/adapters/merkle-adapter/mocks/GuardedCallsMocks.sol";

interface ILensRealMorpho {
    function createMarket(MarketParams calldata params) external;
    function supply(MarketParams calldata params, uint256 assets, uint256 shares, address account, bytes calldata data)
        external
        returns (uint256, uint256);
    function supplyCollateral(MarketParams calldata params, uint256 assets, address account, bytes calldata data)
        external;
    function borrow(MarketParams calldata params, uint256 assets, uint256 shares, address account, address receiver)
        external
        returns (uint256, uint256);
}

contract LensMainnetMorphoOracle {
    function price() external pure returns (uint256) {
        return 2000e24;
    }
}

interface ILensAaveWithdraw {
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

contract ExecutorLiquidityLensMainnetTest is GuardedCallsMainnetTest {
    function test_MainnetLensBorrowCapacityExecutesWithProtectedMinimum() public {
        ExecutorLiquidityLens lens = _lens();
        uint256 amount = lens.aaveBorrow(POOL, USDC, address(adapter), _minimum);
        assertGt(amount, 0);
        _manage(
            address(adapter),
            _guardedData(
                POOL,
                health.target,
                abi.encodeCall(IGuardedCallsCapabilityAavePool.borrow, (USDC, amount, 2, 0, address(adapter))),
                health.data
            )
        );
        assertEq(IERC20(USDC).balanceOf(address(adapter)), amount);
        assertGe(_healthValue(health.target, health.data), _minimum);
        assertLe(lens.aaveBorrow(POOL, USDC, address(adapter), _minimum), 2);
    }

    function test_MainnetLensWithdrawalProtectsRemainingCollateral() public {
        ExecutorLiquidityLens lens = _lens();
        _manage(
            address(adapter),
            _guardedData(
                POOL,
                health.target,
                abi.encodeCall(IGuardedCallsCapabilityAavePool.borrow, (USDC, BORROW_AMOUNT, 2, 0, address(adapter))),
                health.data
            )
        );
        uint256 amount = lens.aaveWithdraw(POOL, WETH, address(adapter));
        assertGt(amount, 0);
        assertLt(amount, 10e18);
        _manage(POOL, abi.encodeCall(ILensAaveWithdraw.withdraw, (WETH, amount, address(adapter))));
        assertEq(IERC20(WETH).balanceOf(address(adapter)), amount);
        assertGe(_healthValue(health.target, health.data), 1e18);
    }

    function test_MainnetLensCheckedWithdrawalUsesLeafFloor() public {
        ExecutorLiquidityLens lens = _lens();
        _manage(
            address(adapter),
            _guardedData(
                POOL,
                health.target,
                abi.encodeCall(IGuardedCallsCapabilityAavePool.borrow, (USDC, BORROW_AMOUNT, 2, 0, address(adapter))),
                health.data
            )
        );
        uint256 beforeCapacity = lens.aaveWithdrawGuarded(POOL, WETH, address(adapter), _minimum);
        _minimum = 2e18;
        uint256 amount = lens.aaveWithdrawGuarded(POOL, WETH, address(adapter), _minimum);
        assertGt(amount, 0);
        assertLt(amount, beforeCapacity);
        _manage(
            address(adapter),
            _guardedData(
                POOL,
                health.target,
                abi.encodeCall(ILensAaveWithdraw.withdraw, (WETH, amount, address(adapter))),
                health.data
            )
        );
        assertEq(IERC20(WETH).balanceOf(address(adapter)), amount);
        assertGe(_healthValue(health.target, health.data), 2e18);
    }

    function test_MainnetLensUsesEachLeavesLiteralMinimum() public {
        ExecutorLiquidityLens lens = _lens();
        uint256 beforeCapacity = lens.aaveBorrow(POOL, USDC, address(adapter), _minimum);
        _minimum = 2e18;
        uint256 afterCapacity = lens.aaveBorrow(POOL, USDC, address(adapter), _minimum);
        assertLt(afterCapacity, beforeCapacity);
        assertGt(afterCapacity, 0);
    }

    function test_MainnetLensMorphoBorrowCapacityExecutesOnRealProtocol() public {
        address morpho = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
        MarketParams memory params = MarketParams(USDC, WETH, address(new LensMainnetMorphoOracle()), address(0), 86e16);
        ILensRealMorpho(morpho).createMarket(params);
        deal(USDC, address(this), 100_000e6);
        IERC20(USDC).approve(morpho, 100_000e6);
        ILensRealMorpho(morpho).supply(params, 100_000e6, 0, address(this), "");
        deal(WETH, address(adapter), 10e18);
        _manage(WETH, abi.encodeCall(IERC20.approve, (morpho, 10e18)));
        _manage(morpho, abi.encodeCall(ILensRealMorpho.supplyCollateral, (params, 10e18, address(adapter), "")));
        ExecutorLiquidityLens lens = _lens();
        bytes32 marketId = keccak256(abi.encode(params));
        BorrowTestCall memory morphoHealth = BorrowTestCall(
            address(new MorphoBlueHealthFactor()),
            abi.encodeCall(MorphoBlueHealthFactor.getHealthFactor, (morpho, marketId, address(adapter)))
        );
        _minimum = 1.2e18;
        uint256 beforeCapacity = lens.morphoBorrowGuarded(morpho, marketId, address(adapter), _minimum);
        _minimum = 2e18;
        uint256 amount = lens.morphoBorrowGuarded(morpho, marketId, address(adapter), _minimum);
        assertLt(amount, beforeCapacity);
        assertGt(amount, 8000e6);
        _manage(
            address(adapter),
            _guardedData(
                morpho,
                morphoHealth.target,
                abi.encodeCall(ILensRealMorpho.borrow, (params, amount, 0, address(adapter), address(adapter))),
                morphoHealth.data
            )
        );
        assertGe(_healthValue(morphoHealth.target, morphoHealth.data), 2e18);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), amount);
        assertEq(lens.morphoBorrowGuarded(morpho, marketId, address(adapter), _minimum), 0);
    }

    function test_MainnetLensZeroFloorUsesProtocolSolvency() public {
        ExecutorLiquidityLens lens = _lens();
        assertEq(lens.aaveBorrow(POOL, USDC, address(adapter), 0), lens.aaveBorrow(POOL, USDC, address(adapter), 1e18));
    }

    function _lens() internal returns (ExecutorLiquidityLens) {
        return ExecutorLiquidityLens(
            IImmutableFactory(address(new ImmutableFactory(type(ExecutorLiquidityLens).creationCode))).create("")
        );
    }
}
