// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {AaveV3Liquidity} from "src/contracts/merkle-adapter/automations/liquidity/AaveV3Liquidity.sol";
import {AaveV4Liquidity} from "src/contracts/merkle-adapter/automations/liquidity/AaveV4Liquidity.sol";
import {ILiquidityAaveV4Spoke} from "src/contracts/merkle-adapter/automations/liquidity/AaveV4Liquidity.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {MorphoLiquidity} from "src/contracts/merkle-adapter/automations/liquidity/MorphoLiquidity.sol";

import {IAaveV3Pool} from "src/interfaces/aave_v3_adapter/IAaveV3AdapterDependencies.sol";
import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {RecipeMainnetTest, IRecipeCapabilityAavePool} from "test/adapters/merkle-adapter/RecipeMainnet.t.sol";

interface ILensAaveWithdraw {
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface ILensAaveV4Actions {
    function supply(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256, uint256);
    function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256, uint256);
}

contract LiquiditySourcesMainnetTest is RecipeMainnetTest {
    address internal constant MORPHO_VAULT = 0x5e577eFb2807D106e2A8BDDE3fC5FCFffFC9ec13;
    address internal constant AAVE_V4_SPOKE = 0x973a023A77420ba610f06b3858aD991Df6d85A08;

    /// @dev Only the initial WETH funding is synthetic; supply, share conversions and withdrawal use the live Spoke/Hub.
    function test_MainnetAaveV4LiquidityWithdrawsSupplyWithoutDebt() public {
        AaveV4Liquidity aaveV4 = _aaveV4();
        (address asset,,,,,,) = ILiquidityAaveV4Spoke(AAVE_V4_SPOKE).getReserve(0);
        assertEq(asset, WETH);
        deal(WETH, account, 1e18);
        _manage(WETH, abi.encodeCall(IERC20.approve, (AAVE_V4_SPOKE, 1e18)));
        _manage(AAVE_V4_SPOKE, abi.encodeCall(ILensAaveV4Actions.supply, (0, 1e18, account)));
        assertEq(IERC20(WETH).balanceOf(account), 0);

        uint256 amount = aaveV4.liquidity(AAVE_V4_SPOKE, 0, account);
        assertGt(amount, 0);
        assertEq(amount, ILiquidityAaveV4Spoke(AAVE_V4_SPOKE).getUserSuppliedAssets(0, account));
        _manage(AAVE_V4_SPOKE, abi.encodeCall(ILensAaveV4Actions.withdraw, (0, amount, account)));
        assertEq(IERC20(WETH).balanceOf(account), amount);
        assertEq(aaveV4.liquidity(AAVE_V4_SPOKE, 0, account), 0);
    }

    function test_MainnetAaveV3LiquidityWithdrawsSupplyWithoutDebt() public {
        AaveV3Liquidity aaveV3 = _aaveV3();
        uint256 amount = aaveV3.liquidity(POOL, WETH, account);
        assertGt(amount, 0);
        assertEq(amount, IERC20(IAaveV3Pool(POOL).getReserveAToken(WETH)).balanceOf(account));
        _manage(POOL, abi.encodeCall(ILensAaveWithdraw.withdraw, (WETH, amount, account)));
        assertEq(IERC20(WETH).balanceOf(account), amount);
        assertEq(aaveV3.liquidity(POOL, WETH, account), 0);
    }

    function test_MainnetAaveV3WithdrawalProtectsRemainingCollateral() public {
        AaveV3Liquidity aaveV3 = _aaveV3();
        _manage(
            account,
            _checkedCallData(
                POOL,
                health.target,
                abi.encodeCall(IRecipeCapabilityAavePool.borrow, (USDC, BORROW_AMOUNT, 2, 0, account)),
                health.data
            )
        );
        uint256 amount = aaveV3.liquidityWithBorrow(POOL, WETH, account);
        assertGt(amount, 0);
        assertLt(amount, 10e18);
        assertGt(aaveV3.liquidity(POOL, WETH, account), amount);
        _manage(POOL, abi.encodeCall(ILensAaveWithdraw.withdraw, (WETH, amount, account)));
        assertEq(IERC20(WETH).balanceOf(account), amount);
        assertGe(_healthValue(health.target, health.data), 1e18);
    }

    function test_MainnetAaveV3MixedCollateralWithdrawalPreservesSolvency() public {
        AaveV3Liquidity aaveV3 = _aaveV3();
        deal(USDC, account, 10_000e6);
        _manage(USDC, abi.encodeCall(IERC20.approve, (POOL, 10_000e6)));
        _manage(POOL, abi.encodeCall(IRecipeCapabilityAavePool.supply, (USDC, 10_000e6, account, 0)));
        _manage(
            account,
            _checkedCallData(
                POOL,
                health.target,
                abi.encodeCall(IRecipeCapabilityAavePool.borrow, (USDC, 10_003e6, 2, 0, account)),
                health.data
            )
        );
        uint256 amount = aaveV3.liquidityWithBorrow(POOL, WETH, account);
        assertGt(amount, 0);
        assertLt(amount, 10e18);
        _manage(POOL, abi.encodeCall(ILensAaveWithdraw.withdraw, (WETH, amount, account)));
        assertEq(IERC20(WETH).balanceOf(account), amount);
        assertGe(_healthValue(health.target, health.data), 1e18);
    }

    /// @dev Only the initial USDC funding is synthetic. Shares, adapter exits and transfers use the pinned vault.
    function test_MainnetMorphoVaultAmountWithdrawsThroughConfiguredExit() public {
        MorphoLiquidity morpho = _morpho();
        assertEq(IERC4626(MORPHO_VAULT).asset(), USDC);
        uint256 funded = 1000e6;
        deal(USDC, account, funded);
        _manage(USDC, abi.encodeCall(IERC20.approve, (MORPHO_VAULT, funded)));
        _manage(MORPHO_VAULT, abi.encodeCall(IERC4626.deposit, (funded, account)));
        assertEq(IERC20(USDC).balanceOf(account), 0);
        assertGt(IERC20(MORPHO_VAULT).balanceOf(account), 0);

        uint256 capacity = morpho.liquidity(MORPHO_VAULT, account);
        assertGt(capacity, funded - 100);
        assertLe(capacity, funded);
        assertEq(IERC4626(MORPHO_VAULT).maxWithdraw(account), 0);
        _manage(MORPHO_VAULT, abi.encodeCall(IERC4626.withdraw, (capacity, account, account)));
        assertEq(IERC20(USDC).balanceOf(account), capacity);
        assertLe(morpho.liquidity(MORPHO_VAULT, account), 1);
        assertEq(IERC20(USDC).balanceOf(address(morpho)), 0);
    }

    function _aaveV3() internal returns (AaveV3Liquidity) {
        return AaveV3Liquidity(
            IImmutableFactory(address(new ImmutableFactory(type(AaveV3Liquidity).creationCode))).create("")
        );
    }

    function _aaveV4() internal returns (AaveV4Liquidity) {
        return AaveV4Liquidity(
            IImmutableFactory(address(new ImmutableFactory(type(AaveV4Liquidity).creationCode))).create("")
        );
    }

    function _morpho() internal returns (MorphoLiquidity) {
        return MorphoLiquidity(
            IImmutableFactory(address(new ImmutableFactory(type(MorphoLiquidity).creationCode))).create("")
        );
    }
}
