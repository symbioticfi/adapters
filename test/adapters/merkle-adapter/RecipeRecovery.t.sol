// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {
    IRecipes,
    OP_APPROVE,
    OP_MIN,
    OP_MUL_DIV,
    OP_READ,
    OP_READ_IF,
    SRC_RESULT
} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BuildRecipe} from "script/recipes/BuildRecipe.s.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {RecoveryRecipe} from "script/recipes/RecoveryRecipe.sol";

import {stdJson} from "forge-std/StdJson.sol";

/// @dev Real Merkle routing and executor, with explicitly local protocol-effects fixtures and no RPC.
/// Asset amounts use six decimals; RWA amounts use eighteen, so the token/asset WAD rate is 1e30.
contract RecipeRecoveryTest is CapabilityTestBase {
    using stdJson for string;
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

    function test_O05InitialHealthClampReducesInstructions() public view {
        RecoveryRecipe.Config memory config = _config;
        for (uint256 mode; mode < 2; ++mode) {
            config.skipUnusedReads = mode == 1;
            (ExecutingRecipe.Recipe memory recipe,) = RecoveryRecipe.recovery(config);
            uint256 index = _firstO05MulDiv(recipe);
            (, uint256 health, uint256 denominator) =
                abi.decode(Bytes.slice(recipe.steps[index], 1), (uint256, uint256, uint256));
            assertEq(health, uint256(SRC_RESULT) << 216);
            assertEq(denominator, config.targetHealthFactor);
            assertEq(recipe.steps.length, mode == 0 ? 96 : 97);
            if (mode == 1) assertEq(abi.encode(recipe.queries, recipe.steps).length, 21_536);
            uint256 clamps;
            for (uint256 i; i < recipe.steps.length; ++i) {
                if (uint8(recipe.steps[i][0]) != OP_MIN) continue;
                (, uint256 b) = abi.decode(Bytes.slice(recipe.steps[i], 1), (uint256, uint256));
                if (b == config.targetHealthFactor) ++clamps;
            }
            assertEq(clamps, 1);
        }
    }

    function test_O05SemanticRecordRecipeControls() public {
        RecoveryRecipe.Config memory config = _config;
        (ExecutingRecipe.Recipe memory recovery,) = RecoveryRecipe.recovery(config);
        (ExecutingRecipe.Recipe memory claim,) = RecoveryRecipe.claim(config);
        (ExecutingRecipe.Recipe memory repay,) = RecoveryRecipe.repay(config, 17e6);
        assertEq(
            keccak256(abi.encode(claim.queries, claim.steps)),
            0x1907dc1d8784938d4049e6c5184873f2292a6caa66973d47cb31d2c8142aaff7
        );
        string memory evidence = vm.envOr("O05_EVIDENCE_DIR", string(""));
        if (bytes(evidence).length > 0) {
            vm.serializeBytes("o05", "recovery", abi.encode(recovery.queries, recovery.steps));
            vm.serializeBytes("o05", "recoveryQueries", abi.encode(recovery.queries));
            vm.serializeUint("o05", "recoverySlots", ExecutingRecipe.runtimeSteps(recovery));
            vm.serializeBytes("o05", "claim", abi.encode(claim.queries, claim.steps));
            vm.serializeBytes("o05", "repay", abi.encode(repay.queries, repay.steps));
            config.skipUnusedReads = true;
            (ExecutingRecipe.Recipe memory conditional,) = RecoveryRecipe.recovery(config);
            vm.serializeBytes("o05", "conditional", abi.encode(conditional.queries, conditional.steps));
            vm.serializeBytes("o05", "conditionalQueries", abi.encode(conditional.queries));
            string memory json = vm.serializeUint("o05", "conditionalSlots", ExecutingRecipe.runtimeSteps(conditional));
            vm.writeFile(string.concat(evidence, "/observations.json"), json);
        }
    }

    function testFuzz_O05SemanticTriggerBoundaries(uint8 boundary, bool skipReads, bool skipApprovals) public {
        uint256[4] memory collateral = [uint256(0), 600e6, 750e6, 750e6 + 1];
        uint256 selected = boundary % 4;
        _config.skipUnusedReads = skipReads;
        _config.skipZeroApprovals = skipApprovals;
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
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
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
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
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
    function test_RecoveryWithdrawsMorphoThenAaveRepaysThenRequestsInOrder() public {
        _recover(30e6, 20e6, 40e6, 10e6, 50e6);
        vm.snapshotGasLastCall("RecipeRecovery", "recovery");

        assertEq(RecoveryAaveMock(_aave).debt(account), 250e6);
        assertEq(RecoveryAaveMock(_aave).healthFactor(account), 1.2e18);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 10e6);
        assertEq(IERC20(_rwaA).balanceOf(account), 960e18);
        assertEq(IERC20(_rwaB).balanceOf(account), 990e18);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
        assertEq(IERC20(_rwaA).allowance(account, _issuerA), 0);
        assertEq(RecoveryTraceMock(_trace).count(), 5);
        assertEq(RecoveryTraceMock(_trace).calls(0), 1);
        assertEq(RecoveryTraceMock(_trace).calls(1), 2);
        assertEq(RecoveryTraceMock(_trace).calls(2), 5);
        assertEq(RecoveryTraceMock(_trace).calls(3), 3);
        assertEq(RecoveryTraceMock(_trace).calls(4), 4);
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

    function test_OptimizedRecoverySkipsUnusedSourceAndIssuerQueries() public {
        _config.skipUnusedReads = true;
        _config.skipZeroApprovals = true;
        RecoveryMorphoVaultMock(_morpho).setCapacity(200e6);
        vm.mockCallRevert(_aave, abi.encodeCall(RecoveryAaveMock.capacity, (account)), hex"deadbeef");
        vm.mockCallRevert(_issuerA, abi.encodeWithSignature("pending(address)", account), hex"deadbeef");
        vm.mockCallRevert(_issuerB, abi.encodeWithSignature("pending(address)", account), hex"deadbeef");
        vm.mockCallRevert(_issuerA, abi.encodeCall(RecoveryIssuerMock.capacity, (account)), hex"deadbeef");
        vm.mockCallRevert(_issuerB, abi.encodeCall(RecoveryIssuerMock.capacity, (account)), hex"deadbeef");
        vm.mockCallRevert(_rwaA, abi.encodeCall(IERC20.balanceOf, (account)), hex"deadbeef");
        vm.mockCallRevert(_rwaB, abi.encodeCall(IERC20.balanceOf, (account)), hex"deadbeef");
        _recover(100e6, 999e6, 999e6, 999e6, 100e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6);
        assertEq(RecoveryAaveMock(_aave).healthFactor(account), 1.5e18);
        assertEq(RecoveryTraceMock(_trace).count(), 2);
    }

    function test_OptimizedRecoveryStillRejectsUnusedIssuerAllowance() public {
        _config.skipUnusedReads = true;
        RecoveryMorphoVaultMock(_morpho).setCapacity(200e6);
        vm.prank(account);
        IERC20(_rwaA).approve(_issuerA, 1);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 100e6, 0, 0, 0, 100e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6);
    }

    function test_OptimizedRecoveryStillCountsLowerPriorityPending() public {
        _config.skipUnusedReads = true;
        RecoveryMorphoVaultMock(_morpho).setCapacity(0);
        RecoveryAaveMock(_aave).setCapacity(0);
        RecoveryIssuerMock(_issuerB).seedPending(account, 60e6);
        _recover(0, 0, 40e6, 0, 0);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 60e6);
    }

    function test_OptimizedRecoveryPreservesPartialProgress() public {
        _config.skipUnusedReads = true;
        _config.skipZeroApprovals = true;
        RecoveryIssuerMock(_issuerA).setCapacity(0);
        RecoveryIssuerMock(_issuerB).setCapacity(0);
        _recover(30e6, 20e6, 0, 0, 50e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 250e6);
        assertEq(RecoveryAaveMock(_aave).healthFactor(account), 1.2e18);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
    }

    /// forge-config: default.isolate = true
    function test_GasOptimizedFullyFundedRecovery() public {
        RecoveryMorphoVaultMock(_morpho).setCapacity(200e6);
        uint256 state = vm.snapshotState();
        _recover(100e6, 0, 0, 0, 100e6);
        uint256 originalGas = vm.snapshotGasLastCall("RecipeRecovery", "fullyFundedUnconditional");
        assertTrue(vm.revertToState(state));
        _config.skipUnusedReads = true;
        _config.skipZeroApprovals = true;
        _recover(100e6, 0, 0, 0, 100e6);
        uint256 optimizedGas = vm.snapshotGasLastCall("RecipeRecovery", "fullyFundedConditional");
        assertLt(optimizedGas, originalGas);
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6);
        assertEq(RecoveryTraceMock(_trace).count(), 2);
        emit log_named_uint("fully-funded recovery gas saved", originalGas - optimizedGas);
    }

    /// forge-config: default.isolate = true
    function test_GasO03HealthClaim() public {
        RecoveryIssuerMock(_issuerA).seedPending(account, 50e6);
        RecoveryIssuerMock(_issuerB).seedPending(account, 50e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 50e6);
        RecoveryIssuerMock(_issuerB).setMatured(account, 50e6);
        _claim(50e6, 50e6, 100e6);
        vm.snapshotGasLastCall("RecipeRecovery", "O03HealthClaim");
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 0);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
        assertEq(RecoveryTraceMock(_trace).count(), 3);
    }

    function test_O03ImpliedPositivityReducesInstructions() public view {
        RecoveryRecipe.Config memory config = _config;
        (ExecutingRecipe.Recipe memory qualifying,) = RecoveryRecipe.claim(config);
        config.claims[0].minAssetPerClaimWad = 1e18 - 1;
        config.claims[1].minAssetPerClaimWad = 1e18 - 1;
        (ExecutingRecipe.Recipe memory fractional,) = RecoveryRecipe.claim(config);
        assertEq(qualifying.steps.length + 4, fractional.steps.length);
        assertEq(
            abi.encode(qualifying.queries, qualifying.steps).length + 640,
            abi.encode(fractional.queries, fractional.steps).length
        );
        assertEq(ExecutingRecipe.runtimeSteps(qualifying).length, ExecutingRecipe.runtimeSteps(fractional).length);
    }

    function test_O03FractionalLaterClaimRollsBackEarlierOutput() public {
        _config.claims[1].minAssetPerClaimWad = 1;
        RecoveryIssuerMock(_issuerA).seedPending(account, 50e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 50e6);
        RecoveryIssuerMock(_issuerB).seedPending(account, 1);
        RecoveryIssuerMock(_issuerB).setMatured(account, 1);
        RecoveryIssuerMock(_issuerB).setClaimRate(1);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(_config);
        bytes[] memory runtime = _claimRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 50e6, 1, 50e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 50e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 1);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6);
    }

    function testFuzz_O03QualifyingRatesKeepSelectedOutputFloor(uint256 amount, uint256 rate) public {
        amount = bound(amount, 1, 50e6);
        rate = bound(rate, 1e18, 2e18);
        RecoveryAaveMock(_aave).setPosition(0, 300e6);
        _config.claims[0].minAssetPerClaimWad = rate;
        _config.claims[0].maxAmount = amount;
        RecoveryIssuerMock(_issuerA).seedPending(account, 50e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 50e6);
        RecoveryIssuerMock(_issuerA).setClaimRate(rate);
        _claim(amount, 0, 0);
        assertEq(IERC20(_asset).balanceOf(account), 17e6 + amount * rate / 1e18);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 50e6 - amount);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 50e6 - amount);
    }

    /// forge-config: default.isolate = true
    function test_GasO01TwoActiveSources() public {
        _config.skipUnusedReads = true;
        _recover(30e6, 20e6, 40e6, 10e6, 50e6);
        vm.snapshotGasLastCall("RecipeRecovery", "O01TwoActiveSources");
        assertEq(RecoveryAaveMock(_aave).debt(account), 250e6);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 10e6);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
        assertEq(RecoveryTraceMock(_trace).calls(0), 1);
        assertEq(RecoveryTraceMock(_trace).calls(1), 2);
        assertEq(RecoveryTraceMock(_trace).calls(2), 5);
    }

    /// forge-config: default.isolate = true
    function test_GasO01TwoActiveClaims() public {
        _config.skipUnusedReads = true;
        RecoveryIssuerMock(_issuerA).seedPending(account, 50e6);
        RecoveryIssuerMock(_issuerB).seedPending(account, 50e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 50e6);
        RecoveryIssuerMock(_issuerB).setMatured(account, 50e6);
        _claim(50e6, 50e6, 100e6);
        vm.snapshotGasLastCall("RecipeRecovery", "O01TwoActiveClaims");
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 0);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
        assertEq(RecoveryTraceMock(_trace).calls(0), 6);
        assertEq(RecoveryTraceMock(_trace).calls(1), 7);
        assertEq(RecoveryTraceMock(_trace).calls(2), 5);
    }

    /// forge-config: default.isolate = true
    function test_GasO01OneActiveGroup() public {
        _config.skipUnusedReads = true;
        RecoveryMorphoVaultMock(_morpho).setCapacity(100e6);
        _recover(100e6, 0, 0, 0, 100e6);
        vm.snapshotGasLastCall("RecipeRecovery", "O01OneActiveGroup");
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
        assertEq(RecoveryTraceMock(_trace).count(), 2);
    }

    function test_O01CashPrefixReadsAreMinimal() public {
        (ExecutingRecipe.Recipe memory ordinaryRecovery,) = RecoveryRecipe.recovery(_config);
        (ExecutingRecipe.Recipe memory ordinaryClaim,) = RecoveryRecipe.claim(_config);
        emit log_named_bytes32(
            "unconditional recovery hash", keccak256(abi.encode(ordinaryRecovery.queries, ordinaryRecovery.steps))
        );
        emit log_named_bytes32(
            "unconditional claim hash", keccak256(abi.encode(ordinaryClaim.queries, ordinaryClaim.steps))
        );
        assertEq(
            keccak256(abi.encode(ordinaryRecovery.queries, ordinaryRecovery.steps)),
            0xb7dac6aa8a621dba9a9f99622314187a0450b8f3544f858ddcf4dd88820687fa
        );
        assertEq(
            keccak256(abi.encode(ordinaryClaim.queries, ordinaryClaim.steps)),
            0x1907dc1d8784938d4049e6c5184873f2292a6caa66973d47cb31d2c8142aaff7
        );
        _config.skipUnusedReads = true;
        (ExecutingRecipe.Recipe memory recovery, RecoveryRecipe.Layout memory recoveryLayout) =
            RecoveryRecipe.recovery(_config);
        (ExecutingRecipe.Recipe memory claim, RecoveryRecipe.Layout memory claimLayout) = RecoveryRecipe.claim(_config);
        uint256[] memory recoverySlots = ExecutingRecipe.runtimeSteps(recovery);
        uint256[] memory claimSlots = ExecutingRecipe.runtimeSteps(claim);
        (uint256 recoveryReads,) = _cashReads(recovery, 0, recoverySlots[recoveryLayout.approve]);
        (uint256 claimReads,) = _cashReads(claim, 0, claimSlots[claimLayout.approve]);
        emit log_named_uint("conditional recovery bytes", abi.encode(recovery.queries, recovery.steps).length);
        emit log_named_uint("conditional claim bytes", abi.encode(claim.queries, claim.steps).length);
        emit log_named_uint("conditional recovery steps", recovery.steps.length);
        emit log_named_uint("conditional claim steps", claim.steps.length);
        assertEq(recovery.steps.length, 97);
        assertEq(claim.steps.length, 57);
        assertEq(abi.encode(recovery.queries, recovery.steps).length, 21_536);
        assertEq(abi.encode(claim.queries, claim.steps).length, 12_064);
        assertEq(recoverySlots.length, ExecutingRecipe.runtimeSteps(ordinaryRecovery).length);
        assertEq(claimSlots.length, ExecutingRecipe.runtimeSteps(ordinaryClaim).length);
        assertEq(recoveryReads, 3);
        assertEq(claimReads, 3);
        (uint256 afterApproval,) =
            _cashReads(recovery, recoverySlots[recoveryLayout.approve] + 1, recoverySlots[recoveryLayout.repay]);
        (uint256 afterCleanup,) =
            _cashReads(recovery, recoverySlots[recoveryLayout.clearApproval] + 1, recovery.steps.length);
        assertEq(afterApproval, 1);
        assertGe(afterCleanup, 1);
    }

    function test_O01ConditionalJsonArtifactsMatchRecipeAndLayout() public {
        address builder = deployCode("BuildRecipe.s.sol:BuildRecipe");
        vm.mockCall(address(0x103), abi.encodeCall(IMerkleAdapter.account, ()), abi.encode(address(0x104)));
        vm.mockCall(address(0x104), abi.encodeCall(IMerkleAccount.adapter, ()), abi.encode(address(0x103)));
        string[2] memory templates = ["health-recovery", "health-claim"];
        for (uint256 i; i < templates.length; ++i) {
            string memory inputPath = string.concat("out/RecipeRecovery.O01-input-", templates[i], ".json");
            string memory outputPath = string.concat("out/RecipeRecovery.O01-output-", templates[i], ".json");
            vm.writeFile(inputPath, vm.readFile(string.concat("script/recipes/examples/", templates[i], ".json")));
            vm.writeJson('{"skipUnusedReads":true}', inputPath, ".optimizations");
            BuildRecipe(builder).run(inputPath, outputPath);
            string memory output = vm.readFile(outputPath);
            ExecutingRecipe.Recipe memory recipe;
            (recipe.queries, recipe.steps) = abi.decode(output.readBytes(".recipe"), (bytes[], bytes[]));
            bytes32 recipeHash = keccak256(abi.encode(recipe.queries, recipe.steps));
            assertEq(output.readBytes32(".recipeHash"), recipeHash);
            assertEq(output.readBytes32(".manifest.recipeHash"), recipeHash);
            assertEq(output.readUint(".stepCount"), recipe.steps.length);
            assertEq(output.readUintArray(".runtimeSteps"), ExecutingRecipe.runtimeSteps(recipe));
            uint256 approval = output.readUint(".approveStep");
            assertEq(
                uint256(uint8(recipe.steps[ExecutingRecipe.runtimeSteps(recipe)[approval]][0])), uint256(OP_APPROVE)
            );
            // Keep these illustrative artifacts under ignored out/ for inspection.
        }
    }

    function testFuzz_O01SourcePrefixCallsOnlyActivePostBalances(uint256 first, uint256 second) public {
        first = bound(first, 0, 50e6);
        second = bound(second, 0, 50e6);
        RecoveryMorphoVaultMock(_morpho).setCapacity(first);
        RecoveryAaveMock(_aave).setCapacity(second);
        _assertCashPrefix(false, first, second, 17e6);
    }

    function testFuzz_O01ClaimPrefixCallsOnlyActivePostBalances(uint256 first, uint256 second) public {
        first = bound(first, 0, 50e6);
        second = bound(second, 0, 50e6);
        RecoveryIssuerMock(_issuerA).seedPending(account, first);
        RecoveryIssuerMock(_issuerB).seedPending(account, second);
        RecoveryIssuerMock(_issuerA).setMatured(account, first);
        RecoveryIssuerMock(_issuerB).setMatured(account, second);
        _assertCashPrefix(true, first, second, 17e6);
    }

    function test_O01ZeroActiveClaimsStillRevertAfterOneCashCall() public {
        _assertCashPrefix(true, 0, 0, 17e6);
    }

    function test_O01SkippedFirstClaimCarriesFullWidthOldCash() public {
        uint256 oldCash = uint256(type(uint216).max) + 17e6;
        deal(_asset, account, oldCash);
        RecoveryIssuerMock(_issuerB).seedPending(account, 1);
        RecoveryIssuerMock(_issuerB).setMatured(account, 1);
        _assertCashPrefix(true, 0, 1, oldCash);
    }

    function testFuzz_O01FullRecoveryPreservesOldCash(uint256 first, uint256 second, bool skipReads, bool skipApprovals)
        public
    {
        first = bound(first, 0, 50e6);
        second = bound(second, 0, 50e6);
        _config.skipUnusedReads = skipReads;
        _config.skipZeroApprovals = skipApprovals;
        RecoveryMorphoVaultMock(_morpho).setCapacity(first);
        RecoveryAaveMock(_aave).setCapacity(second);
        uint256 gap = 100e6 - first - second;
        uint256 requestA = gap < 40e6 ? gap : 40e6;
        _recover(first, second, requestA, gap - requestA, first + second);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6 - first - second);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), requestA);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), gap - requestA);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
        assertEq(IERC20(_rwaA).allowance(account, _issuerA), 0);
        assertEq(IERC20(_rwaB).allowance(account, _issuerB), 0);
    }

    function testFuzz_O01BoundedPendingFreeClaimsPreserveSurplus(uint256 ready, uint256 cap, bool skipApprovals)
        public
    {
        ready = bound(ready, 1, 50e6);
        cap = bound(cap, 1, 50e6);
        uint256 selected = ready < cap ? ready : cap;
        _config.skipUnusedReads = true;
        _config.skipZeroApprovals = skipApprovals;
        _config.claims[0].maxAmount = cap;
        delete _config.claims[0].pending;
        RecoveryIssuerMock(_issuerA).seedPending(account, ready);
        RecoveryIssuerMock(_issuerA).setMatured(account, ready);
        RecoveryAaveMock(_aave).setPosition(0, 300e6);
        _claim(selected, 0, 0);
        assertEq(IERC20(_asset).balanceOf(account), 17e6 + selected);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), ready - selected);
        assertEq(RecoveryAaveMock(_aave).debt(account), 0);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
    }

    function test_O01ConditionalShortSourceStillRollsBack() public {
        _config.skipUnusedReads = true;
        RecoveryMorphoVaultMock(_morpho).setShortfall(1);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 30e6, 20e6, 40e6, 10e6, 50e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        _assertPristine();
    }

    function test_O01EmptyGroupsKeepOnePrefixCashRead() public {
        RecoveryRecipe.Config memory config = _config;
        config.skipUnusedReads = true;
        config.sources = new RecoveryRecipe.Source[](0);
        config.claims = new RecoveryRecipe.Claim[](0);
        (ExecutingRecipe.Recipe memory recovery, RecoveryRecipe.Layout memory recoveryLayout) =
            RecoveryRecipe.recovery(config);
        (ExecutingRecipe.Recipe memory claim, RecoveryRecipe.Layout memory claimLayout) = RecoveryRecipe.claim(config);
        (uint256 sourceReads,) = _cashReads(recovery, 0, ExecutingRecipe.runtimeSteps(recovery)[recoveryLayout.approve]);
        (uint256 claimReads,) = _cashReads(claim, 0, ExecutingRecipe.runtimeSteps(claim)[claimLayout.approve]);
        assertEq(sourceReads, 1);
        assertEq(claimReads, 1);
        RecipeExecutor(_executor).setRecipe(claim.queries, claim.steps);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        RecipeExecutor(_executor).execute(claim.queries, claim.steps, new uint256[](0), new bytes[](3));
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

    function test_ExistingLowerPriorityPendingIsCountedBeforeAnyNewRequest() public {
        RecoveryMorphoVaultMock(_morpho).setCapacity(0);
        RecoveryAaveMock(_aave).setCapacity(0);
        RecoveryIssuerMock(_issuerB).seedPending(account, 60e6);
        _recover(0, 0, 40e6, 0, 0);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 60e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6);
        assertEq(RecoveryAaveMock(_aave).healthFactor(account), 1e18);
    }

    function test_RepeatedRecoveryCannotDuplicatePendingRequests() public {
        _recover(30e6, 20e6, 40e6, 10e6, 50e6);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime = _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 0, 0, 0, 0, 0);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 10e6);
        assertEq(RecoveryTraceMock(_trace).count(), 5);
    }

    function testFuzz_CappedRecoveryQueuesUncoveredNeedAcrossRuns(bool skipUnusedReads) public {
        _config.maxRepayment = 40e6;
        _config.skipUnusedReads = skipUnusedReads;
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
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(IERC20(_rwaA).balanceOf(account), 960e18);
        assertEq(IERC20(_rwaB).balanceOf(account), 940e18);

        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime = _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 0, 0, 0, 0, 0);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 60e6);
        assertEq(RecoveryTraceMock(_trace).count(), 3);
    }

    function testFuzz_CappedRecoveryOnlyQueuesNeedUncoveredByPending(bool skipUnusedReads) public {
        _config.maxRepayment = 40e6;
        _config.skipUnusedReads = skipUnusedReads;
        RecoveryMorphoVaultMock(_morpho).setCapacity(0);
        RecoveryAaveMock(_aave).setCapacity(0);
        RecoveryIssuerMock(_issuerB).seedPending(account, 90e6);

        _recover(0, 0, 10e6, 0, 0);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 10e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 90e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(IERC20(_rwaA).balanceOf(account), 990e18);
    }

    function testFuzz_CappedRecoverySharesNewBudgetAfterPendingAndRepayment(bool skipUnusedReads) public {
        _config.maxRepayment = 60e6;
        _config.skipUnusedReads = skipUnusedReads;
        RecoveryIssuerMock(_issuerB).seedPending(account, 20e6);

        _recover(30e6, 20e6, 10e6, 0, 50e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 10e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 20e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 250e6);
        assertEq(RecoveryAaveMock(_aave).healthFactor(account), 1.2e18);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(IERC20(_rwaA).balanceOf(account), 990e18);
    }

    function test_PendingAboveGapIncludesMaturedUnclaimedPrincipalAndSaturates() public {
        RecoveryMorphoVaultMock(_morpho).setCapacity(0);
        RecoveryAaveMock(_aave).setCapacity(0);
        RecoveryIssuerMock(_issuerB).seedPending(account, 150e6);
        RecoveryIssuerMock(_issuerB).setMatured(account, 150e6);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime = _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 0, 0, 0, 0, 0);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 150e6);
        assertEq(RecoveryIssuerMock(_issuerB).claimable(account), 150e6);
        assertEq(RecoveryTraceMock(_trace).count(), 0);
    }

    function test_FullyCoveredFirstRedemptionSkipsLaterRedemption() public {
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

    function test_InsufficientTotalLiquidityMakesPartialProgress() public {
        RecoveryIssuerMock(_issuerA).setCapacity(7e6);
        RecoveryIssuerMock(_issuerB).setCapacity(3e6);
        _recover(30e6, 20e6, 7e6, 3e6, 50e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 250e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 7e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 3e6);
    }

    function test_RepaymentCapLimitsWithdrawalsAndLeavesNoRequestBudget() public {
        _config.maxRepayment = 40e6;
        _recover(30e6, 10e6, 0, 0, 40e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 260e6);
        assertEq(RecoveryAaveMock(_aave).capacity(account), 10e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 0);
    }

    function test_CapIsSharedBetweenFreshRepaymentAndRequests() public {
        _config.maxRepayment = 60e6;
        _recover(30e6, 20e6, 10e6, 0, 50e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 10e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 0);
    }

    function test_ProviderCannotSkipHigherPrioritySource() public {
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 0, 20e6, 40e6, 40e6, 20e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        _assertPristine();
    }

    function testFuzz_ProviderCannotChangeWithdrawalAmount(uint256 extra) public {
        extra = bound(extra, 1, 10e6);
        RecoveryMorphoVaultMock(_morpho).setCapacity(100e6 + extra);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 100e6 + extra, 0, 0, 0, 100e6);
        _execute(runtime);
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
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

    function test_UnexpectedDebtChangeRollsBackEverything() public {
        RecoveryAaveMock(_aave).setRepayEffects(-2, 0);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 30e6, 20e6, 40e6, 10e6, 50e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
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

    function test_CollateralWorseningCannotHideBehindDebtRepayment() public {
        RecoveryAaveMock(_aave).setRepayEffects(0, 150e6);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 30e6, 20e6, 40e6, 10e6, 50e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        _assertPristine();
    }

    function test_SourceInsufficientCashReceiptRollsBack() public {
        RecoveryMorphoVaultMock(_morpho).setShortfall(1);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 30e6, 20e6, 40e6, 10e6, 50e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        _assertPristine();
    }

    function test_RwaOverburnFailsEvenWithSufficientApprovalAndOldInventory() public {
        RecoveryIssuerMock(_issuerA).setRequestEffects(1, 0);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 30e6, 20e6, 40e6, 10e6, 50e6);
        IMerkleAccount.Action[] memory calls = abi.decode(runtime[layout.requestCalls[0]], (IMerkleAccount.Action[]));
        calls[0].data = abi.encodeCall(IERC20.approve, (_issuerA, 40e18 + 1));
        runtime[layout.requestCalls[0]] = abi.encode(calls);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        _assertPristine();
    }

    function test_OversizedApprovalWithoutZeroResetRollsBackRequest() public {
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 30e6, 20e6, 40e6, 10e6, 50e6);
        IMerkleAccount.Action[] memory calls = abi.decode(runtime[layout.requestCalls[0]], (IMerkleAccount.Action[]));
        calls[0].data = abi.encodeCall(IERC20.approve, (_issuerA, type(uint256).max));
        calls[2].data = abi.encodeCall(IERC20.approve, (_issuerA, 1));
        runtime[layout.requestCalls[0]] = abi.encode(calls);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        _assertPristine();
        assertEq(IERC20(_rwaA).allowance(account, _issuerA), 0);
    }

    function test_OptimizedClaimSkipsUnusedPendingAndKeepsFreshCashChecks() public {
        _config.skipUnusedReads = true;
        _config.skipZeroApprovals = true;
        RecoveryIssuerMock(_issuerA).seedPending(account, 50e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 50e6);
        vm.mockCallRevert(_issuerB, abi.encodeWithSignature("pending(address)", account), hex"deadbeef");
        _claim(50e6, 0, 50e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 250e6);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
    }

    function test_ZeroDebtClaimsAllMaturedCashWithoutHealthArithmeticOverflow() public {
        RecoveryAaveMock(_aave).setPosition(0, 300e6);
        RecoveryIssuerMock(_issuerA).seedPending(account, 1);
        RecoveryIssuerMock(_issuerA).setMatured(account, 1);
        _claim(1, 0, 0);
        assertEq(RecoveryAaveMock(_aave).debt(account), 0);
        assertEq(RecoveryAaveMock(_aave).healthFactor(account), type(uint256).max);
        assertEq(IERC20(_asset).balanceOf(account), 17e6 + 1);
    }

    function test_ClaimCannotSucceedWithZeroCashFromRateFloorRounding() public {
        _config.claims[0].minAssetPerClaimWad = 1;
        RecoveryIssuerMock(_issuerA).seedPending(account, 1);
        RecoveryIssuerMock(_issuerA).setMatured(account, 1);
        RecoveryIssuerMock(_issuerA).setClaimRate(1);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(_config);
        bytes[] memory runtime = _claimRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 1, 0, 0);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 1);
    }

    function test_RequestMustCreateTheExactPendingPrincipal() public {
        RecoveryIssuerMock(_issuerA).setRequestEffects(0, 1);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.recovery(_config);
        bytes[] memory runtime =
            _recoveryRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 30e6, 20e6, 40e6, 10e6, 50e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        _assertPristine();
    }

    function test_ClaimBeforeMaturityRevertsWithoutChangingPending() public {
        _recover(30e6, 20e6, 40e6, 10e6, 50e6);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(_config);
        bytes[] memory runtime = _claimRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 0, 0, 0);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 250e6);
    }

    function test_PartialSettlementThenLaterClaimRepaysAboveTrigger() public {
        _recover(30e6, 20e6, 40e6, 10e6, 50e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 20e6);
        _claim(20e6, 0, 20e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 20e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 230e6);
        assertGt(RecoveryAaveMock(_aave).healthFactor(account), _config.triggerHealthFactor);
        RecoveryIssuerMock(_issuerA).setMatured(account, 20e6);
        RecoveryIssuerMock(_issuerB).setMatured(account, 10e6);
        _claim(20e6, 10e6, 30e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 0);
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6);
        assertEq(RecoveryAaveMock(_aave).healthFactor(account), 1.5e18);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
    }

    /// forge-config: default.isolate = true
    function test_RepayUsesPreviouslySettledCashAndPreservesReserve() public {
        _recover(30e6, 20e6, 40e6, 10e6, 50e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 20e6);
        vm.prank(account);
        RecoveryIssuerMock(_issuerA).claim(20e6, account);
        vm.roll(block.number + 1);
        bytes[] memory runtime = _repayRuntime(17e6, 20e6);
        _execute(runtime);
        vm.snapshotGasLastCall("RecipeRecovery", "repaySettledCash");
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 230e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 20e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 10e6);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);

        // A later issuer payout can be repaid above the original recovery trigger.
        vm.prank(_issuerA);
        IERC20(_asset).transfer(account, 30e6);
        vm.roll(block.number + 1);
        _execute(runtime);
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(RecoveryAaveMock(_aave).healthFactor(account), 1.5e18);
    }

    function testFuzz_RepaySettledCashRespectsReserveAndRepaymentCap(uint256 cash, uint256 cap) public {
        cash = bound(cash, 1, 200e6);
        cap = bound(cap, 1, 200e6);
        _config.maxRepayment = cap;
        RecoveryTokenMock(_asset).mint(account, cash);
        uint256 expected = cash < cap ? cash : cap;
        if (expected > 100e6) expected = 100e6;
        _execute(_repayRuntime(17e6, expected));
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6 - expected);
        assertEq(IERC20(_asset).balanceOf(account), 17e6 + cash - expected);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
    }

    function test_RepaySettledCashRejectsNoAvailableCash() public {
        bytes[] memory runtime = _repayRuntime(17e6, 0);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        _assertPristine();
    }

    function test_RepaySettledCashRejectsZeroDebt() public {
        RecoveryAaveMock(_aave).setPosition(0, 300e6);
        bytes[] memory runtime = _repayRuntime(0, 0);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
    }

    function test_RepaySettledCashFailurePreservesEarlierPayout() public {
        RecoveryTokenMock(_asset).mint(account, 40e6);
        RecoveryAaveMock(_aave).setRepayFailure(true);
        bytes[] memory runtime = _repayRuntime(17e6, 40e6);
        vm.expectRevert(RecoveryAaveMock.RepayFailed.selector);
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(account), 57e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
    }

    function test_ClaimKeepsExcessCashAndPreservesExistingCash() public {
        _recover(30e6, 20e6, 40e6, 10e6, 50e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 40e6);
        RecoveryIssuerMock(_issuerB).setMatured(account, 10e6);
        RecoveryIssuerMock(_issuerA).setClaimRate(2e18);
        RecoveryIssuerMock(_issuerB).setClaimRate(2e18);
        _claim(40e6, 10e6, 50e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6);
        assertEq(IERC20(_asset).balanceOf(account), 67e6);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
    }

    function test_ClaimAtTargetSettlesAllPrincipalWithoutRepayingOldCash() public {
        RecoveryAaveMock(_aave).setPosition(200e6, 300e6);
        RecoveryIssuerMock(_issuerA).seedPending(account, 40e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 40e6);
        _claim(40e6, 0, 0);
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6);
        assertEq(IERC20(_asset).balanceOf(account), 57e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
    }

    function test_ClaimRepayFailureRollsBackIssuerSettlementAndCash() public {
        RecoveryIssuerMock(_issuerA).seedPending(account, 40e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 40e6);
        RecoveryAaveMock(_aave).setRepayFailure(true);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(_config);
        bytes[] memory runtime = _claimRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 40e6, 0, 40e6);
        vm.expectRevert(RecoveryAaveMock.RepayFailed.selector);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 40e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
    }

    function test_ClaimCashBelowCuratorRateRollsBackSettlement() public {
        RecoveryIssuerMock(_issuerA).seedPending(account, 40e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 40e6);
        RecoveryIssuerMock(_issuerA).setClaimRate(0.99e18);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(_config);
        bytes[] memory runtime = _claimRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 40e6, 0, 40e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 40e6);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
    }

    function test_ClaimMustSettleAllOnchainMaturedPrincipal() public {
        RecoveryIssuerMock(_issuerA).seedPending(account, 40e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 40e6);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(_config);
        bytes[] memory runtime = _claimRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 20e6, 0, 20e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
    }

    function testFuzz_BoundedClaimUsesSelectedPrincipalAndKeepsRemainder(uint256 maximum, bool skipUnusedReads) public {
        maximum = bound(maximum, 1, 50e6);
        _config.skipUnusedReads = skipUnusedReads;
        _config.claims[0].maxAmount = maximum;
        RecoveryIssuerMock(_issuerA).seedPending(account, 40e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 40e6);
        uint256 selected = maximum < 40e6 ? maximum : 40e6;
        _claim(selected, 0, selected);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6 - selected);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 40e6 - selected);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6 - selected);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
    }

    function test_BoundedClaimCannotConsumeMoreThanSelectedPrincipal() public {
        _config.claims[0].maxAmount = 20e6;
        RecoveryIssuerMock(_issuerA).seedPending(account, 40e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 40e6);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(_config);
        bytes[] memory runtime = _claimRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 40e6, 0, 40e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 40e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6);
    }

    function test_BoundedClaimStillEnforcesSelectedOutputMinimum() public {
        _config.claims[0].maxAmount = 20e6;
        RecoveryIssuerMock(_issuerA).seedPending(account, 40e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 40e6);
        RecoveryIssuerMock(_issuerA).setClaimRate(0.99e18);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(_config);
        bytes[] memory runtime = _claimRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 20e6, 0, 20e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 40e6);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
    }

    function testFuzz_PendingFreeClaimSupportsSettlementSeparatedAccounting(bool skipUnusedReads) public {
        _config.skipUnusedReads = skipUnusedReads;
        _config.claims[0].maxAmount = 20e6;
        delete _config.claims[0].pending;
        RecoveryIssuerMock(_issuerA).setSettlementSeparatesPending(true);
        RecoveryIssuerMock(_issuerA).seedPending(account, 40e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 40e6);
        vm.mockCallRevert(_issuerA, abi.encodeWithSignature("pending(address)", account), hex"deadbeef");
        _claim(20e6, 0, 20e6);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 20e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 280e6);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        vm.clearMockedCalls();
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
        _claim(20e6, 0, 20e6);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 0);
        assertEq(RecoveryAaveMock(_aave).debt(account), 260e6);
    }

    function test_PendingFreeClaimCannotConsumeMoreThanSelectedReadiness() public {
        _config.claims[0].maxAmount = 20e6;
        delete _config.claims[0].pending;
        RecoveryIssuerMock(_issuerA).setSettlementSeparatesPending(true);
        RecoveryIssuerMock(_issuerA).seedPending(account, 40e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 40e6);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(_config);
        bytes[] memory runtime = _claimRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 40e6, 0, 40e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 40e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
    }

    function test_PendingFreeClaimWithZeroDebtKeepsAllProceeds() public {
        RecoveryAaveMock(_aave).setPosition(0, 300e6);
        delete _config.claims[0].pending;
        RecoveryIssuerMock(_issuerA).setSettlementSeparatesPending(true);
        RecoveryIssuerMock(_issuerA).seedPending(account, 40e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 40e6);
        _claim(40e6, 0, 0);
        assertEq(RecoveryAaveMock(_aave).debt(account), 0);
        assertEq(IERC20(_asset).balanceOf(account), 57e6);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 0);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
    }

    function testFuzz_EmptyPendingTargetRejectsStrayQueryConfiguration(bool data) public {
        delete _config.claims[0].pending;
        if (data) _config.claims[0].pending.data = hex"deadbeef";
        else _config.claims[0].pending.offset = 1;
        vm.expectRevert(RecoveryRecipe.InvalidConfiguration.selector);
        this.buildClaim(_config);
    }

    function buildClaim(RecoveryRecipe.Config memory config) public pure {
        RecoveryRecipe.claim(config);
    }

    function testFuzz_ClaimRejectsPositionChangesBeforeRepayment(bool increasesDebt) public {
        RecoveryIssuerMock(_issuerA).seedPending(account, 40e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 40e6);
        RecoveryIssuerMock(_issuerA)
            .setClaimPosition(_aave, increasesDebt ? 301e6 : 300e6, increasesDebt ? 301e6 : 299e6);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(_config);
        bytes[] memory runtime = _claimRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 40e6, 0, 40e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 40e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6);
        assertEq(RecoveryAaveMock(_aave).healthFactor(account), 1e18);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
    }

    function testFuzz_RepaymentCapNeverSpendsOldCash(uint256 cap) public {
        cap = bound(cap, 1, 100e6);
        RecoveryMorphoVaultMock(_morpho).setCapacity(100e6);
        _config.maxRepayment = cap;
        _recover(cap, 0, 0, 0, cap);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6 - cap);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
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

    function _cashReads(ExecutingRecipe.Recipe memory recipe, uint256 start, uint256 end)
        internal
        view
        returns (uint256 count, uint256 last)
    {
        bytes32 queryHash = keccak256(
            abi.encode(_asset, abi.encodeCall(IERC20.balanceOf, (account)), new uint256[](0), uint256(0))
        );
        for (uint256 i = start; i < end; ++i) {
            uint8 operation = uint8(recipe.steps[i][0]);
            if (operation != OP_READ && operation != OP_READ_IF) continue;
            uint256 index;
            if (operation == OP_READ) index = abi.decode(Bytes.slice(recipe.steps[i], 1), (uint256));
            else (, index,) = abi.decode(Bytes.slice(recipe.steps[i], 1), (uint256, uint256, uint256));
            if (keccak256(recipe.queries[index]) == queryHash) {
                ++count;
                last = i;
            }
        }
    }

    function _assertCashPrefix(bool claimMode, uint256 first, uint256 second, uint256 oldCash) internal {
        _config.skipUnusedReads = true;
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) =
            claimMode ? RecoveryRecipe.claim(_config) : RecoveryRecipe.recovery(_config);
        uint256 end = ExecutingRecipe.runtimeSteps(recipe)[layout.approve];
        (, uint256 last) = _cashReads(recipe, 0, end);
        bytes[] memory steps = new bytes[](end);
        for (uint256 i; i < end; ++i) {
            steps[i] = recipe.steps[i];
        }
        bytes[] memory runtime = new bytes[](2);
        runtime[0] = first == 0
            ? bytes(hex"deadbeef")
            : claimMode
                ? _one(8, abi.encodeCall(RecoveryIssuerMock.claim, (first, account)))
                : _one(0, abi.encodeCall(RecoveryMorphoVaultMock.withdraw, (first, account, account)));
        runtime[1] = second == 0
            ? bytes(hex"deadbeef")
            : claimMode
                ? _one(9, abi.encodeCall(RecoveryIssuerMock.claim, (second, account)))
                : _one(1, abi.encodeCall(RecoveryAaveMock.withdraw, (_asset, second, account)));
        RecipeExecutor(_executor).setRecipe(recipe.queries, steps);
        vm.expectCall(
            _asset, abi.encodeCall(IERC20.balanceOf, (account)), uint64(1 + (first > 0 ? 1 : 0) + (second > 0 ? 1 : 0))
        );
        if (claimMode && first == 0 && second == 0) {
            vm.expectRevert(IRecipes.CheckFailed.selector);
            RecipeExecutor(_executor).execute(recipe.queries, steps, new uint256[](0), runtime);
        } else {
            uint256[] memory values =
                RecipeExecutor(_executor).execute(recipe.queries, steps, new uint256[](0), runtime);
            assertEq(values[last], oldCash + first + second);
        }
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
        _config.debtTolerance = 1;
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
            _config.redemptions[i].token = i == 0 ? _rwaA : _rwaB;
            _config.redemptions[i].spender = issuer;
            _config.redemptions[i].capacity = _read(issuer, abi.encodeCall(RecoveryIssuerMock.capacity, (account)));
            _config.redemptions[i].pending = _read(issuer, abi.encodeWithSignature("pending(address)", account));
            _config.redemptions[i].maxTokenPerAssetWad = 1e30;
            _config.redemptions[i].leaves.push(_leaf(4 + i * 2));
            _config.redemptions[i].leaves.push(_leaf(5 + i * 2));
            _config.redemptions[i].leaves.push(_leaf(4 + i * 2));
            _config.claims.push();
            _config.claims[i].claimable = _read(issuer, abi.encodeWithSignature("claimable(address)", account));
            _config.claims[i].pending = _config.redemptions[i].pending;
            _config.claims[i].minAssetPerClaimWad = 1e18;
            _config.claims[i].leaves.push(_leaf(8 + i));
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
        return MerkleAdapterVerifier.leaf(_actions[index].target, 0, _actions[index].data, _actions[index].dataMask);
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

    function _claimRuntime(
        uint256 length,
        RecoveryRecipe.Layout memory layout,
        uint256 amountA,
        uint256 amountB,
        uint256 repayAmount
    ) internal returns (bytes[] memory runtime) {
        runtime = _baseRuntime(length, layout, repayAmount);
        runtime[layout.claimCalls[0]] = _one(8, abi.encodeCall(RecoveryIssuerMock.claim, (amountA, account)));
        runtime[layout.claimCalls[1]] = _one(9, abi.encodeCall(RecoveryIssuerMock.claim, (amountB, account)));
        (ExecutingRecipe.Recipe memory recipe,) = RecoveryRecipe.claim(_config);
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

    function _repayRuntime(uint256 reserve, uint256 repayAmount) internal returns (bytes[] memory runtime) {
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) =
            RecoveryRecipe.repay(_config, reserve);
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

    function _claim(uint256 amountA, uint256 amountB, uint256 repayAmount) internal {
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(_config);
        _execute(_claimRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, amountA, amountB, repayAmount));
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
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
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
