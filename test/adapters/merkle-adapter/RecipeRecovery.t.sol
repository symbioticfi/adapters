// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {
    IRecipes,
    OP_APPROVE,
    OP_CALL,
    OP_EQUAL,
    OP_LESS_OR_EQUAL,
    OP_MANAGE,
    OP_MIN,
    OP_MUL_DIV,
    OP_READ,
    OP_SUB,
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

    function test_HealthClaimBindsAllMaturedAmountsDespiteWrongRuntime() public {
        RecoveryIssuerMock(_issuerA).seedPending(account, 50e6);
        RecoveryIssuerMock(_issuerB).seedPending(account, 50e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 50e6);
        RecoveryIssuerMock(_issuerB).setMatured(account, 50e6);
        _claim(1, 1, 100e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 0);
    }

    function test_ZeroStaticClaimRateStillRequiresPositiveCash() public {
        _config.claims[0].minAssetPerClaimWad = 0;
        RecoveryIssuerMock(_issuerA).seedPending(account, 40e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 40e6);
        RecoveryIssuerMock(_issuerA).setClaimRate(0);
        RecoveryIssuerMock(_issuerB).seedPending(account, 10e6);
        RecoveryIssuerMock(_issuerB).setMatured(account, 10e6);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(_config);
        bytes[] memory runtime = _claimRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 1, 1, 0);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        RecoveryIssuerMock(_issuerA).setClaimRate(1e18);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
    }

    function test_ZeroLiveMinimumStillRequiresPositiveCash() public {
        _config.claims[0].minAssetPerClaimWad = 1e18;
        _config.claims[0].minimum = _read(_asset, abi.encodeCall(IERC20.balanceOf, (address(0xBEEF))));
        RecoveryIssuerMock(_issuerA).seedPending(account, 40e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 40e6);
        RecoveryIssuerMock(_issuerA).setClaimRate(0);
        RecoveryIssuerMock(_issuerB).seedPending(account, 10e6);
        RecoveryIssuerMock(_issuerB).setMatured(account, 10e6);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(_config);
        bytes[] memory runtime = _claimRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 1, 1, 0);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
    }

    function test_HealthClaimSelectedIdChecksSameLedgerThenRefreshesNextGroup() public {
        RecoveryAaveMock(_aave).setPosition(0, 300e6);
        address queue = address(new RecoverySelectedIssuer(_asset));
        RecoverySelectedIssuer(queue).seed(0, 7);
        RecoverySelectedIssuer(queue).seed(17, 11);
        IMerkleAccount.Action memory action =
            _action(queue, abi.encodeCall(RecoverySelectedIssuer.claim, (999, 1, account)), 4);
        for (uint256 i = 36; i < 68; ++i) {
            action.dataMask[i] = 0xff;
        }
        bytes32 leaf = ActionMasker.mask(queue, 0, action.data, action.dataMask);
        bytes32 approval = _config.approvalLeaf;
        bytes32 root =
            leaf < approval ? keccak256(abi.encodePacked(leaf, approval)) : keccak256(abi.encodePacked(approval, leaf));
        roots.setRoot(account, root);
        MerkleAccount(payable(account)).acceptRoot(root);
        MerkleAccount(payable(account)).grantRole(leaf, _executor);
        action.proof = new bytes32[](1);
        action.proof[0] = approval;
        _actions[2].proof = new bytes32[](1);
        _actions[2].proof[0] = leaf;
        RecoveryRecipe.Config memory config = _config;
        RecoveryRecipe.Claim memory claim = config.claims[0];
        delete claim.pending;
        claim.selectedId = _read(queue, abi.encodeCall(RecoverySelectedIssuer.next, (account)));
        claim.claimable = _read(queue, abi.encodeCall(RecoverySelectedIssuer.ready, (account, 999)));
        claim.claimableIdOffsets = new uint256[](1);
        claim.claimableIdOffsets[0] = 36;
        claim.idOffsets = new uint256[][](1);
        claim.idOffsets[0] = new uint256[](1);
        claim.idOffsets[0][0] = 4;
        claim.amountOffsets[0][0] = 36;
        claim.leaves[0] = leaf;
        config.claims = new RecoveryRecipe.Claim[](2);
        config.claims[0] = claim;
        config.claims[1] = claim;
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(config);
        bytes[] memory runtime = _baseRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 0);
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = action;
        runtime[layout.claimCalls[0]] = abi.encode(actions);
        runtime[layout.claimCalls[1]] = runtime[layout.claimCalls[0]];
        _recipe = abi.encode(recipe.queries, recipe.steps);
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(account), 17e6 + 18);
        assertEq(RecoverySelectedIssuer(queue).ready(account, 0), 0);
        assertEq(RecoverySelectedIssuer(queue).ready(account, 17), 0);
        RecoverySelectedIssuer(queue).seed(203, 5);
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(account), 17e6 + 23);
    }

    /// forge-config: default.isolate = true
    function test_GasO09BoundedIdentityHealthClaim() public {
        _config.skipUnusedReads = true;
        _config.claims[0].maxAmount = 20e6;
        _config.claims[1].maxAmount = 20e6;
        RecoveryIssuerMock(_issuerA).seedPending(account, 50e6);
        RecoveryIssuerMock(_issuerB).seedPending(account, 50e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 50e6);
        RecoveryIssuerMock(_issuerB).setMatured(account, 50e6);
        _claim(20e6, 20e6, 40e6);
        vm.snapshotGasLastCall("RecipeRecovery", "O09BoundedIdentityHealthClaim");
        assertEq(RecoveryAaveMock(_aave).debt(account), 260e6);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 30e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 30e6);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 30e6);
        assertEq(RecoveryIssuerMock(_issuerB).claimable(account), 30e6);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
        assertEq(RecoveryTraceMock(_trace).count(), 3);
    }

    function test_O09SemanticRecordModeSizes() public {
        for (uint256 mode; mode < 4; ++mode) {
            RecoveryRecipe.Config memory config = _config;
            config.skipUnusedReads = mode % 2 == 1;
            config.claims[0].maxAmount = 20e6;
            config.claims[1].maxAmount = 20e6;
            if (mode >= 2) {
                delete config.claims[0].pending;
                delete config.claims[1].pending;
            }
            (ExecutingRecipe.Recipe memory recipe,) = RecoveryRecipe.claim(config);
            emit log_named_uint("O09 health mode", mode);
            emit log_named_uint("O09 health steps", recipe.steps.length);
            emit log_named_uint("O09 health bytes", abi.encode(recipe.queries, recipe.steps).length);
            _assertO09Queries(recipe, mode >= 2);
        }
    }

    function test_O09SemanticHealthThresholdAndUncappedOverflow() public {
        uint256 threshold = type(uint256).max / 1e18;
        _prefixO09(type(uint256).max, threshold, 1e18, false);
        _prefixO09(threshold, threshold + 1, 1e18, false);
        _prefixO09(threshold + 1, threshold + 1, 1e18, true);
        _prefixO09(threshold + 1, 0, 1e18, true);
        _prefixO09(0, 3, 1e18, false);
        _prefixO09(1, 3, 1e18, false);
        _prefixO09(3, 3, 1e18, false);
        _prefixO09(4, 3, 1e18, false);
        _prefixO09(type(uint256).max, 3, 1e18, false);
        _prefixO09(2, 3, 1e18 - 1, false);
        _prefixO09(2, 3, 1e18 + 1, false);
    }

    function testFuzz_O09SemanticHealthFullWidthReadiness(uint256 ready, uint64 cap) public {
        _prefixO09(ready, bound(cap, 1, 1000), 1e18, false);
    }

    function test_O09SemanticHealthLiteralWidthsAndErrorOrder() public {
        uint256 invalid = uint256(type(uint216).max) + 1;
        _config.claims[0].maxAmount = invalid;
        vm.expectRevert(abi.encodeWithSignature("SafeCastOverflowedUintDowncast(uint8,uint256)", uint8(216), invalid));
        this.buildClaim(_config);
        _config.claims[0].minAssetPerClaimWad = 1e18;
        delete _config.claims[0].pending;
        _config.claims[0].pending.data = hex"deadbeef";
        // ClaimRecipe rejects a targetless pending read before it encodes any literal.
        vm.expectRevert(RecoveryRecipe.InvalidConfiguration.selector);
        this.buildClaim(_config);
        _config.claims[0].maxAmount = 1;
        _config.claims[0].minAssetPerClaimWad = invalid;
        vm.expectRevert(RecoveryRecipe.InvalidConfiguration.selector);
        this.buildClaim(_config);
        delete _config.claims[0].pending;
        vm.expectRevert(abi.encodeWithSignature("SafeCastOverflowedUintDowncast(uint8,uint256)", uint8(216), invalid));
        this.buildClaim(_config);
    }

    function testFuzz_O09SemanticAccountingModesSurplusAndRepeat(bool pendingFree, bool skipReads) public {
        _config.skipUnusedReads = skipReads;
        _config.maxRepayment = 10e6;
        for (uint256 i; i < 2; ++i) {
            address issuer = i == 0 ? _issuerA : _issuerB;
            _config.claims[i].maxAmount = 20e6;
            if (pendingFree) {
                delete _config.claims[i].pending;
                RecoveryIssuerMock(issuer).setSettlementSeparatesPending(true);
            }
            RecoveryIssuerMock(issuer).seedPending(account, 50e6);
            RecoveryIssuerMock(issuer).setMatured(account, 50e6);
        }
        _claim(20e6, 20e6, 10e6);
        assertEq(IERC20(_asset).balanceOf(account), 47e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 290e6);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 30e6);
        assertEq(RecoveryIssuerMock(_issuerB).claimable(account), 30e6);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
        _claim(20e6, 20e6, 10e6);
        assertEq(IERC20(_asset).balanceOf(account), 77e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 280e6);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 10e6);
        assertEq(RecoveryIssuerMock(_issuerB).claimable(account), 10e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), pendingFree ? 0 : 10e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), pendingFree ? 0 : 10e6);
    }

    function testFuzz_O09SemanticZeroDebtAndFailedRepayment(bool skipReads) public {
        _config.skipUnusedReads = skipReads;
        _config.claims[0].maxAmount = 20e6;
        RecoveryIssuerMock(_issuerA).seedPending(account, 50e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 50e6);
        RecoveryAaveMock(_aave).setRepayFailure(true);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(_config);
        bytes[] memory runtime = _claimRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 20e6, 0, 20e6);
        vm.expectRevert(RecoveryAaveMock.RepayFailed.selector);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 50e6);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
        RecoveryAaveMock(_aave).setRepayFailure(false);
        RecoveryAaveMock(_aave).setPosition(0, 300e6);
        _claim(20e6, 0, 0);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 30e6);
        assertEq(IERC20(_asset).balanceOf(account), 37e6);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
    }

    function testFuzz_O09SemanticShortPayoutRollsBackPriorClaim(bool skipReads) public {
        _config.skipUnusedReads = skipReads;
        _config.claims[0].maxAmount = 20e6;
        _config.claims[1].maxAmount = 20e6;
        RecoveryIssuerMock(_issuerA).seedPending(account, 50e6);
        RecoveryIssuerMock(_issuerB).seedPending(account, 50e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 50e6);
        RecoveryIssuerMock(_issuerB).setMatured(account, 50e6);
        RecoveryIssuerMock(_issuerB).setClaimRate(0.99e18);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(_config);
        bytes[] memory runtime = _claimRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 20e6, 20e6, 40e6);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 50e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 50e6);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 50e6);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(RecoveryTraceMock(_trace).count(), 0);
    }

    function testFuzz_O09SemanticExactDebitAndQueryRuntimeFailures(bool pendingFree, bool skipReads, bool overclaim)
        public
    {
        _config.skipUnusedReads = skipReads;
        _config.claims[0].maxAmount = 20e6;
        if (pendingFree) {
            delete _config.claims[0].pending;
            RecoveryIssuerMock(_issuerA).setSettlementSeparatesPending(true);
        }
        RecoveryIssuerMock(_issuerA).seedPending(account, 50e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 50e6);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(_config);
        bytes[] memory runtime = _claimRuntime(
            ExecutingRecipe.runtimeSteps(recipe).length, layout, overclaim ? 20e6 + 1 : 20e6 - 1, 0, 20e6
        );
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 30e6);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        runtime = _claimRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 20e6, 0, 20e6);
        vm.mockCallRevert(_issuerA, abi.encodeWithSignature("claimable(address)", account), hex"12345678");
        vm.expectRevert(bytes(hex"12345678"));
        _execute(runtime);
        vm.clearMockedCalls();
        runtime[0] = hex"deadbeef";
        vm.expectRevert(bytes(""));
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 30e6);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
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

    function test_FullWidthRecipes() public {
        _emptyAsset();
        RecoveryTokenMock(_asset).mint(account, type(uint256).max - 20e6);
        RecoveryTokenMock(_asset).mint(_issuerA, 20e6);
        RecoveryIssuerMock(_issuerA).seedPending(account, 20e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 20e6);
        _expectClaim(20e6, 0, 20e6, true, "");
        assertEq(IERC20(_asset).balanceOf(account), type(uint256).max - 20e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 280e6);
        _emptyAsset();
        RecoveryTokenMock(_asset).mint(account, type(uint256).max);
        RecoveryAaveMock(_aave).setPosition(300e6, 300e6);
        _expectRepay(100e6, true, "");
        assertEq(IERC20(_asset).balanceOf(account), type(uint256).max - 100e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6);
    }

    function testFuzz_FullWidthCash(uint256 cash, bool skipReads) public {
        _config.skipUnusedReads = skipReads;
        _emptyAsset();
        RecoveryTokenMock(_asset).mint(account, cash);
        uint256 amount = cash;
        if (amount > 100e6) amount = 100e6;
        _expectRepay(amount, amount > 0, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
        assertEq(IERC20(_asset).balanceOf(account), cash - amount);
    }

    function testFuzz_SettlementModes(bool skipReads, bool pendingFree, uint8 budget) public {
        _config.skipUnusedReads = skipReads;
        _config.maxRepayment = bound(budget, 1, 40) * 1e6;
        for (uint256 i; i < 2; ++i) {
            address issuer = i == 0 ? _issuerA : _issuerB;
            _config.claims[i].maxAmount = 20e6;
            if (pendingFree) {
                delete _config.claims[i].pending;
                RecoveryIssuerMock(issuer).setSettlementSeparatesPending(true);
            }
            RecoveryIssuerMock(issuer).seedPending(account, 50e6);
            RecoveryIssuerMock(issuer).setMatured(account, 50e6);
        }
        _expectClaim(20e6, 20e6, _config.maxRepayment, true, "");
        assertEq(IERC20(_asset).balanceOf(account), 57e6 - _config.maxRepayment);
        _expectClaim(20e6, 20e6, _config.maxRepayment, true, "");
        assertEq(IERC20(_asset).balanceOf(account), 97e6 - 2 * _config.maxRepayment);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6 - 2 * _config.maxRepayment);
    }

    function test_VolatileCashStillRequiresConservation() public {
        _volatileFailure();
    }

    function test_AliasedCashQueryStillRequiresConservation() public {
        _config.healthFactor = _read(_asset, abi.encodeCall(IERC20.balanceOf, (account)));
        _volatileFailure();
    }

    function _volatileFailure() internal {
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.repay(_config);
        bytes[] memory runtime = _runtime(recipe, layout, false, 0, 0, 17e6);
        bytes32 initial = _effectsHash();
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        bytes[] memory cash = new bytes[](4);
        cash[0] = abi.encode(uint256(17e6));
        cash[1] = abi.encode(uint256(2));
        cash[2] = abi.encode(uint256(2));
        cash[3] = abi.encode(uint256(2));
        vm.mockCalls(_asset, abi.encodeCall(IERC20.balanceOf, (account)), cash);
        (bool ok, bytes memory result) = _executor.call(
            abi.encodeCall(RecipeExecutor.execute, (recipe.queries, recipe.steps, new uint256[](0), runtime))
        );
        vm.clearMockedCalls();
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
        assertEq(_effectsHash(), initial, "volatile observations cannot bypass conservation checks");
    }

    function test_ZeroNeedAndEmptyClaims() public {
        RecoveryAaveMock(_aave).setPosition(200e6, 300e6);
        RecoveryIssuerMock(_issuerA).seedPending(account, 20e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 20e6);
        _expectClaim(20e6, 0, 0, true, "");
        assertEq(IERC20(_asset).balanceOf(account), 37e6);
        _expectClaim(0, 0, 0, false, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
        delete _config.claims;
        _expectClaim(0, 0, 0, false, abi.encodeWithSelector(IRecipes.CheckFailed.selector));
    }

    function testFuzz_RuntimeAndProtocolFailures(uint8 failure, bool skipReads) public {
        _config.skipUnusedReads = skipReads;
        RecoveryIssuerMock(_issuerA).seedPending(account, 20e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 20e6);
        uint256 selected = failure % 6;
        if (selected == 5) _config.claims[0].claimable.data = hex"ffffffff";
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(_config);
        bytes[] memory runtime = _runtime(recipe, layout, true, 20e6, 0, 20e6);
        bytes memory expected = abi.encodeWithSelector(IRecipes.CheckFailed.selector);
        if (selected < 2) {
            runtime[layout.claimCalls[0]] =
                _one(8, abi.encodeCall(RecoveryIssuerMock.claim, (selected == 0 ? 20e6 - 1 : 20e6 + 1, account)));
            if (selected == 1) expected = abi.encodeWithSignature("Panic(uint256)", 0x11);
        } else if (selected == 2) {
            runtime[layout.claimCalls[0]] = hex"deadbeef";
            expected = "";
        } else if (selected == 3) {
            IMerkleAccount.Action[] memory calls = abi.decode(runtime[layout.claimCalls[0]], (IMerkleAccount.Action[]));
            calls[0].proof[0] = bytes32(uint256(123));
            runtime[layout.claimCalls[0]] = abi.encode(calls);
            expected = abi.encodeWithSelector(IMerkleAccount.InvalidMerkleProof.selector);
        } else if (selected == 4) {
            RecoveryAaveMock(_aave).setRepayFailure(true);
            expected = abi.encodeWithSelector(RecoveryAaveMock.RepayFailed.selector);
        } else {
            vm.mockCallRevert(_issuerA, bytes(hex"ffffffff"), bytes(hex"12345678"));
            expected = hex"12345678";
        }
        _assertExecution(recipe, layout, runtime, selected < 2, expected);
        vm.clearMockedCalls();
    }

    function testFuzz_EffectsAndRollback(uint8 effect, bool skipReads) public {
        _effectsCase(effect % 3 + 4, skipReads);
    }

    function test_RepaymentCallbackBarrier() public {
        // Approval-side balance mutations are outside the recipe's ERC20 assumptions.
        for (uint256 effect = 4; effect < 7; ++effect) {
            uint256 saved = vm.snapshotState();
            _effectsCase(effect, true);
            assertTrue(vm.revertToState(saved));
        }
    }

    function _effectsCase(uint256 effect, bool skipReads) internal {
        _rebindEffects();
        _config.skipUnusedReads = skipReads;
        uint256 selected = effect;
        RecoveryEffectTokenMock(_asset).setEffects(account, _aave, _executor, selected);
        RecoveryIssuerMock(_issuerA).seedPending(account, 20e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 20e6);
        bytes memory expected = selected == 6
            ? abi.encodeWithSignature("ReentrancyGuardReentrantCall()")
            : abi.encodeWithSelector(IRecipes.CheckFailed.selector);
        _expectClaim(20e6, 0, 20e6, false, expected);
        assertEq(RecoveryEffectTokenMock(_asset).effectCount(), 0, "callback effects rolled back");
        _config.maxRepayment = 16e6;
        _expectRepay(16e6, false, expected);
        assertEq(RecoveryEffectTokenMock(_asset).effectCount(), 0, "repay effects rolled back");
    }

    function _runtime(
        ExecutingRecipe.Recipe memory recipe,
        RecoveryRecipe.Layout memory layout,
        bool claim,
        uint256 amountA,
        uint256 amountB,
        uint256 amount
    ) internal view returns (bytes[] memory runtime) {
        runtime = _baseRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, amount);
        if (claim) {
            if (layout.claimCalls.length > 0) {
                runtime[layout.claimCalls[0]] = _one(8, abi.encodeCall(RecoveryIssuerMock.claim, (amountA, account)));
            }
            if (layout.claimCalls.length > 1) {
                runtime[layout.claimCalls[1]] = _one(9, abi.encodeCall(RecoveryIssuerMock.claim, (amountB, account)));
            }
        }
    }

    function _expectClaim(uint256 amountA, uint256 amountB, uint256 amount, bool succeeds, bytes memory errorData)
        internal
    {
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(_config);
        _assertExecution(recipe, layout, _runtime(recipe, layout, true, amountA, amountB, amount), succeeds, errorData);
    }

    function _expectRepay(uint256 amount, bool succeeds, bytes memory errorData) internal {
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.repay(_config);
        _assertExecution(recipe, layout, _runtime(recipe, layout, false, 0, 0, amount), succeeds, errorData);
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

    function _wordO09(bytes memory step, uint256 offset) internal pure returns (uint256 word) {
        assembly ("memory-safe") { word := mload(add(add(step, 32), offset)) }
    }

    function _assertO09Queries(ExecutingRecipe.Recipe memory recipe, bool pendingFree) internal view {
        assertEq(recipe.queries.length, pendingFree ? 5 : 7);
        assertEq(
            recipe.queries[0],
            abi.encode(_aave, abi.encodeCall(RecoveryAaveMock.healthFactor, (account)), new uint256[](0), uint256(0))
        );
        assertEq(
            recipe.queries[1],
            abi.encode(_aave, abi.encodeCall(RecoveryAaveMock.debt, (account)), new uint256[](0), uint256(0))
        );
        assertEq(
            recipe.queries[2],
            abi.encode(_asset, abi.encodeCall(IERC20.balanceOf, (account)), new uint256[](0), uint256(0))
        );
        for (uint256 i; i < 2; ++i) {
            address issuer = i == 0 ? _issuerA : _issuerB;
            uint256 index = 3 + i * (pendingFree ? 1 : 2);
            assertEq(
                recipe.queries[index],
                abi.encode(issuer, abi.encodeWithSignature("claimable(address)", account), new uint256[](0), uint256(0))
            );
            if (!pendingFree) {
                assertEq(
                    recipe.queries[index + 1],
                    abi.encode(
                        issuer, abi.encodeWithSignature("pending(address)", account), new uint256[](0), uint256(0)
                    )
                );
            }
        }
    }

    function _prefixO09(uint256 ready, uint256 cap, uint256 rate, bool overflow) internal {
        address lens = address(new RecoveryO09Lens(ready));
        RecoveryRecipe.Config memory config = _config;
        config.asset = lens;
        config.healthFactor = _read(lens, abi.encodeCall(RecoveryO09Lens.health, ()));
        config.debt = _read(lens, abi.encodeCall(RecoveryO09Lens.debt, ()));
        config.claims = new RecoveryRecipe.Claim[](1);
        config.claims[0] = RecoveryRecipe.Claim({
            amountOffsets: _config.claims[0].amountOffsets,
            selectedId: RecoveryRecipe.Read({target: address(0), data: "", offset: 0}),
            claimableIdOffsets: new uint256[](0),
            pendingIdOffsets: new uint256[](0),
            idOffsets: new uint256[][](0),
            minimum: RecoveryRecipe.Read({target: address(0), data: "", offset: 0}),
            claimable: _read(lens, abi.encodeWithSignature("ready()")),
            pending: RecoveryRecipe.Read({target: address(0), data: "", offset: 0}),
            maxAmount: cap,
            minAssetPerClaimWad: rate,
            leaves: _config.claims[0].leaves
        });
        (ExecutingRecipe.Recipe memory recipe,) = RecoveryRecipe.claim(config);
        uint256 end = ExecutingRecipe.runtimeSteps(recipe)[0];
        uint256 operand = _wordO09(recipe.steps[end], 1);
        // The claim minimum follows the claim call; evaluate a copy of it in place of the call.
        bytes[] memory steps = new bytes[](end + 2);
        uint256 originalMinimum = operand;
        for (uint256 i; i < end; ++i) {
            steps[i] = recipe.steps[i];
        }
        steps[end] = bytes.concat(bytes1(OP_MUL_DIV), abi.encode(operand, rate, uint256(1e18)));
        steps[end + 1] = steps[end];
        for (uint256 i = end + 1; i < recipe.steps.length; ++i) {
            if (uint8(recipe.steps[i][0]) == OP_MUL_DIV && _wordO09(recipe.steps[i], 1) == operand) {
                steps[end + 1] = recipe.steps[i];
                originalMinimum = ExecutingRecipe.result(end + 1);
                break;
            }
        }
        RecipeExecutor(_executor).setRecipe(recipe.queries, steps);
        if (overflow) {
            assertTrue(originalMinimum != operand, "unsafe or uncapped claim must retain its product");
            vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
            RecipeExecutor(_executor).execute(recipe.queries, steps, new uint256[](0), new bytes[](0));
        } else {
            uint256[] memory values =
                RecipeExecutor(_executor).execute(recipe.queries, steps, new uint256[](0), new bytes[](0));
            uint256 selected = cap > 0 && cap < ready ? cap : ready;
            assertEq(values[uint216(operand)], selected);
            assertEq(values[end], selected * rate / 1e18);
            assertEq(values[uint216(originalMinimum)], values[end]);
        }
    }

    function test_O05SemanticRecordRecipeControls() public {
        RecoveryRecipe.Config memory config = _config;
        (ExecutingRecipe.Recipe memory recovery,) = RecoveryRecipe.recovery(config);
        (ExecutingRecipe.Recipe memory claim,) = RecoveryRecipe.claim(config);
        (ExecutingRecipe.Recipe memory repay,) = RecoveryRecipe.repay(config);
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

    function testFuzz_O05SemanticTriggerBoundaries(uint8 boundary, bool skipReads) public withoutCash {
        uint256[4] memory collateral = [uint256(0), 600e6, 750e6, 750e6 + 1];
        uint256 selected = boundary % 4;
        _config.skipUnusedReads = skipReads;
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
        _config.skipUnusedReads = true;
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

    function test_OptimizedRecoveryStillCountsLowerPriorityPending() public withoutCash {
        _config.skipUnusedReads = true;
        RecoveryMorphoVaultMock(_morpho).setCapacity(0);
        RecoveryAaveMock(_aave).setCapacity(0);
        RecoveryIssuerMock(_issuerB).seedPending(account, 60e6);
        _recover(0, 0, 40e6, 0, 0);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 60e6);
    }

    function test_OptimizedRecoveryPreservesPartialProgress() public withoutCash {
        _config.skipUnusedReads = true;
        RecoveryIssuerMock(_issuerA).setCapacity(0);
        RecoveryIssuerMock(_issuerB).setCapacity(0);
        _recover(30e6, 20e6, 0, 0, 50e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 250e6);
        assertEq(RecoveryAaveMock(_aave).healthFactor(account), 1.2e18);
        assertEq(IERC20(_asset).balanceOf(account), 0);
    }

    /// forge-config: default.isolate = true
    function test_GasOptimizedFullyFundedRecovery() public {
        RecoveryMorphoVaultMock(_morpho).setCapacity(200e6);
        uint256 state = vm.snapshotState();
        _recover(100e6, 0, 0, 0, 100e6);
        uint256 originalGas = vm.snapshotGasLastCall("RecipeRecovery", "fullyFundedUnconditional");
        assertTrue(vm.revertToState(state));
        _config.skipUnusedReads = true;
        _recover(100e6, 0, 0, 0, 100e6);
        uint256 optimizedGas = vm.snapshotGasLastCall("RecipeRecovery", "fullyFundedConditional");
        assertGt(optimizedGas, originalGas);
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6);
        assertEq(RecoveryTraceMock(_trace).count(), 2);
        emit log_named_uint("fully-funded recovery additional gas", optimizedGas - originalGas);
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
        // ClaimRecipe omits one positive-output check per claim when its static minimum already implies it.
        assertEq(fractional.steps.length - qualifying.steps.length, 2, "steps");
        assertEq(
            abi.encode(fractional.queries, fractional.steps).length
                - abi.encode(qualifying.queries, qualifying.steps).length,
            320,
            "bytes"
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
    function test_GasO01TwoActiveSources() public withoutCash {
        _config.skipUnusedReads = true;
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
    function test_GasO01OneActiveGroup() public withoutCash {
        _config.skipUnusedReads = true;
        RecoveryMorphoVaultMock(_morpho).setCapacity(100e6);
        _recover(100e6, 0, 0, 0, 100e6);
        vm.snapshotGasLastCall("RecipeRecovery", "O01OneActiveGroup");
        assertEq(RecoveryAaveMock(_aave).debt(account), 200e6);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).allowance(account, _aave), 0);
        assertEq(RecoveryTraceMock(_trace).count(), 2);
    }

    function test_O01ConditionalJsonArtifactsMatchRecipeAndLayout() public {
        address builder = deployCode("BuildRecipe.s.sol:BuildRecipe");
        vm.mockCall(address(0x103), abi.encodeCall(IMerkleAdapter.account, ()), abi.encode(address(0x104)));
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
        second = second < 83e6 - first ? second : 83e6 - first;
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

    function testFuzz_O01FullRecoverySpendsCashBeforeSources(uint256 first, uint256 second, bool skipReads) public {
        first = bound(first, 0, 50e6);
        second = bound(second, 0, 50e6);
        _config.skipUnusedReads = skipReads;
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

    function testFuzz_O01BoundedPendingFreeClaimsPreserveSurplus(uint256 ready, uint256 cap) public {
        ready = bound(ready, 1, 50e6);
        cap = bound(cap, 1, 50e6);
        uint256 selected = ready < cap ? ready : cap;
        _config.skipUnusedReads = true;
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
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryIssuerMock(_issuerB).pending(account), 10e6);
        assertEq(RecoveryTraceMock(_trace).count(), 5);
    }

    function testFuzz_CappedRecoveryQueuesUncoveredNeedAcrossRuns(bool skipUnusedReads) public withoutCash {
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
        assertEq(IERC20(_asset).balanceOf(account), 0);
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

    function testFuzz_CappedRecoveryOnlyQueuesNeedUncoveredByPending(bool skipUnusedReads) public withoutCash {
        _config.maxRepayment = 40e6;
        _config.skipUnusedReads = skipUnusedReads;
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

    function testFuzz_CappedRecoverySharesNewBudgetAfterPendingAndRepayment(bool skipUnusedReads) public withoutCash {
        _config.maxRepayment = 60e6;
        _config.skipUnusedReads = skipUnusedReads;
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
        vm.expectRevert(IRecipes.CheckFailed.selector);
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

    function test_ClaimRequiresReadablePendingQueries() public {
        _config.skipUnusedReads = true;
        RecoveryIssuerMock(_issuerA).seedPending(account, 50e6);
        RecoveryIssuerMock(_issuerA).setMatured(account, 50e6);
        vm.mockCallRevert(_issuerB, abi.encodeWithSignature("pending(address)", account), hex"deadbeef");
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(_config);
        bytes[] memory runtime = _claimRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 50e6, 0, 50e6);
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(bytes4(0xdeadbeef));
        RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](0), runtime);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6);
        assertEq(IERC20(_asset).balanceOf(account), 17e6);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 50e6);
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

    function test_ClaimBeforeMaturityRevertsWithoutChangingPending() public withoutCash {
        _recover(30e6, 20e6, 40e6, 10e6, 50e6);
        (ExecutingRecipe.Recipe memory recipe, RecoveryRecipe.Layout memory layout) = RecoveryRecipe.claim(_config);
        bytes[] memory runtime = _claimRuntime(ExecutingRecipe.runtimeSteps(recipe).length, layout, 0, 0, 0);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 40e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 250e6);
    }

    function test_PartialSettlementThenLaterClaimRepaysAboveTrigger() public withoutCash {
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
        assertEq(IERC20(_asset).balanceOf(account), 0);
    }

    /// forge-config: default.isolate = true
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

    function test_RepaySettledCashRejectsNoAvailableCash() public {
        vm.prank(account);
        IERC20(_asset).transfer(_issuerA, 17e6);
        bytes[] memory runtime = _repayRuntime(0);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(RecoveryAaveMock(_aave).debt(account), 300e6);
    }

    function test_RepaySettledCashRejectsZeroDebt() public {
        RecoveryAaveMock(_aave).setPosition(0, 300e6);
        bytes[] memory runtime = _repayRuntime(0);
        vm.expectRevert(IRecipes.CheckFailed.selector);
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

    function test_ClaimKeepsExcessCashAndPreservesExistingCash() public {
        RecoveryAaveMock(_aave).setPosition(250e6, 300e6);
        RecoveryIssuerMock(_issuerA).seedPending(account, 40e6);
        RecoveryIssuerMock(_issuerB).seedPending(account, 10e6);
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
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
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
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 20e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 280e6);
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
        _execute(runtime);
        assertEq(RecoveryIssuerMock(_issuerA).pending(account), 0);
        assertEq(RecoveryIssuerMock(_issuerA).claimable(account), 20e6);
        assertEq(RecoveryAaveMock(_aave).debt(account), 280e6);
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
            if (operation != OP_READ) continue;
            uint256 index = abi.decode(Bytes.slice(recipe.steps[i], 1), (uint256));
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
        // ClaimRecipe groups measure their own output before and after every claim; gates do not skip reads.
        vm.expectCall(_asset, abi.encodeCall(IERC20.balanceOf, (account)), claimMode ? 5 : 3);
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
            _config.claims[i].amountOffsets.push();
            _config.claims[i].amountOffsets[0].push(4);
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
contract RecoveryO09Lens {
    uint256 public ready;

    constructor(uint256 newReady) {
        ready = newReady;
    }

    function health() public pure returns (uint256) {
        return 1e18;
    }

    function debt() public pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) public pure returns (uint256) {
        return 0;
    }
}

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
contract RecoverySelectedIssuer {
    address public immutable asset;
    uint256[] internal _ids;
    mapping(uint256 => uint256) internal _ready;

    constructor(address asset_) {
        asset = asset_;
    }

    function seed(uint256 id, uint256 amount) external {
        _ids.push(id);
        _ready[id] = amount;
    }

    function next(address) external view returns (uint256) {
        for (uint256 i; i < _ids.length; ++i) {
            if (_ready[_ids[i]] != 0) return _ids[i];
        }
        return 0;
    }

    function ready(address, uint256 id) external view returns (uint256) {
        return _ready[id];
    }

    function claim(uint256 id, uint256 amount, address recipient) external {
        require(_ready[id] == amount && amount != 0);
        _ready[id] = 0;
        RecoveryTokenMock(asset).mint(recipient, amount);
    }
}
