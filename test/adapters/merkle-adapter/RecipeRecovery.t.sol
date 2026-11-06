// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {IRecipes, OP_LESS_OR_EQUAL, OP_MUL_DIV, OP_READ} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {RecoveryRecipe} from "script/recipes/RecoveryRecipe.sol";

/// @dev Real Merkle routing and executor, with explicitly local protocol-effects fixtures and no RPC.
/// Asset amounts use six decimals; RWA amounts use eighteen, so the token/asset WAD rate is 1e30.
contract RecipeRecoveryTest is CapabilityTestBase {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    bytes internal _recipe;

    address internal _asset;
    address internal _morpho;
    address internal _aave;
    address internal _issuerA;
    address internal _issuerB;
    address internal _rwaA;
    address internal _rwaB;
    address internal _executor;
    address internal _trace;
    RecoveryRecipe.Config internal _config;
    IMerkleAccount.Action[] internal _actions;

    uint256 internal _initialCash = 17e6;

    modifier withoutCash() {
        RecoveryTokenMock(_asset).burn(account, _initialCash);
        _initialCash = 0;
        _;
    }

    function setUp() public {
        _asset = address(new RecoveryTokenMock("USDC", 6));
        _rwaA = address(new RecoveryTokenMock("RWA-A", 18));
        _rwaB = address(new RecoveryTokenMock("RWA-B", 18));
        _trace = address(new RecoveryTraceMock());
        _aave = address(new RecoveryAaveMock(_asset, _trace));
        _morpho = address(new RecoveryMorphoVaultMock(_asset, _trace));
        _issuerA = address(new RecoveryIssuerMock(_asset, _rwaA, _trace, 3));
        _issuerB = address(new RecoveryIssuerMock(_asset, _rwaB, _trace, 4));
        _deployAdapter(_asset);
        _executor = new ImmutableFactory(type(RecipeExecutor).creationCode).create(abi.encode(address(this), account));
        RecipeExecutor(_executor).setCaller(address(this));
        _configurePermissions();
        _configureRecipe();
        RecoveryAaveMock(_aave).setPosition(300e6, 300e6);
        RecoveryMorphoVaultMock(_morpho).setCapacity(30e6);
        RecoveryAaveMock(_aave).setCapacity(20e6);
        RecoveryIssuerMock(_issuerA).setCapacity(40e6);
        RecoveryIssuerMock(_issuerB).setCapacity(100e6);
        RecoveryTokenMock(_asset).mint(account, 17e6);
        RecoveryTokenMock(_asset).mint(_morpho, 1000e6);
        RecoveryTokenMock(_asset).mint(_aave, 1000e6);
        RecoveryTokenMock(_asset).mint(_issuerA, 1000e6);
        RecoveryTokenMock(_asset).mint(_issuerB, 1000e6);
        RecoveryTokenMock(_rwaA).mint(account, 1000e18);
        RecoveryTokenMock(_rwaB).mint(account, 1000e18);
    }

    function test_RecoveryBindsComputedRequestAmountsDespiteWrongRuntime() public withoutCash {
        _recover(30e6, 20e6, 1, 1, 50e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 10e6);
    }

    /// forge-config: default.isolate = true
    function test_GasCashRepay() public {
        bytes[] memory runtime = _repayRuntime(17e6);
        (bytes[] memory queries, bytes[] memory steps) = abi.decode(_recipe, (bytes[], bytes[]));
        uint256[] memory inputs = new uint256[](0);
        RecipeExecutor(_executor).execute(queries, steps, inputs, runtime);
        vm.snapshotGasLastCall("RecipeRecovery", "cashRepay");
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(RecoveryAaveMock(_aave).debt(account), 283e6);
        assertEq(IERC20(_asset).balanceOf(_aave), 1017e6);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
        assertEq(RecoveryTraceMock(_trace).count(), 1);
        assertEq(RecoveryTraceMock(_trace).calls(0), 5);
    }

    function testFuzz_FullWidthCash(uint256 cash) public {
        _emptyAsset();
        RecoveryTokenMock(_asset).mint(account, cash);
        uint256 amount = cash;
        if (amount > 100e6) amount = 100e6;
        _expectRepay(amount, true, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
        assertEq(IERC20(_asset).balanceOf(account), cash - amount);
    }

    function test_RepaymentCallbackBarrier() public {
        _effectsCase(6);
    }

    function _effectsCase(uint256 effect) internal {
        _rebindEffects();
        uint256 selected = effect;
        RecoveryEffectTokenMock(_asset).setEffects(account, _aave, _executor, selected);
        bytes memory expected = selected == 6
            ? abi.encodeWithSignature("ReentrancyGuardReentrantCall()")
            : abi.encodeWithSelector(IRecipes.CheckFailed.selector);
        _config.maxRepayment = 16e6;
        _expectRepay(16e6, false, expected);
        assertEq(RecoveryEffectTokenMock(_asset).effectCount(), 0, "repay effects rolled back");
    }

    function _expectRepay(uint256 amount, bool succeeds, bytes memory errorData) internal {
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.repay(_config);
        _assertExecution(
            recipe,
            layout,
            _baseRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, amount),
            succeeds,
            errorData
        );
    }

    function _assertExecution(
        ExecutingRecipe.Recipe memory recipe,
        RecoveryRecipe.Layout memory layout,
        bytes[] memory runtime,
        bool succeeds,
        bytes memory errorData
    ) internal {
        assertEq(layout.clearApproval, runtime.length - 1);
        bytes32 initial = _effectsHash();
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        (bool ok, bytes memory result) = _executor.call(
            abi.encodeCall(RecipeExecutor.execute, (recipe.queries, recipe.steps, new uint256[](0), runtime))
        );
        assertEq(ok, succeeds);
        if (!ok) {
            assertEq(result, errorData);
            assertEq(_effectsHash(), initial, "failed execution must roll back");
        }
    }

    function _effectsHash() internal view returns (bytes32) {
        uint256 count = RecoveryTraceMock(_trace).count();
        uint256[] memory trace = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            trace[i] = RecoveryTraceMock(_trace).calls(i);
        }
        return keccak256(
            abi.encode(
                IERC20(_asset).balanceOf(account),
                IERC20(_asset).balanceOf(_aave),
                IERC20(_asset).balanceOf(_issuerA),
                IERC20(_asset).balanceOf(_issuerB),
                IERC20(_asset).totalSupply(),
                RecoveryAaveMock(_aave).debt(account),
                RecoveryAaveMock(_aave).healthFactor(account),
                RecoveryIssuerMock(_issuerA).pending(account),
                RecoveryIssuerMock(_issuerB).pending(account),
                RecoveryIssuerMock(_issuerA).claimable(account),
                RecoveryIssuerMock(_issuerB).claimable(account),
                IERC20(_asset).allowance(account, _aave),
                trace
            )
        );
    }

    function _emptyAsset() internal {
        address[5] memory holders = [account, _morpho, _aave, _issuerA, _issuerB];
        for (uint256 i; i < holders.length; ++i) {
            RecoveryTokenMock(_asset).burn(holders[i], IERC20(_asset).balanceOf(holders[i]));
        }
    }

    function _rebindEffects() internal {
        _asset = address(new RecoveryEffectTokenMock());
        _aave = address(new RecoveryAaveMock(_asset, _trace));
        _morpho = address(new RecoveryMorphoVaultMock(_asset, _trace));
        _issuerA = address(new RecoveryIssuerMock(_asset, _rwaA, _trace, 3));
        _issuerB = address(new RecoveryIssuerMock(_asset, _rwaB, _trace, 4));
        delete _actions;
        delete _config;
        _configurePermissions();
        _configureRecipe();
        RecoveryAaveMock(_aave).setPosition(300e6, 300e6);
        RecoveryTokenMock(_asset).mint(account, 17e6);
        RecoveryTokenMock(_asset).mint(_issuerA, 1000e6);
    }

    function testFuzz_O05SemanticTriggerBoundaries(uint8 boundary) public withoutCash {
        uint256[4] memory collateral = [uint256(0), 600e6, 750e6, 750e6 + 1];
        uint256 selected = boundary % 4;
        RecoveryAaveMock(_aave).setPosition(600e6, collateral[selected]);
        if (selected == 3) {
            (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) =
                RecoveryRecipe.recovery(_config);
            bytes[] memory runtime =
                _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 30e6, 20e6, 40e6, 10e6, 50e6);
            vm.expectRevert(IRecipes.CheckFailed.selector);
            _execute(runtime);
            assertEq(RecoveryAaveMock(_aave).debt(account), 600e6);
            assertEq(RecoveryTraceMock(_trace).count(), 0);
        } else {
            _recover(30e6, 20e6, 40e6, 10e6, 50e6);
            assertEq(RecoveryAaveMock(_aave).debt(account), 550e6);
            assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
            assertEq(RecoveryIssuerMock(_issuerB).pending(account), 10e6);
        }
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
        assertEq(IERC20(_rwaA).allowance(account, _issuerA), 0);
        assertEq(IERC20(_rwaB).allowance(account, _issuerB), 0);
    }

    function test_O05SemanticLaterHealthAboveTargetStaysClamped() public {
        _config.targetHealthFactor = _config.triggerHealthFactor + 1;
        RecoveryAaveMock(_aave).setPosition(600e6, 750e6);
        _recover(1, 0, 0, 0, 1);
        assertEq(RecoveryAaveMock(_aave).debt(account), 600e6 - 1);
        assertGt(RecoveryAaveMock(_aave).healthFactor(account), _config.targetHealthFactor);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
        assertEq(IERC20(_asset).balanceOf(account), 17e6 - 1);
    }

    function testFuzz_O05SemanticInvalidTargetRejects(uint256 reduction) public {
        _config.targetHealthFactor = _config.triggerHealthFactor - bound(reduction, 0, _config.triggerHealthFactor);
        vm.expectRevert(RecoveryRecipe.InvalidConfiguration.selector);
        this.buildRecoveryO05(_config);
    }

    function test_O05SemanticZeroDebtRecoveryRejectsBeforeArithmetic() public {
        RecoveryAaveMock(_aave).setPosition(0, 300e6);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime = _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 0, 0, 0, 0, 0);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(RecoveryTraceMock(_trace).count(), 0);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
    }

    function testFuzz_O05SemanticFullWidthDebtAndCheckedOverflow(uint256 debtAmount, uint256 health) public {
        health = bound(health, 0, _config.triggerHealthFactor);
        (bool success, bytes memory response) = _prefixO05(debtAmount, health);
        if (health > 0 && debtAmount > type(uint256).max / health) {
            assertFalse(success);
            assertEq(response, abi.encodeWithSignature("Panic(uint256)", 0x11));
        } else {
            assertTrue(success);
            uint256[] memory values = abi.decode(response, (uint256[]));
            uint256 need = debtAmount - debtAmount * health / _config.targetHealthFactor;
            assertEq(values[values.length - 1], need < 100e6 ? need : 100e6);
        }
    }

    function test_O05SemanticExtremeHealthRejectsBeforeOverflow() public {
        (bool success, bytes memory response) = _prefixO05(type(uint256).max, type(uint256).max);
        assertFalse(success);
        assertEq(response, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
    }

    function test_O05SemanticZeroHealthSupportsMaximumDebt() public {
        (bool success, bytes memory response) = _prefixO05(type(uint256).max, 0);
        assertTrue(success);
        uint256[] memory values = abi.decode(response, (uint256[]));
        assertEq(values[values.length - 1], 100e6);
        (success, response) = _prefixO05(0, 0);
        assertTrue(success);
        values = abi.decode(response, (uint256[]));
        assertEq(values[values.length - 1], 0);
    }

    /// forge-config: default.isolate = true
    function test_RecoveryWithdrawsMorphoThenAaveRepaysThenRequestsInOrder() public withoutCash {
        _recover(30e6, 20e6, 40e6, 10e6, 50e6);
        vm.snapshotGasLastCall("RecipeRecovery", "recovery");

        assertEq(RecoveryAaveMock(_aave).debt(account), 250e6);
        assertEq(RecoveryAaveMock(_aave).healthFactor(account), 1.2e18);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 10e6);
        assertEq(IERC20(_rwaA).balanceOf(account), 960e18);
        assertEq(IERC20(_rwaB).balanceOf(account), 990e18);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
        assertEq(IERC20(_rwaA).allowance(account, _issuerA), 0);
        assertEq(RecoveryTraceMock(_trace).count(), 5);
        assertEq(RecoveryTraceMock(_trace).calls(0), 1);
        assertEq(RecoveryTraceMock(_trace).calls(1), 2);
        assertEq(RecoveryTraceMock(_trace).calls(2), 5);
        assertEq(RecoveryTraceMock(_trace).calls(3), 3);
        assertEq(RecoveryTraceMock(_trace).calls(4), 4);
    }

    function test_RecoverySpendsHeldCashBeforeSources() public {
        _recover(30e6, 20e6, 33e6, 0, 67e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 233e6);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(RecoveryMorphoVaultMock(_morpho).maxWithdraw(account), 0);
        assertEq(RecoveryAaveMock(_aave).capacity(account), 0);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 33e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 0);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
    }

    function test_HeldCashCoveringBudgetSkipsSourcesAndRequests() public {
        RecoveryTokenMock(_asset).mint(account, 100e6);
        _recover(30e6, 20e6, 40e6, 10e6, 100e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(RecoveryMorphoVaultMock(_morpho).maxWithdraw(account), 30e6);
        assertEq(RecoveryAaveMock(_aave).capacity(account), 20e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 0);
        assertEq(RecoveryTraceMock(_trace).count(), 1);
    }

    function test_RecoveryChecksTriggerBeforeOtherReads() public view {
        (ExecutingRecipe.Recipe memory recipe,) = RecoveryRecipe.recovery(_config);
        assertEq(uint8(recipe.steps[0][0]), OP_READ);
        assertEq(uint8(recipe.steps[1][0]), OP_LESS_OR_EQUAL);
    }

    function test_FullyFundedFirstSourceSkipsEveryLaterSourceAndRequest() public {
        RecoveryMorphoVaultMock(_morpho).setCapacity(200e6);
        _recover(100e6, 999e6, 999e6, 999e6, 100e6);
        assertEq(RecoveryTraceMock(_trace).count(), 2);
        assertEq(RecoveryAaveMock(_aave).capacity(account), 20e6);
        assertEq(RecoveryAaveMock(_aave).healthFactor(account), 1.5e18);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 0);
    }

    function test_RecoveryRequiresReadableSourceAndIssuerQueries() public {
        RecoveryMorphoVaultMock(_morpho).setCapacity(200e6);
        vm.mockCallRevert(_aave, abi.encodeCall(RecoveryAaveMock.capacity, (account)), hex"deadbeef");
        vm.mockCallRevert(_issuerA, abi.encodeWithSignature("pending(address)", account), hex"deadbeef");
        vm.mockCallRevert(_issuerB, abi.encodeWithSignature("pending(address)", account), hex"deadbeef");
        vm.mockCallRevert(_issuerA, abi.encodeCall(RecoveryIssuerMock.capacity, (account)), hex"deadbeef");
        vm.mockCallRevert(_issuerB, abi.encodeCall(RecoveryIssuerMock.capacity, (account)), hex"deadbeef");
        vm.mockCallRevert(_rwaA, abi.encodeCall(IERC20.balanceOf, (account)), hex"deadbeef");
        vm.mockCallRevert(_rwaB, abi.encodeCall(IERC20.balanceOf, (account)), hex"deadbeef");
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 100e6, 0, 0, 0, 100e6);
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(bytes4(0xdeadbeef));
        RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](0), runtime);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6);
        assertEq(RecoveryAaveMock(_aave).healthFactor(account), 1e18);
        assertEq(RecoveryTraceMock(_trace).count(), 0);
    }

    function test_RecoveryLeavesUnrelatedIssuerAllowanceUnchanged() public {
        RecoveryMorphoVaultMock(_morpho).setCapacity(200e6);
        vm.prank(account);
        IERC20(_rwaA).approve(_issuerA, 1);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 100e6, 0, 0, 0, 100e6);
        _execute(runtime);
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6);
        assertEq(IERC20(_rwaA).allowance(account, _issuerA), 1);
    }

    function test_RecoveryStillCountsLowerPriorityPending() public withoutCash {
        RecoveryMorphoVaultMock(_morpho).setCapacity(0);
        RecoveryAaveMock(_aave).setCapacity(0);
        RecoveryIssuerMock(_issuerB).seedPending(account, 60e6);
        _recover(0, 0, 40e6, 0, 0);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 60e6);
    }

    function test_RecoveryPreservesPartialProgress() public withoutCash {
        RecoveryIssuerMock(_issuerA).setCapacity(0);
        RecoveryIssuerMock(_issuerB).setCapacity(0);
        _recover(30e6, 20e6, 0, 0, 50e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 250e6);
        assertEq(RecoveryAaveMock(_aave).healthFactor(account), 1.2e18);
        assertEq(IERC20(_asset).balanceOf(account), 0);
    }

    /// forge-config: default.isolate = true
    function test_GasO01TwoActiveSources() public withoutCash {
        _recover(30e6, 20e6, 40e6, 10e6, 50e6);
        vm.snapshotGasLastCall("RecipeRecovery", "O01TwoActiveSources");
        assertEq(RecoveryAaveMock(_aave).debt(account), 250e6);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 10e6);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
        assertEq(RecoveryTraceMock(_trace).calls(0), 1);
        assertEq(RecoveryTraceMock(_trace).calls(1), 2);
        assertEq(RecoveryTraceMock(_trace).calls(2), 5);
    }

    /// forge-config: default.isolate = true
    function test_GasO01OneActiveGroup() public withoutCash {
        RecoveryMorphoVaultMock(_morpho).setCapacity(100e6);
        _recover(100e6, 0, 0, 0, 100e6);
        vm.snapshotGasLastCall("RecipeRecovery", "O01OneActiveGroup");
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
        assertEq(RecoveryTraceMock(_trace).count(), 2);
    }

    function testFuzz_O01FullRecoverySpendsCashBeforeSources(uint256 first, uint256 second) public {
        first = bound(first, 0, 50e6);
        second = bound(second, 0, 50e6);
        RecoveryMorphoVaultMock(_morpho).setCapacity(first);
        RecoveryAaveMock(_aave).setCapacity(second);
        second = second < 83e6 - first ? second : 83e6 - first;
        RecoveryAaveMock(_aave).setCapacity(second);
        uint256 funded = 17e6 + first + second;
        uint256 gap = 100e6 - funded;
        uint256 requestA = gap < 40e6 ? gap : 40e6;
        _recover(first, second, requestA, gap - requestA, funded);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6 - funded);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), requestA);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), gap - requestA);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
        assertEq(IERC20(_rwaA).allowance(account, _issuerA), 0);
        assertEq(IERC20(_rwaB).allowance(account, _issuerB), 0);
    }

    function test_O01ConditionalShortSourceStillRollsBack() public {
        RecoveryMorphoVaultMock(_morpho).setShortfall(1);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 30e6, 20e6, 40e6, 10e6, 50e6);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", account, 67e6 - 1, 67e6)
        );
        _execute(runtime);
        _assertPristine();
    }

    function test_ZeroCapacitySourceSkipsItsUndecodableRuntime() public {
        RecoveryMorphoVaultMock(_morpho).setCapacity(0);
        RecoveryAaveMock(_aave).setCapacity(100e6);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 0, 100e6, 0, 0, 100e6);
        runtime[layout.sourceCalls[0]] = hex"deadbeef";
        _execute(runtime);
        assertEq(RecoveryTraceMock(_trace).calls(0), 2);
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6);
    }

    function test_AboveTriggerRejectsEvenWhenTargetStillNeedsRecovery() public {
        RecoveryAaveMock(_aave).setPosition(300e6, 375e6 + 1);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 30e6, 20e6, 0, 0, 50e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(RecoveryTraceMock(_trace).count(), 0);
    }

    function test_ExactTriggerBoundaryIsEligible() public {
        RecoveryAaveMock(_aave).setPosition(600e6, 750e6);
        RecoveryMorphoVaultMock(_morpho).setCapacity(100e6);
        _recover(100e6, 0, 0, 0, 100e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 500e6);
        assertEq(RecoveryAaveMock(_aave).healthFactor(account), 1.5e18);
    }

    function test_ExistingLowerPriorityPendingIsCountedBeforeAnyNewRequest() public withoutCash {
        RecoveryMorphoVaultMock(_morpho).setCapacity(0);
        RecoveryAaveMock(_aave).setCapacity(0);
        RecoveryIssuerMock(_issuerB).seedPending(account, 60e6);
        _recover(0, 0, 40e6, 0, 0);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 60e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6);
        assertEq(RecoveryAaveMock(_aave).healthFactor(account), 1e18);
    }

    function test_RepeatedRecoveryCannotDuplicatePendingRequests() public withoutCash {
        _recover(30e6, 20e6, 40e6, 10e6, 50e6);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime = _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 0, 0, 0, 0, 0);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 10e6);
        assertEq(RecoveryTraceMock(_trace).count(), 5);
    }

    function test_CappedRecoveryQueuesUncoveredNeedAcrossRuns() public withoutCash {
        _config.maxRepayment = 40e6;
        RecoveryMorphoVaultMock(_morpho).setCapacity(0);
        RecoveryAaveMock(_aave).setCapacity(0);

        _recover(0, 0, 40e6, 0, 0);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 0);

        _recover(0, 0, 0, 40e6, 0);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 40e6);

        _recover(0, 0, 0, 20e6, 0);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 60e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6);
        assertEq(RecoveryAaveMock(_aave).healthFactor(account), 1e18);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_rwaA).balanceOf(account), 960e18);
        assertEq(IERC20(_rwaB).balanceOf(account), 940e18);

        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime = _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 0, 0, 0, 0, 0);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 60e6);
        assertEq(RecoveryTraceMock(_trace).count(), 3);
    }

    function test_CappedRecoveryOnlyQueuesNeedUncoveredByPending() public withoutCash {
        _config.maxRepayment = 40e6;
        RecoveryMorphoVaultMock(_morpho).setCapacity(0);
        RecoveryAaveMock(_aave).setCapacity(0);
        RecoveryIssuerMock(_issuerB).seedPending(account, 90e6);

        _recover(0, 0, 10e6, 0, 0);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 10e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 90e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_rwaA).balanceOf(account), 990e18);
    }

    function test_CappedRecoverySharesNewBudgetAfterPendingAndRepayment() public withoutCash {
        _config.maxRepayment = 60e6;
        RecoveryIssuerMock(_issuerB).seedPending(account, 20e6);

        _recover(30e6, 20e6, 10e6, 0, 50e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 10e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 20e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 250e6);
        assertEq(RecoveryAaveMock(_aave).healthFactor(account), 1.2e18);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_rwaA).balanceOf(account), 990e18);
    }

    function test_PendingAboveGapIncludesMaturedUnclaimedPrincipalAndSaturates() public withoutCash {
        RecoveryMorphoVaultMock(_morpho).setCapacity(0);
        RecoveryAaveMock(_aave).setCapacity(0);
        RecoveryIssuerMock(_issuerB).seedPending(account, 150e6);
        RecoveryIssuerMock(_issuerB).setMatured(account, 150e6);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime = _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 0, 0, 0, 0, 0);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 150e6);
        assertEq(RecoveryIssuerMock(_issuerB).claimable(account), 150e6);
        assertEq(RecoveryTraceMock(_trace).count(), 0);
    }

    function test_FullyCoveredFirstRedemptionSkipsLaterRedemption() public withoutCash {
        RecoveryMorphoVaultMock(_morpho).setCapacity(0);
        RecoveryAaveMock(_aave).setCapacity(0);
        RecoveryIssuerMock(_issuerA).setCapacity(100e6);
        _recover(0, 0, 100e6, 999e6, 0);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 100e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 0);
        assertEq(RecoveryTraceMock(_trace).count(), 1);
        assertEq(RecoveryTraceMock(_trace).calls(0), 3);
        assertEq(RecoveryAaveMock(_aave).healthFactor(account), 1e18);
    }

    function test_InsufficientTotalLiquidityMakesPartialProgress() public withoutCash {
        RecoveryIssuerMock(_issuerA).setCapacity(7e6);
        RecoveryIssuerMock(_issuerB).setCapacity(3e6);
        _recover(30e6, 20e6, 7e6, 3e6, 50e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 250e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 7e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 3e6);
    }

    function test_RepaymentCapLimitsWithdrawalsAndLeavesNoRequestBudget() public withoutCash {
        _config.maxRepayment = 40e6;
        _recover(30e6, 10e6, 0, 0, 40e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 260e6);
        assertEq(RecoveryAaveMock(_aave).capacity(account), 10e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 0);
    }

    function test_CapIsSharedBetweenFreshRepaymentAndRequests() public withoutCash {
        _config.maxRepayment = 60e6;
        _recover(30e6, 20e6, 10e6, 0, 50e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 10e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 0);
    }

    function test_ProviderCannotSkipHigherPrioritySource() public withoutCash {
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 0, 20e6, 40e6, 40e6, 20e6);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 10e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 250e6);
    }

    function testFuzz_ProviderCannotChangeWithdrawalAmount(uint256 extra) public withoutCash {
        extra = bound(extra, 1, 10e6);
        RecoveryMorphoVaultMock(_morpho).setCapacity(100e6 + extra);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 100e6 + extra, 0, 0, 0, 100e6);
        _execute(runtime);
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6);
        assertEq(IERC20(_asset).balanceOf(account), 0);
    }

    function test_ProviderCannotChangeWithdrawalRecipient() public {
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 30e6, 20e6, 40e6, 10e6, 50e6);
        IMerkleAccount.Action[] memory calls = abi.decode(runtime[layout.sourceCalls[0]], (IMerkleAccount.Action[]));
        calls[0].data = abi.encodeCall(RecoveryMorphoVaultMock.withdraw, (30e6, address(0xbad), account));
        runtime[layout.sourceCalls[0]] = abi.encode(calls);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        _execute(runtime);
        _assertPristine();
    }

    function test_InvalidCurrentProofRollsBackPriorWithdrawal() public {
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 30e6, 20e6, 40e6, 10e6, 50e6);
        IMerkleAccount.Action[] memory calls = abi.decode(runtime[layout.sourceCalls[1]], (IMerkleAccount.Action[]));
        calls[0].proof[0] ^= bytes32(uint256(1));
        runtime[layout.sourceCalls[1]] = abi.encode(calls);
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        _execute(runtime);
        _assertPristine();
    }

    function test_RevokedRepayLeafRollsBackBothWithdrawals() public {
        MerkleAccount(payable(account)).revokeRole(_config.repayLeaf, _executor);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 30e6, 20e6, 40e6, 10e6, 50e6);
        vm.expectRevert();
        _execute(runtime);
        _assertPristine();
    }

    function test_RepayFailureRollsBackSourcesAndApproval() public {
        RecoveryAaveMock(_aave).setRepayFailure(true);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 30e6, 20e6, 40e6, 10e6, 50e6);
        vm.expectRevert(RecoveryAaveMock.RepayFailed.selector);
        _execute(runtime);
        _assertPristine();
    }

    function test_OneBaseUnitDebtRoundingIsAccepted() public {
        RecoveryMorphoVaultMock(_morpho).setCapacity(100e6);
        RecoveryAaveMock(_aave).setRepayEffects(-1, 0);
        _recover(100e6, 0, 0, 0, 100e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6 + 1);
    }

    function test_ReverseOneBaseUnitDebtRoundingIsAccepted() public {
        RecoveryMorphoVaultMock(_morpho).setCapacity(100e6);
        RecoveryAaveMock(_aave).setRepayEffects(1, 0);
        _recover(100e6, 0, 0, 0, 100e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6 - 1);
    }

    function test_SourceInsufficientCashReceiptRollsBack() public {
        RecoveryMorphoVaultMock(_morpho).setShortfall(1);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 30e6, 20e6, 40e6, 10e6, 50e6);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", account, 67e6 - 1, 67e6)
        );
        _execute(runtime);
        _assertPristine();
    }

    function test_RwaOverburnCannotExceedBoundApproval() public withoutCash {
        RecoveryIssuerMock(_issuerA).setRequestEffects(1, 0);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 30e6, 20e6, 40e6, 10e6, 50e6);
        IMerkleAccount.Action[] memory calls = abi.decode(runtime[layout.requestCalls[0]], (IMerkleAccount.Action[]));
        calls[0].data = abi.encodeCall(IERC20.approve, (_issuerA, 40e18 + 1));
        runtime[layout.requestCalls[0]] = abi.encode(calls);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", _issuerA, 40e18, 40e18 + 1)
        );
        _execute(runtime);
        _assertPristine();
    }

    function test_ApprovalAndCleanupAmountsOverrideRuntime() public withoutCash {
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 30e6, 20e6, 40e6, 10e6, 50e6);
        IMerkleAccount.Action[] memory calls = abi.decode(runtime[layout.requestCalls[0]], (IMerkleAccount.Action[]));
        calls[0].data = abi.encodeCall(IERC20.approve, (_issuerA, type(uint256).max));
        calls[2].data = abi.encodeCall(IERC20.approve, (_issuerA, 1));
        runtime[layout.requestCalls[0]] = abi.encode(calls);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(IERC20(_rwaA).allowance(account, _issuerA), 0);
    }

    /// forge-config: default.isolate = true
    function test_CashRepayDoesNotRequireTriggerConfiguration() public {
        _config.triggerHealthFactor = 0;
        _execute(_repayRuntime(17e6));
        assertEq(RecoveryAaveMock(_aave).debt(account), 283e6);
        assertEq(IERC20(_asset).balanceOf(account), 0);
    }

    function test_RepayUsesAllSettledCashUpToTarget() public {
        RecoveryAaveMock(_aave).setPosition(250e6, 300e6);
        RecoveryIssuerMock(_issuerA).seedPending(account, 40e6);
        RecoveryIssuerMock(_issuerB).seedPending(account, 10e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 20e6);
        vm.prank(account);
        RecoveryIssuerMock(_issuerA).claim(20e6, account);
        vm.roll(block.number + 1);
        bytes[] memory runtime = _repayRuntime(37e6);
        _execute(runtime);
        vm.snapshotGasLastCall("RecipeRecovery", "repaySettledCash");
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(RecoveryAaveMock(_aave).debt(account), 213e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 20e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 10e6);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);

        // A later issuer payout can be repaid above the original recovery trigger.
        vm.prank(_issuerA);
        IERC20(_asset).transfer(account, 30e6);
        vm.roll(block.number + 1);
        _execute(_repayRuntime(13e6 + 1));
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6 - 1);
        assertEq(IERC20(_asset).balanceOf(account), 17e6 - 1);
        assertGe(RecoveryAaveMock(_aave).healthFactor(account), 1.5e18);
    }

    function testFuzz_RepaySettledCashRespectsAvailableCashAndRepaymentCap(uint256 cash, uint256 cap) public {
        cash = bound(cash, 1, 200e6);
        cap = bound(cap, 1, 200e6);
        _config.maxRepayment = cap;
        RecoveryTokenMock(_asset).mint(account, cash);
        uint256 available = 17e6 + cash;
        uint256 expected = available < cap ? available : cap;
        if (expected > 100e6) expected = 100e6;
        _execute(_repayRuntime(expected));
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6 - expected);
        assertEq(IERC20(_asset).balanceOf(account), 17e6 + cash - expected);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
    }

    function test_RepaySettledCashSkipsNoAvailableCash() public {
        vm.prank(account);
        IERC20(_asset).transfer(_issuerA, 17e6);
        bytes[] memory runtime = _repayRuntime(0);
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6);
    }

    function test_RepaySettledCashSkipsZeroDebt() public {
        RecoveryAaveMock(_aave).setPosition(0, 300e6);
        bytes[] memory runtime = _repayRuntime(0);
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
    }

    function test_RepaySettledCashFailurePreservesEarlierPayout() public {
        RecoveryTokenMock(_asset).mint(account, 40e6);
        RecoveryAaveMock(_aave).setRepayFailure(true);
        bytes[] memory runtime = _repayRuntime(57e6);
        vm.expectRevert(RecoveryAaveMock.RepayFailed.selector);
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(account), 57e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
    }

    function testFuzz_RepaymentCapBoundsCashAndSourceSpending(uint256 cap) public {
        cap = bound(cap, 1, 100e6);
        RecoveryMorphoVaultMock(_morpho).setCapacity(100e6);
        _config.maxRepayment = cap;
        _recover(cap, 0, 0, 0, cap);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6 - cap);
        assertEq(IERC20(_asset).balanceOf(account), cap < 17e6 ? 17e6 - cap : 0);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
        assertEq(RecoveryMorphoVaultMock(_morpho).maxWithdraw(account), 100e6 - (cap > 17e6 ? cap - 17e6 : 0));
    }

    function buildRecoveryO05(RecoveryRecipe.Config memory config) public pure {
        RecoveryRecipe.recovery(config);
    }

    function _firstO05MulDiv(ExecutingRecipe.Recipe memory recipe) internal pure returns (uint256) {
        for (uint256 i; i < recipe.steps.length; ++i) {
            if (uint8(recipe.steps[i][0]) == OP_MUL_DIV) return i;
        }
        revert("missing initial need");
    }

    function _prefixO05(uint256 debtAmount, uint256 health) internal returns (bool success, bytes memory response) {
        address lens = address(new RecoveryO05Lens(health, debtAmount));
        RecoveryRecipe.Config memory config = _config;
        config.healthFactor = _read(lens, abi.encodeWithSignature("health()"));
        config.debt = _read(lens, abi.encodeWithSignature("debt()"));
        (ExecutingRecipe.Recipe memory recipe,) = RecoveryRecipe.recovery(config);
        bytes[] memory steps = new bytes[](_firstO05MulDiv(recipe) + 3);
        for (uint256 i; i < steps.length; ++i) {
            steps[i] = recipe.steps[i];
        }
        RecipeExecutor(_executor).setRecipe(recipe.queries, steps);
        return _executor.call(
            abi.encodeCall(IRecipeExecutor.execute, (recipe.queries, steps, new uint256[](0), new bytes[](0)))
        );
    }

    function _configureRecipe() internal {
        _config.account = account;
        _config.asset = _asset;
        _config.repayTarget = _aave;
        _config.approvalLeaf = _leaf(2);
        _config.repayLeaf = _leaf(3);
        _config.repayAmountOffsets.push(36);
        _config.healthFactor = _read(_aave, abi.encodeCall(RecoveryAaveMock.healthFactor, (account)));
        _config.debt = _read(_aave, abi.encodeCall(RecoveryAaveMock.debt, (account)));
        _config.triggerHealthFactor = 1.25e18;
        _config.targetHealthFactor = 1.5e18;
        _config.maxRepayment = 100e6;
        _config.sources.push();
        _config.sources[0].capacity = _read(_morpho, abi.encodeCall(RecoveryMorphoVaultMock.maxWithdraw, (account)));
        _config.sources[0].leaves.push(_leaf(0));
        _config.sources[0].amountOffsets.push();
        _config.sources[0].amountOffsets[0].push(4);
        _config.sources.push();
        _config.sources[1].capacity = _read(_aave, abi.encodeCall(RecoveryAaveMock.capacity, (account)));
        _config.sources[1].leaves.push(_leaf(1));
        _config.sources[1].amountOffsets.push();
        _config.sources[1].amountOffsets[0].push(36);
        for (uint256 i; i < 2; ++i) {
            address issuer = i == 0 ? _issuerA : _issuerB;
            _config.redemptions.push();

            _config.redemptions[i].capacity = _read(issuer, abi.encodeCall(RecoveryIssuerMock.capacity, (account)));
            _config.redemptions[i].pending = _read(issuer, abi.encodeWithSignature("pending(address)", account));
            _config.redemptions[i].maxTokenPerAssetWad = 1e30;
            _config.redemptions[i].leaves.push(_leaf(4 + i * 2));
            _config.redemptions[i].leaves.push(_leaf(5 + i * 2));
            _config.redemptions[i].leaves.push(_leaf(4 + i * 2));
            for (uint256 j; j < 3; ++j) {
                _config.redemptions[i].amountOffsets.push();
                _config.redemptions[i].approvalAmountOffsets.push();
                _config.redemptions[i].clearApprovalAmountOffsets.push();
            }
            _config.redemptions[i].amountOffsets[1].push(4);
            _config.redemptions[i].approvalAmountOffsets[0].push(36);
            _config.redemptions[i].clearApprovalAmountOffsets[2].push(36);
        }
    }

    function _configurePermissions() internal {
        _actions.push(_action(_morpho, abi.encodeCall(RecoveryMorphoVaultMock.withdraw, (0, account, account)), 4));
        _actions.push(_action(_aave, abi.encodeCall(RecoveryAaveMock.withdraw, (_asset, 0, account)), 36));
        _actions.push(_action(_asset, abi.encodeCall(IERC20.approve, (_aave, 0)), 36));
        _actions.push(_action(_aave, abi.encodeCall(RecoveryAaveMock.repay, (_asset, 0, 2, account)), 36));
        _actions.push(_action(_rwaA, abi.encodeCall(IERC20.approve, (_issuerA, 0)), 36));
        _actions.push(_action(_issuerA, abi.encodeCall(RecoveryIssuerMock.request, (0, account)), 4));
        _actions.push(_action(_rwaB, abi.encodeCall(IERC20.approve, (_issuerB, 0)), 36));
        _actions.push(_action(_issuerB, abi.encodeCall(RecoveryIssuerMock.request, (0, account)), 4));
        _actions.push(_action(_issuerA, abi.encodeCall(RecoveryIssuerMock.claim, (0, account)), 4));
        _actions.push(_action(_issuerB, abi.encodeCall(RecoveryIssuerMock.claim, (0, account)), 4));
        bytes32[] memory nodes = new bytes32[](31);
        for (uint256 i; i < _actions.length; ++i) {
            nodes[15 + i] = _leaf(i);
            MerkleAccount(payable(account)).grantRole(nodes[15 + i], _executor);
        }
        for (uint256 i = 15; i > 0;) {
            --i;
            bytes32 left = nodes[i * 2 + 1];
            bytes32 right = nodes[i * 2 + 2];
            nodes[i] =
                left < right ? keccak256(abi.encodePacked(left, right)) : keccak256(abi.encodePacked(right, left));
        }
        for (uint256 i; i < _actions.length; ++i) {
            uint256 cursor = 15 + i;
            while (cursor > 0) {
                _actions[i].proof.push(nodes[cursor % 2 == 1 ? cursor + 1 : cursor - 1]);
                cursor = (cursor - 1) / 2;
            }
        }
        roots.setRoot(account, nodes[0]);
        MerkleAccount(payable(account)).acceptRoot(nodes[0]);
    }

    function _action(address target, bytes memory data, uint256 amountOffset)
        internal
        pure
        returns (IMerkleAccount.Action memory)
    {
        bytes memory mask = new bytes(data.length);
        for (uint256 i; i < 32; ++i) {
            mask[amountOffset + i] = 0xff;
        }
        return IMerkleAccount.Action({target: target, value: 0, data: data, dataMask: mask, proof: new bytes32[](0)});
    }

    function _leaf(uint256 index) internal view returns (bytes32) {
        return ActionMasker.mask(_actions[index].target, 0, _actions[index].data, _actions[index].dataMask);
    }

    function _read(address target, bytes memory data) internal pure returns (RecoveryRecipe.Read memory) {
        return RecoveryRecipe.Read({target: target, data: data, offset: 0});
    }

    function _recoveryRuntime(
        uint256 length,
        RecoveryRecipe.Layout memory layout,
        uint256 morpho,
        uint256 aave,
        uint256 requestA,
        uint256 requestB,
        uint256 repayAmount
    ) internal returns (bytes[] memory runtime) {
        runtime = _baseRuntime(length, layout, repayAmount);
        runtime[layout.sourceCalls[0]] =
            _one(0, abi.encodeCall(RecoveryMorphoVaultMock.withdraw, (morpho, account, account)));
        runtime[layout.sourceCalls[1]] = _one(1, abi.encodeCall(RecoveryAaveMock.withdraw, (_asset, aave, account)));
        runtime[layout.requestCalls[0]] = _request(0, requestA);
        runtime[layout.requestCalls[1]] = _request(1, requestB);
        (ExecutingRecipe.Recipe memory recipe,) = RecoveryRecipe.recovery(_config);
        _recipe = abi.encode(recipe.queries, recipe.steps);
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
    }

    function _baseRuntime(uint256 length, RecoveryRecipe.Layout memory layout, uint256 repayAmount)
        internal
        view
        returns (bytes[] memory runtime)
    {
        runtime = new bytes[](length);
        runtime[layout.approve] = abi.encode(_actions[2].dataMask, _actions[2].proof);
        runtime[layout.clearApproval] = runtime[layout.approve];
        runtime[layout.repay] = _one(3, abi.encodeCall(RecoveryAaveMock.repay, (_asset, repayAmount, 2, account)));
    }

    function _repayRuntime(uint256 repayAmount) internal returns (bytes[] memory runtime) {
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.repay(_config);
        runtime = _baseRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, repayAmount);
        _recipe = abi.encode(recipe.queries, recipe.steps);
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
    }

    function _request(uint256 index, uint256 amount) internal view returns (bytes memory) {
        address issuer = index == 0 ? _issuerA : _issuerB;
        IMerkleAccount.Action[] memory calls = new IMerkleAccount.Action[](3);
        calls[0] = _actions[4 + index * 2];
        calls[0].data = abi.encodeCall(IERC20.approve, (issuer, amount * 1e12));
        calls[1] = _actions[5 + index * 2];
        calls[1].data = abi.encodeCall(RecoveryIssuerMock.request, (amount, account));
        calls[2] = _actions[4 + index * 2];
        calls[2].data = abi.encodeCall(IERC20.approve, (issuer, 0));
        return abi.encode(calls);
    }

    function _one(uint256 index, bytes memory data) internal view returns (bytes memory) {
        IMerkleAccount.Action[] memory calls = new IMerkleAccount.Action[](1);
        calls[0] = _actions[index];
        calls[0].data = data;
        return abi.encode(calls);
    }

    function _recover(uint256 morpho, uint256 aave, uint256 requestA, uint256 requestB, uint256 repayAmount) internal {
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        _execute(
            _recoveryRuntime(
                ExecutingRecipe.runtimeSteps(recipe).length, layout, morpho, aave, requestA, requestB, repayAmount
            )
        );
    }

    function _execute(bytes[] memory runtime) internal {
        (bytes[] memory queries, bytes[] memory steps) = abi.decode(_recipe, (bytes[], bytes[]));
        RecipeExecutor(_executor).execute(queries, steps, new uint256[](0), runtime);
    }

    function _assertPristine() internal view {
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6);
        assertEq(RecoveryAaveMock(_aave).healthFactor(account), 1e18);
        assertEq(RecoveryMorphoVaultMock(_morpho).maxWithdraw(account), 30e6);
        assertEq(RecoveryAaveMock(_aave).capacity(account), 20e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 0);
        assertEq(IERC20(_asset).balanceOf(account), _initialCash);
        assertEq(IERC20(_rwaA).balanceOf(account), 1000e18);
        assertEq(IERC20(_rwaB).balanceOf(account), 1000e18);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
        assertEq(RecoveryTraceMock(_trace).count(), 0);
    }
}

/// @dev Deliberately unrestricted local fixture tokens; never represents live issuer authorization.
contract RecoveryTokenMock is ERC20 {
    uint8 internal immutable _decimals;

    constructor(string memory symbol, uint8 newDecimals) ERC20(symbol, symbol) {
        _decimals = newDecimals;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address account, uint256 amount) public {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) public {
        _burn(account, amount);
    }
}

contract RecoveryTraceMock {
    uint256[] public calls;

    function record(uint256 value) public {
        calls.push(value);
    }

    function count() public view returns (uint256) {
        return calls.length;
    }
}

/// @dev ERC-4626 withdraw/maxWithdraw ABI models an independent Morpho vault position, not debt collateral.
contract RecoveryMorphoVaultMock {
    address public immutable asset;
    address public immutable trace;
    uint256 internal _capacity;
    uint256 internal _shortfall;

    constructor(address newAsset, address newTrace) {
        asset = newAsset;
        trace = newTrace;
    }

    function setCapacity(uint256 value) public {
        _capacity = value;
    }

    function setShortfall(uint256 value) public {
        _shortfall = value;
    }

    function maxWithdraw(address) public view returns (uint256) {
        return _capacity;
    }

    function withdraw(uint256 assets, address receiver, address owner) public returns (uint256) {
        require(owner == msg.sender);
        _capacity -= assets;
        IERC20(asset).transfer(receiver, assets - _shortfall);
        RecoveryTraceMock(trace).record(1);
        return assets;
    }
}

/// @dev Aave-compatible withdraw/repay ABIs. Debt/HF reads are normalized fixture queries;
/// independent supplied USDC is withdrawable while fixed liquidation-weighted collateral backs debt.
contract RecoveryAaveMock {
    error RepayFailed();
    address public immutable asset;
    address public immutable trace;
    uint256 internal _capacity;
    uint256 internal _debt;
    uint256 internal _collateral;
    int256 internal _debtReductionAdjustment;
    uint256 internal _collateralLoss;
    bool internal _repayFailure;

    constructor(address newAsset, address newTrace) {
        asset = newAsset;
        trace = newTrace;
    }

    function setPosition(uint256 debtAmount, uint256 collateral) public {
        _debt = debtAmount;
        _collateral = collateral;
    }

    function setCapacity(uint256 value) public {
        _capacity = value;
    }

    function setRepayFailure(bool value) public {
        _repayFailure = value;
    }

    function setRepayEffects(int256 debtAdjustment, uint256 collateralLoss) public {
        _debtReductionAdjustment = debtAdjustment;
        _collateralLoss = collateralLoss;
    }

    function capacity(address) public view returns (uint256) {
        return _capacity;
    }

    function debt(address) public view returns (uint256) {
        return _debt;
    }

    function healthFactor(address) public view returns (uint256) {
        return _debt == 0 ? type(uint256).max : _collateral * 1e18 / _debt;
    }

    function withdraw(address token, uint256 amount, address to) public returns (uint256) {
        require(token == asset);
        _capacity -= amount;
        IERC20(asset).transfer(to, amount);
        RecoveryTraceMock(trace).record(2);
        return amount;
    }

    function repay(address token, uint256 amount, uint256 mode, address onBehalf) public returns (uint256) {
        if (_repayFailure) revert RepayFailed();
        require(token == asset && mode == 2 && onBehalf == msg.sender);
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        _debt -= uint256(int256(amount) + _debtReductionAdjustment);
        _collateral -= _collateralLoss;
        RecoveryTraceMock(trace).record(5);
        return amount;
    }
}

/// @dev Normalized asynchronous issuer fixture: pending and claimable are asset principal in six decimals.
/// Request burns eighteen-decimal RWA; maturity is externally advanced to model offchain settlement.
contract RecoveryIssuerMock {
    address public immutable asset;
    address public immutable token;
    address public immutable trace;
    uint256 public immutable traceId;
    mapping(address => uint256) public pending;
    mapping(address => uint256) public claimable;
    uint256 internal _capacity;
    uint256 internal _burnExtra;
    uint256 internal _pendingShortfall;
    uint256 internal _claimRate = 1e18;
    bool internal _settlementSeparatesPending;
    address internal _claimPosition;
    uint256 internal _claimDebt;
    uint256 internal _claimCollateral;

    constructor(address newAsset, address newToken, address newTrace, uint256 newTraceId) {
        asset = newAsset;
        token = newToken;
        trace = newTrace;
        traceId = newTraceId;
    }

    function setCapacity(uint256 value) public {
        _capacity = value;
    }

    function capacity(address) public view returns (uint256) {
        return _capacity;
    }

    function seedPending(address account, uint256 amount) public {
        pending[account] = amount;
    }

    function setMatured(address account, uint256 amount) public {
        require(amount <= pending[account]);
        if (_settlementSeparatesPending) pending[account] -= amount;
        claimable[account] = amount;
    }

    function setSettlementSeparatesPending(bool value) public {
        _settlementSeparatesPending = value;
    }

    function setClaimPosition(address position, uint256 debtAmount, uint256 collateral) public {
        _claimPosition = position;
        _claimDebt = debtAmount;
        _claimCollateral = collateral;
    }

    function setRequestEffects(uint256 burnExtra, uint256 pendingShortfall) public {
        _burnExtra = burnExtra;
        _pendingShortfall = pendingShortfall;
    }

    function setClaimRate(uint256 value) public {
        _claimRate = value;
    }

    function request(uint256 amount, address recipient) public {
        _capacity -= amount;
        uint256 burn = amount * 1e12 + _burnExtra;
        IERC20(token).transferFrom(msg.sender, address(this), burn);
        RecoveryTokenMock(token).burn(address(this), burn);
        pending[recipient] += amount - _pendingShortfall;
        RecoveryTraceMock(trace).record(traceId);
    }

    function claim(uint256 amount, address recipient) public {
        claimable[msg.sender] -= amount;
        if (!_settlementSeparatesPending) pending[msg.sender] -= amount;
        IERC20(asset).transfer(recipient, amount * _claimRate / 1e18);
        if (_claimPosition != address(0)) {
            RecoveryAaveMock(_claimPosition).setPosition(_claimDebt, _claimCollateral);
        }
        RecoveryTraceMock(trace).record(traceId + 3);
    }
}

/// @dev Supplies raw full-width observations without the fixture collateral arithmetic.
contract RecoveryO05Lens {
    uint256 public health;
    uint256 public debt;

    constructor(uint256 newHealth, uint256 newDebt) {
        health = newHealth;
        debt = newDebt;
    }
}

/// @dev Raw claim observations bypass fixture collateral and payout multiplication for arithmetic prefixes.
/// @dev Separate adversarial token; the gas fixtures keep the ordinary mock unchanged.
contract RecoveryEffectTokenMock is RecoveryTokenMock {
    address internal _effectAccount;
    address internal _repayTarget;
    address internal _executor;
    uint256 internal _effect;
    uint256 public effectCount;

    constructor() RecoveryTokenMock("EFFECT", 6) {}

    function setEffects(address newAccount, address newRepayTarget, address newExecutor, uint256 newEffect) public {
        _effectAccount = newAccount;
        _repayTarget = newRepayTarget;
        _executor = newExecutor;
        _effect = newEffect;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        if (_effectAccount == msg.sender && spender == _repayTarget) {
            if ((_effect < 2 && amount > 0) || (_effect >= 2 && _effect < 4 && amount == 0)) {
                ++effectCount;
                if (_effect % 2 == 0) _mint(_effectAccount, 1);
                else _burn(_effectAccount, 1);
            }
            if (_effect == 6 && amount > 0) {
                RecipeExecutor(_executor).execute(new bytes[](0), new bytes[](0), new uint256[](0), new bytes[](0));
            }
        }
        return super.approve(spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 value) internal override {
        if (_effect >= 2 && _effect < 4 && owner == _effectAccount && spender == _repayTarget) {
            require(allowance(owner, spender) >= value);
            return;
        }
        super._spendAllowance(owner, spender, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == _effectAccount && to == _repayTarget && (_effect == 4 || _effect == 5)) {
            ++effectCount;
            value = _effect == 4 ? value + 1 : value - 1;
        }
        super._update(from, to, value);
    }
}

/// @dev Local per-ID owner ledger used to distinguish the cleared ID from the next selector result.
