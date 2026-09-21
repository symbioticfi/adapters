// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ExecutorLiquidityLens} from "src/contracts/merkle-adapter/automations/ExecutorLiquidityLens.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";

import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {
    GuardedCallsMainnetTest,
    IGuardedCallsCapabilityAavePool
} from "test/adapters/merkle-adapter/GuardedCallsMainnet.t.sol";

interface ILensAaveWithdraw {
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

contract ExecutorLiquidityLensMainnetTest is GuardedCallsMainnetTest {
    address internal constant MORPHO_VAULT = 0x5e577eFb2807D106e2A8BDDE3fC5FCFffFC9ec13;

    function test_MainnetLensWithdrawalProtectsRemainingCollateral() public {
        ExecutorLiquidityLens lens = _lens();
        _manage(
            account,
            _guardedData(
                POOL,
                health.target,
                abi.encodeCall(IGuardedCallsCapabilityAavePool.borrow, (USDC, BORROW_AMOUNT, 2, 0, account)),
                health.data
            )
        );
        uint256 amount = lens.aaveWithdraw(POOL, WETH, account);
        assertGt(amount, 0);
        assertLt(amount, 10e18);
        _manage(POOL, abi.encodeCall(ILensAaveWithdraw.withdraw, (WETH, amount, account)));
        assertEq(IERC20(WETH).balanceOf(account), amount);
        assertGe(_healthValue(health.target, health.data), 1e18);
    }

    function test_MainnetLensMixedCollateralWithdrawalPreservesSolvency() public {
        ExecutorLiquidityLens lens = _lens();
        deal(USDC, account, 10_000e6);
        _manage(USDC, abi.encodeCall(IERC20.approve, (POOL, 10_000e6)));
        _manage(POOL, abi.encodeCall(IGuardedCallsCapabilityAavePool.supply, (USDC, 10_000e6, account, 0)));
        _manage(
            account,
            _guardedData(
                POOL,
                health.target,
                abi.encodeCall(IGuardedCallsCapabilityAavePool.borrow, (USDC, 10_003e6, 2, 0, account)),
                health.data
            )
        );
        uint256 amount = lens.aaveWithdraw(POOL, WETH, account);
        assertGt(amount, 0);
        assertLt(amount, 10e18);
        _manage(POOL, abi.encodeCall(ILensAaveWithdraw.withdraw, (WETH, amount, account)));
        assertEq(IERC20(WETH).balanceOf(account), amount);
        assertGe(_healthValue(health.target, health.data), 1e18);
    }

    /// @dev Only the initial USDC funding is synthetic. Shares, adapter exits and transfers use the pinned vault.
    function test_MainnetMorphoVaultLensAmountWithdrawsThroughConfiguredExit() public {
        ExecutorLiquidityLens lens = _lens();
        assertEq(IERC4626(MORPHO_VAULT).asset(), USDC);
        uint256 funded = 1000e6;
        deal(USDC, account, funded);
        _manage(USDC, abi.encodeCall(IERC20.approve, (MORPHO_VAULT, funded)));
        _manage(MORPHO_VAULT, abi.encodeCall(IERC4626.deposit, (funded, account)));
        assertEq(IERC20(USDC).balanceOf(account), 0);
        assertGt(IERC20(MORPHO_VAULT).balanceOf(account), 0);

        uint256 capacity = lens.morphoVaultWithdraw(MORPHO_VAULT, account);
        assertGt(capacity, funded - 100);
        assertLe(capacity, funded);
        assertEq(IERC4626(MORPHO_VAULT).maxWithdraw(account), 0);
        _manage(MORPHO_VAULT, abi.encodeCall(IERC4626.withdraw, (capacity, account, account)));
        assertEq(IERC20(USDC).balanceOf(account), capacity);
        assertLe(lens.morphoVaultWithdraw(MORPHO_VAULT, account), 1);
        assertEq(IERC20(USDC).balanceOf(address(lens)), 0);
    }

    function _lens() internal returns (ExecutorLiquidityLens) {
        return ExecutorLiquidityLens(
            IImmutableFactory(address(new ImmutableFactory(type(ExecutorLiquidityLens).creationCode))).create("")
        );
    }
}
