// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ExecutorLiquidityLens} from "src/contracts/merkle-adapter/automations/ExecutorLiquidityLens.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";

import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    GuardedCallsMainnetTest,
    IGuardedCallsCapabilityAavePool
} from "test/adapters/merkle-adapter/GuardedCallsMainnet.t.sol";

interface ILensAaveWithdraw {
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

contract ExecutorLiquidityLensMainnetTest is GuardedCallsMainnetTest {
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

    function _lens() internal returns (ExecutorLiquidityLens) {
        return ExecutorLiquidityLens(
            IImmutableFactory(address(new ImmutableFactory(type(ExecutorLiquidityLens).creationCode))).create("")
        );
    }
}
