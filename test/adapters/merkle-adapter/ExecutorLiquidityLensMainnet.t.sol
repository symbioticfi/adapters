// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ExecutorLiquidityLens} from "src/contracts/periphery/ExecutorLiquidityLens.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {MarketParams} from "morpho-blue/src/interfaces/IMorpho.sol";
import {
    MorphoBlueHealthFactor
} from "src/contracts/merkle-adapter/capabilities/borrow-capability/MorphoBlueHealthFactor.sol";

import {IBorrowCapability} from "src/interfaces/merkle-adapter/capabilities/IBorrowCapability.sol";
import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    BorrowCapabilityMainnetTest,
    IBorrowCapabilityAavePool
} from "test/adapters/merkle-adapter/BorrowCapabilityMainnet.t.sol";
import {BorrowTestCall} from "test/adapters/merkle-adapter/mocks/BorrowCapabilityMocks.sol";

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

contract ExecutorLiquidityLensMainnetTest is BorrowCapabilityMainnetTest {
    function test_MainnetLensBorrowCapacityExecutesWithProtectedMinimum() public {
        ExecutorLiquidityLens lens = _lens();
        uint256 amount =
            lens.borrowCapability(address(adapter), POOL, USDC, keccak256(abi.encode(health.target, health.data)));
        assertGt(amount, 0);
        _manage(
            address(adapter),
            abi.encodeCall(
                IBorrowCapability.borrow,
                (
                    POOL,
                    health.target,
                    abi.encodeCall(IBorrowCapabilityAavePool.borrow, (USDC, amount, 2, 0, address(adapter))),
                    health.data
                )
            )
        );
        assertEq(IERC20(USDC).balanceOf(address(adapter)), amount);
        assertGe(
            capability.getHealthFactor(health.target, health.data),
            capability.minHealthFactor(keccak256(abi.encode(health.target, health.data)))
        );
        assertLe(
            lens.borrowCapability(address(adapter), POOL, USDC, keccak256(abi.encode(health.target, health.data))), 2
        );
    }

    function test_MainnetLensWithdrawalProtectsRemainingCollateral() public {
        ExecutorLiquidityLens lens = _lens();
        _manage(
            address(adapter),
            abi.encodeCall(
                IBorrowCapability.borrow,
                (
                    POOL,
                    health.target,
                    abi.encodeCall(IBorrowCapabilityAavePool.borrow, (USDC, BORROW_AMOUNT, 2, 0, address(adapter))),
                    health.data
                )
            )
        );
        uint256 amount = lens.aaveWithdraw(POOL, WETH, address(adapter));
        assertGt(amount, 0);
        assertLt(amount, 10e18);
        _manage(POOL, abi.encodeCall(ILensAaveWithdraw.withdraw, (WETH, amount, address(adapter))));
        assertEq(IERC20(WETH).balanceOf(address(adapter)), amount);
        assertGe(capability.getHealthFactor(health.target, health.data), 1e18);
    }

    function test_MainnetLensCheckedWithdrawalUsesCurrentCuratorFloor() public {
        ExecutorLiquidityLens lens = _lens();
        bytes32 healthFactorId = keccak256(abi.encode(health.target, health.data));
        _manage(
            address(adapter),
            abi.encodeCall(
                IBorrowCapability.borrow,
                (
                    POOL,
                    health.target,
                    abi.encodeCall(IBorrowCapabilityAavePool.borrow, (USDC, BORROW_AMOUNT, 2, 0, address(adapter))),
                    health.data
                )
            )
        );
        uint256 beforeCapacity = lens.withdrawCapability(address(adapter), POOL, WETH, healthFactorId);
        _setHealthFactor(healthFactorId, 2e18);
        uint256 amount = lens.withdrawCapability(address(adapter), POOL, WETH, healthFactorId);
        assertGt(amount, 0);
        assertLt(amount, beforeCapacity);
        _manage(
            address(adapter),
            abi.encodeCall(
                IBorrowCapability.borrow,
                (
                    POOL,
                    health.target,
                    abi.encodeCall(ILensAaveWithdraw.withdraw, (WETH, amount, address(adapter))),
                    health.data
                )
            )
        );
        assertEq(IERC20(WETH).balanceOf(address(adapter)), amount);
        assertGe(capability.getHealthFactor(health.target, health.data), 2e18);
    }

    function test_MainnetLensReadsChangedMinimumWithoutReconfiguringExecutorQuery() public {
        ExecutorLiquidityLens lens = _lens();
        uint256 beforeCapacity =
            lens.borrowCapability(address(adapter), POOL, USDC, keccak256(abi.encode(health.target, health.data)));
        _setHealthFactor(keccak256(abi.encode(health.target, health.data)), 2e18);
        uint256 afterCapacity =
            lens.borrowCapability(address(adapter), POOL, USDC, keccak256(abi.encode(health.target, health.data)));
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
        bytes32 healthFactorId = keccak256(abi.encode(morphoHealth.target, morphoHealth.data));
        _setHealthFactor(healthFactorId, 1.2e18);
        uint256 beforeCapacity = lens.morphoBorrowCapability(address(adapter), morpho, marketId, healthFactorId);
        _setHealthFactor(healthFactorId, 2e18);
        uint256 amount = lens.morphoBorrowCapability(address(adapter), morpho, marketId, healthFactorId);
        assertLt(amount, beforeCapacity);
        assertGt(amount, 8000e6);
        _manage(
            address(adapter),
            abi.encodeCall(
                IBorrowCapability.borrow,
                (
                    morpho,
                    morphoHealth.target,
                    abi.encodeCall(ILensRealMorpho.borrow, (params, amount, 0, address(adapter), address(adapter))),
                    morphoHealth.data
                )
            )
        );
        assertGe(capability.getHealthFactor(morphoHealth.target, morphoHealth.data), 2e18);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), amount);
        assertEq(lens.morphoBorrowCapability(address(adapter), morpho, marketId, healthFactorId), 0);
    }

    function test_MainnetLensDisablesBorrowingWhenHealthQueryIsUnset() public {
        ExecutorLiquidityLens lens = _lens();
        assertEq(lens.borrowCapability(address(adapter), POOL, USDC, bytes32(0)), 0);
    }

    function _lens() internal returns (ExecutorLiquidityLens) {
        return ExecutorLiquidityLens(
            IImmutableFactory(address(new ImmutableFactory(type(ExecutorLiquidityLens).creationCode))).create("")
        );
    }
}
