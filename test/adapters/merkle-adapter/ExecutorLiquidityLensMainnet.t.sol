// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ExecutorLiquidityLens} from "src/contracts/merkle-adapter/automations/ExecutorLiquidityLens.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {ILiquidityAaveV4Spoke} from "src/contracts/merkle-adapter/automations/liquidity/AaveV4Liquidity.sol";

import {IAaveV3Pool} from "src/interfaces/aave_v3_adapter/IAaveV3AdapterDependencies.sol";
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

interface ILensAaveV4Actions {
    function supply(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256, uint256);
    function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256, uint256);
}

contract ExecutorLiquidityLensMainnetTest is GuardedCallsMainnetTest {
    address internal constant MORPHO_VAULT = 0x5e577eFb2807D106e2A8BDDE3fC5FCFffFC9ec13;
    address internal constant AAVE_V4_SPOKE = 0x973a023A77420ba610f06b3858aD991Df6d85A08;

    /// @dev Only the initial WETH funding is synthetic; supply, share conversions and withdrawal use the live Spoke/Hub.
    function test_MainnetLensAaveV4WithdrawsSupplyWithoutDebt() public {
        address lens = address(_lens());
        (address asset,,,,,,) = ILiquidityAaveV4Spoke(AAVE_V4_SPOKE).getReserve(0);
        assertEq(asset, WETH);
        deal(WETH, account, 1e18);
        _manage(WETH, abi.encodeCall(IERC20.approve, (AAVE_V4_SPOKE, 1e18)));
        _manage(AAVE_V4_SPOKE, abi.encodeCall(ILensAaveV4Actions.supply, (0, 1e18, account)));
        assertEq(IERC20(WETH).balanceOf(account), 0);

        uint256 amount = ExecutorLiquidityLens(lens).aaveV4Withdraw(AAVE_V4_SPOKE, 0, account);
        assertGt(amount, 0);
        assertEq(amount, ILiquidityAaveV4Spoke(AAVE_V4_SPOKE).getUserSuppliedAssets(0, account));
        _manage(AAVE_V4_SPOKE, abi.encodeCall(ILensAaveV4Actions.withdraw, (0, amount, account)));
        assertEq(IERC20(WETH).balanceOf(account), amount);
        assertEq(ExecutorLiquidityLens(lens).aaveV4Withdraw(AAVE_V4_SPOKE, 0, account), 0);
    }

    function test_MainnetLensLiquidityWithdrawsSupplyWithoutDebt() public {
        address lens = address(_lens());
        uint256 amount = ExecutorLiquidityLens(lens).aaveWithdraw(POOL, WETH, account);
        assertGt(amount, 0);
        assertEq(amount, IERC20(IAaveV3Pool(POOL).getReserveAToken(WETH)).balanceOf(account));
        _manage(POOL, abi.encodeCall(ILensAaveWithdraw.withdraw, (WETH, amount, account)));
        assertEq(IERC20(WETH).balanceOf(account), amount);
        assertEq(ExecutorLiquidityLens(lens).aaveWithdraw(POOL, WETH, account), 0);
    }

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
        uint256 amount = lens.aaveWithdrawWithBorrow(POOL, WETH, account);
        assertGt(amount, 0);
        assertLt(amount, 10e18);
        assertGt(lens.aaveWithdraw(POOL, WETH, account), amount);
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
        uint256 amount = lens.aaveWithdrawWithBorrow(POOL, WETH, account);
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
