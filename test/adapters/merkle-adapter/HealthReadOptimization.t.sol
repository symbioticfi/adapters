// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {AaveHealthFactor} from "src/contracts/merkle-adapter/automations/health-factors/AaveHealthFactor.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {IAaveHealthPool} from "src/interfaces/merkle-adapter/automations/health-factors/IAaveHealthFactor.sol";
import {IAaveV3Pool} from "src/interfaces/aave_v3_adapter/IAaveV3AdapterDependencies.sol";
import {IRecipes, OP_LESS_OR_EQUAL} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";

interface IHealthReadAavePool {
    function borrow(address asset, uint256 amount, uint256 mode, uint16 referralCode, address onBehalfOf) external;
}

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";

abstract contract HealthReadOptimizationBase is Test {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    address internal _executor;
    address internal _health;

    function _initialize() internal {
        _executor = address(new RecipeExecutor(address(this), address(this)));
        RecipeExecutor(_executor).setCaller(address(this));
        _health = address(new AaveHealthFactor());
    }

    function _recipe(address pool, uint216 minimum, bool direct, uint256 count)
        internal
        view
        returns (ExecutingRecipe.Recipe memory)
    {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        ExecutingRecipe.Read memory query = direct
            ? ExecutingRecipe.Read({
                target: pool, data: abi.encodeCall(IAaveHealthPool.getUserAccountData, (address(this))), offset: 160
            })
            : ExecutingRecipe.Read({
                target: _health,
                data: abi.encodeCall(AaveHealthFactor.getHealthFactor, (pool, address(this))),
                offset: 0
            });
        for (uint256 i; i < count; ++i) {
            builder.check(OP_LESS_OR_EQUAL, minimum, builder.read(query));
        }
        return builder.finish();
    }

    function _run(ExecutingRecipe.Recipe memory recipe) internal returns (uint256[] memory) {
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        return RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
    }

    function _assertRejected(ExecutingRecipe.Recipe memory recipe) internal {
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
    }
}

contract HealthReadOptimizationTest is HealthReadOptimizationBase {
    address internal constant POOL = address(0xaa7e);

    function setUp() public {
        _initialize();
    }

    function testFuzz_DirectHealthWordPreservesFullWidth(uint256 health, uint216 minimum) public {
        vm.mockCall(
            POOL,
            abi.encodeCall(IAaveHealthPool.getUserAccountData, (address(this))),
            abi.encode(11, 22, 33, 44, 55, health)
        );
        ExecutingRecipe.Recipe memory direct = _recipe(POOL, minimum, true, 1);
        ExecutingRecipe.Recipe memory wrapped = _recipe(POOL, minimum, false, 1);
        if (health >= minimum) {
            uint256[] memory actual = _run(direct);
            uint256[] memory expected = _run(wrapped);
            assertEq(actual, expected);
            assertEq(actual[0], health);
        } else {
            _assertRejected(direct);
            _assertRejected(wrapped);
        }
    }

    function test_ZeroDebtMaximumHealthIsNotTruncated() public {
        vm.mockCall(
            POOL,
            abi.encodeCall(IAaveHealthPool.getUserAccountData, (address(this))),
            abi.encode(11, 0, 33, 44, 55, type(uint256).max)
        );
        uint256[] memory direct = _run(_recipe(POOL, type(uint216).max, true, 1));
        uint256[] memory wrapped = _run(_recipe(POOL, type(uint216).max, false, 1));
        assertEq(direct, wrapped);
        assertEq(direct[0], type(uint256).max);
    }

    function test_ThresholdBoundaryPassesAndOneUnitAboveFails() public {
        vm.mockCall(
            POOL,
            abi.encodeCall(IAaveHealthPool.getUserAccountData, (address(this))),
            abi.encode(11, 22, 33, 44, 55, 1.2e18)
        );
        assertEq(_run(_recipe(POOL, 1.2e18, true, 1)), _run(_recipe(POOL, 1.2e18, false, 1)));
        _assertRejected(_recipe(POOL, 1.2e18 + 1, true, 1));
        _assertRejected(_recipe(POOL, 1.2e18 + 1, false, 1));
    }
}

contract HealthReadOptimizationMainnetTest is HealthReadOptimizationBase {
    address internal constant POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 25_892_000);
        _initialize();
        // Only starting collateral is synthetic; lending and health calculations use the actual Pool.
        deal(WETH, address(this), 10e18);
        IERC20(WETH).approve(POOL, 10e18);
        IAaveV3Pool(POOL).supply(WETH, 10e18, address(this), 0);
    }

    function test_MainnetZeroDebtHealthRemainsFullWidth() public {
        uint256[] memory direct = _run(_recipe(POOL, type(uint216).max, true, 1));
        uint256[] memory wrapped = _run(_recipe(POOL, type(uint216).max, false, 1));
        assertEq(direct, wrapped);
        assertEq(direct[0], type(uint256).max);
    }

    /// forge-config: default.isolate = true
    function test_MainnetDirectHealthReducesFourReadExecutionGas() public {
        IHealthReadAavePool(POOL).borrow(USDC, 1000e6, 2, 0, address(this));
        (,,,,, uint256 health) = IAaveHealthPool(POOL).getUserAccountData(address(this));
        assertGe(health, 1e18);
        assertLe(health, type(uint216).max);
        ExecutingRecipe.Recipe memory wrapped = _recipe(POOL, uint216(health), false, 4);
        ExecutingRecipe.Recipe memory direct = _recipe(POOL, uint216(health), true, 4);
        uint256[] memory expected = _run(wrapped);
        uint256 wrappedGas = vm.snapshotGasLastCall("HealthReadOptimizationMainnet", "four_wrapped_reads");
        uint256[] memory actual = _run(direct);
        uint256 directGas = vm.snapshotGasLastCall("HealthReadOptimizationMainnet", "four_direct_reads");
        assertEq(actual, expected);
        for (uint256 i; i < actual.length; i += 2) {
            assertEq(actual[i], health);
        }
        assertLt(directGas, wrappedGas);
        _assertRejected(_recipe(POOL, uint216(health) + 1, true, 1));
        _assertRejected(_recipe(POOL, uint216(health) + 1, false, 1));
        emit log_named_uint("Four wrapped health reads through execute", wrappedGas);
        emit log_named_uint("Four direct health reads through execute", directGas);
    }
}
