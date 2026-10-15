// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapterDelegatorMock, MerkleAdapterOracleMock, MerkleAdapterVaultMock} from "../MerkleAdapter.t.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {RecipeLiquiditySource} from "./mocks/RecipeMocks.sol";
import {ThreeFPolicy} from "src/contracts/merkle-adapter/capabilities/policies/ThreeFPolicy.sol";

import {AssetRateLimits} from "src/contracts/merkle-adapter/libraries/AssetRateLimits.sol";
import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {OP_ADD} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {IRecipes} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFVaultController} from "src/interfaces/3f-adapter/IThreeFVaultController.sol";

import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {ThreeFExecuting} from "script/recipes/ThreeFExecuting.sol";
import {ThreeFGuardedMint} from "script/recipes/ThreeFGuardedMint.sol";

import {
    ThreeFFacilityMock,
    ThreeFPositionManagerMock,
    ThreeFRequestFactoryMock,
    ThreeFRequestMock,
    ThreeFUnderlyingAssetMock
} from "test/mocks/ThreeFRequestMocks.sol";
import {Token} from "test/mocks/Token.sol";
import {createThreeFPolicy} from "test/helpers/ThreeFPolicyFactory.sol";

contract ThreeFExecutingTest is CapabilityTestBase {
    bytes internal _recipe;

    address internal _asset;
    address internal _rwa;
    address internal _facility;
    address internal _positionManager;
    address internal _executor;
    address internal _first;
    address internal _second;
    address internal _request;
    address internal _requestsFactory;
    address internal _policy;
    address internal _delegator;
    address internal _provider = makeAddr("provider");
    ThreeFExecuting.Layout internal _layout;
    bool internal _reuseTupleReads;
    uint256 internal _principalInput = 100;
    uint256 internal _yieldInput = 10;

    function setUp() public virtual {
        _asset = address(new Token("Funding"));
        _rwa = address(new Token("RWA"));
        _facility = address(new ThreeFFacilityMock());
        _positionManager = address(new ThreeFPositionManagerMock(address(new ThreeFUnderlyingAssetMock(_rwa)), _asset));
        _deployAdapter(_asset);
        _delegator = address(new MerkleAdapterDelegatorMock(adapter.vault()));
        MerkleAdapterVaultMock(adapter.vault()).setDelegator(_delegator);
        _executor = address(new RecipeExecutor(address(this), account));
        RecipeExecutor(_executor).setCaller(_provider);
        _first = address(new RecipeLiquiditySource(IERC20(_asset), account));
        _second = address(new RecipeLiquiditySource(IERC20(_asset), account));
        IERC20(_asset).transfer(_first, 1_000_000);
        IERC20(_asset).transfer(_second, 1_000_000);
        RecipeLiquiditySource(_first).setLiquidity(30);
        RecipeLiquiditySource(_second).setLiquidity(1_000_000);
        _requestsFactory = address(new ThreeFRequestFactoryMock());
        _policy = createThreeFPolicy(address(this), account, _requestsFactory, _facility);
        _installCapability(adapter, address(new RecipeCapability()), _recipeSelectors());
        _request = _newRequest(1, 100);
    }

    function test_ExecutesDirectlyFromAdapterWithIdleThenOrderedSources() public {
        IERC20(_asset).transfer(account, 20);
        uint256[] memory values = _execute(_prepare(30, 50, 100, 10, 1000));
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset, _rwa), 900);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset, _asset), 0);
        assertEq(values[_layout.sourceAmounts[0]], 30);
        assertEq(values[_layout.sourceAmounts[1]], 50);
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 30);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 50);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).balanceOf(_request), 100);
        assertEq(ThreeFRequestMock(_request).mintCaller(), account);
        assertEq(ThreeFRequestMock(_request).allowanceAtMint(), 100);
        assertEq(IERC20(_asset).allowance(account, _request), 0);
        (uint256 principal, uint256 yieldAmount) = ThreeFRequestMock(_request).balancesOf(account);
        assertEq(principal, 100);
        assertEq(yieldAmount, 10);
    }

    function testFuzz_PrincipalIsReadLiveAndUsesSourcesInOrder(uint128 principal) public {
        principal = uint128(bound(principal, 1, 1000));
        ThreeFRequestMock(_request).authorizeMinting(account, principal, 10);
        uint256 firstAmount = principal < 30 ? principal : 30;
        _execute(_prepare(firstAmount, principal - firstAmount, 1000, 10, 1000));
        assertEq(RecipeLiquiditySource(_first).withdrawn(), firstAmount);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), principal - firstAmount);
        assertEq(IERC20(_asset).balanceOf(_request), principal);
        assertEq(IERC20(_asset).allowance(account, _request), 0);
    }

    function test_SkipsAllSourcesWhenIdleFundsSuffice() public {
        IERC20(_asset).transfer(account, 150);
        bytes[] memory runtime = _prepare(0, 0, 100, 10, 1000);
        runtime[_layout.sourceCalls[0]] = "";
        runtime[_layout.sourceCalls[1]] = "";
        _execute(runtime);
        assertEq(RecipeLiquiditySource(_first).calls(), 0);
        assertEq(RecipeLiquiditySource(_second).calls(), 0);
        assertEq(IERC20(_asset).balanceOf(account), 50);
    }

    function test_SkipsZeroCapacitySourceWithoutDecodingRuntime() public {
        RecipeLiquiditySource(_first).setLiquidity(0);
        bytes[] memory runtime = _prepare(0, 100, 100, 10, 1000);
        runtime[_layout.sourceCalls[0]] = hex"dead";
        _execute(runtime);
        assertEq(RecipeLiquiditySource(_first).calls(), 0);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 100);
    }

    function test_ReadsSecondSourceCapacityAfterFirstSourceRuns() public {
        RecipeLiquiditySource(_second).setLiquidity(1);
        RecipeLiquiditySource(_first).setCallback(_second, abi.encodeCall(RecipeLiquiditySource.setLiquidity, (70)));
        _execute(_prepare(30, 70, 100, 10, 1000));
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 70);
    }

    function testFuzz_PushPreservesLockedLiquidityAfterRequestReset(bool released) public {
        IERC20(_asset).transfer(adapter.vault(), 50);
        MerkleAdapterDelegatorMock(_delegator).allocate(address(adapter), 50);
        MerkleAdapterDelegatorMock(_delegator).requestDeallocate(address(adapter), 50);
        if (released) {
            uint48 stagedAt = uint48(block.number);
            vm.roll(block.number + 1);
            MerkleAdapterOracleMock(adapter.oracle()).setSnapshotBlock(stagedAt);
            vm.prank(_delegator);
            adapter.deallocate(0);
        }
        MerkleAdapterDelegatorMock(_delegator).requestDeallocate(address(adapter), 0);
        IERC20(_asset).transfer(address(adapter), 50);
        IERC20(_asset).transfer(account, 20);
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](4);
        actions[0] = _action(address(adapter), abi.encodeCall(IMerkleAdapter.push, (0)), 4);
        actions[1] = _action(_asset, abi.encodeCall(IERC20.approve, (_request, 0)), 36);
        actions[2] = _mintAction(_request);
        actions[3] = _action(_first, abi.encodeCall(RecipeLiquiditySource.withdraw, (account, 0)), 36);
        _publish(actions);
        ExecutingRecipe.Source[] memory sources = new ExecutingRecipe.Source[](1);
        sources[0] = ExecutingRecipe.Source({
            prepare: ExecutingRecipe.Call({target: address(0), data: ""}),
            capacity: ExecutingRecipe.Read(_first, abi.encodeCall(RecipeLiquiditySource.getLiquidity, ()), 0),
            leaves: new bytes32[](1),
            amountOffsets: _sourceOffsets()
        });
        sources[0].leaves[0] = _leaf(actions[3]);
        (ExecutingRecipe.Recipe memory recipe, ThreeFExecuting.Layout memory layout) = ThreeFExecuting.build(
            ThreeFExecuting.Config({
                funding: ExecutingRecipe.Funding({
                    adapter: address(adapter),
                    account: account,
                    pushLeaf: _leaf(actions[0]),
                    asset: _asset,
                    skipUnusedReads: false,
                    sources: sources
                }),
                request: _request,
                policy: _policy,
                approvalLeaf: _leaf(actions[1]),
                mintLeaf: _leaf(actions[2]),
                maxPrincipal: 100,
                skipZeroApprovals: false,
                reuseTupleReads: _reuseTupleReads
            })
        );
        vm.prank(account);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_rwa, 1000, 1 days);
        vm.prank(account);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_rwa, 10_000_000);
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        bytes[] memory runtime = new bytes[](ExecutingRecipe.runtimeSteps(recipe).length);
        IMerkleAccount.Action[] memory call = new IMerkleAccount.Action[](1);
        call[0] = actions[0];
        runtime[layout.sourceCalls[0]] = abi.encode(call);
        call[0] = actions[3];
        runtime[layout.sourceCalls[1]] = abi.encode(call);
        runtime[layout.approve] = abi.encode(actions[1].dataMask, actions[1].proof);
        runtime[layout.clearApproval] = runtime[layout.approve];
        call[0] = actions[2];
        runtime[layout.operation] = abi.encode(call);
        uint256[] memory inputs = _requestInput();
        vm.prank(_provider);
        uint256[] memory values = RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, inputs, runtime);
        assertEq(values[layout.sourceAmounts[0]], 50);
        assertEq(values[layout.sourceAmounts[1]], 30);
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 30);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 50);
        assertEq(adapter.pendingDeallocation(), 50);
        assertEq(adapter.releasedLiquidity(), released ? 50 : 0);
        assertEq(adapter.stagedLiquidity(), released ? 0 : 50);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).balanceOf(_request), 100);
        assertEq(ThreeFRequestMock(_request).mintCaller(), account);
    }

    function test_PreservesRequestedWithdrawalAndUsesOnlyFreeIdleFunds() public {
        IERC20(_asset).transfer(adapter.vault(), 50);
        MerkleAdapterDelegatorMock(_delegator).allocate(address(adapter), 50);
        MerkleAdapterDelegatorMock(_delegator).requestDeallocate(address(adapter), 50);
        IERC20(_asset).transfer(account, 20);
        _execute(_prepare(30, 50, 100, 10, 1000));
        assertEq(adapter.pendingDeallocation(), 50);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 50);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 50);
    }

    function test_ReservedWithdrawalsRemainInAdapterWhileAccountFundsMint() public {
        IERC20(_asset).transfer(address(adapter), 50);
        MerkleAdapterDelegatorMock(_delegator).requestDeallocate(address(adapter), 50);
        RecipeLiquiditySource(_first).setLiquidity(80);
        _execute(_prepare(80, 20, 100, 10, 1000));
        assertEq(adapter.pendingDeallocation(), 50);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 50);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 20);
    }

    function test_OracleUpdateDoesNotChangeAccountFunding() public {
        IERC20(_asset).transfer(address(adapter), 50);
        MerkleAdapterDelegatorMock(_delegator).requestDeallocate(address(adapter), 50);
        assertEq(adapter.pendingDeallocation(), 50);
        RecipeLiquiditySource(_first).setLiquidity(60);
        RecipeLiquiditySource(_first)
            .setCallback(adapter.oracle(), abi.encodeCall(MerkleAdapterOracleMock.setTotalAssets, (50)));
        _execute(_prepare(60, 40, 100, 10, 1000));
        assertEq(adapter.pendingDeallocation(), 50);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 50);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 40);
    }

    function test_OracleUpdateDuringMintPreservesRequestedCash() public {
        IERC20(_asset).transfer(address(adapter), 50);
        MerkleAdapterDelegatorMock(_delegator).requestDeallocate(address(adapter), 50);
        ThreeFRequestMock(_request)
            .setMintCallback(adapter.oracle(), abi.encodeCall(MerkleAdapterOracleMock.setTotalAssets, (50)));
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 50);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(adapter.pendingDeallocation(), 50);
    }

    function test_InsufficientLiquidityRollsBackBothSources() public {
        RecipeLiquiditySource(_second).setLiquidity(69);
        bytes[] memory runtime = _prepare(30, 69, 100, 10, 1000);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, account, 99, 100));
        _execute(runtime);
        _assertRollback();
        assertEq(ThreeFPolicy(_policy).remainingAssets(_rwa), 1000);
    }

    function test_CalculatedAmountsReplaceWrongSourceTemplateAmounts() public {
        bytes[] memory runtime = _prepare(29, 71, 100, 10, 1000);
        _execute(runtime);
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 30);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 70);
    }

    function testFuzz_WrongFundingDeltaRollsBack(int256 adjustment) public {
        adjustment = bound(adjustment, -29, 30);
        vm.assume(adjustment != 0);
        RecipeLiquiditySource(_first).setAdjustment(adjustment);
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_ChangedPrincipalDuringFundingCannotUseStaleRead() public {
        RecipeLiquiditySource(_first)
            .setCallback(_request, abi.encodeCall(ThreeFRequestMock.authorizeMinting, (account, 90, 10)));
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        _assertRollback();
        (uint128 principal,) = ThreeFRequestMock(_request).mintAuthorization(account);
        assertEq(principal, 100);
    }

    function test_ChangedYieldDuringFundingCannotBypassConfiguredMinimum() public {
        RecipeLiquiditySource(_first)
            .setCallback(_request, abi.encodeCall(ThreeFRequestMock.authorizeMinting, (account, 100, 9)));
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        _assertRollback();
    }

    function testFuzz_ChangedAuthorizationAfterApprovalCannotUseCachedTuple(bool changedYield) public {
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        bytes[] memory authorizations = new bytes[](2);
        bytes memory changed = abi.encode(uint128(changedYield ? 100 : 90), uint128(changedYield ? 9 : 10));
        authorizations[0] = changed;
        authorizations[1] = changed;
        vm.mockCalls(_request, abi.encodeCall(ThreeFRequestMock.mintAuthorization, (account)), authorizations);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        vm.clearMockedCalls();
        _assertRollback();
    }

    function test_FullWidthPriorSharesRemainExactAcrossMint() public {
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        bytes[] memory balances = new bytes[](4);
        balances[0] = abi.encode(type(uint256).max - 100, type(uint256).max - 10);
        balances[1] = balances[0];
        bytes memory afterMint = abi.encode(type(uint256).max, type(uint256).max);
        balances[2] = afterMint;
        balances[3] = afterMint;
        vm.mockCalls(_request, abi.encodeCall(IThreeFVaultController.balancesOf, (account)), balances);
        _execute(runtime);
        vm.clearMockedCalls();
        (uint256 principal, uint256 yieldAssets) = ThreeFRequestMock(_request).balancesOf(account);
        assertEq(principal, 100);
        assertEq(yieldAssets, 10);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).balanceOf(_request), 100);
        assertEq(IERC20(_asset).allowance(account, _request), 0);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_rwa), 900);
    }

    function test_PrincipalCapFailsBeforeFunding() public {
        bytes[] memory runtime = _prepare(30, 70, 99, 10, 1000);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_ZeroAuthorizationCannotExecute() public {
        ThreeFRequestMock(_request).authorizeMinting(account, 0, 0);
        bytes[] memory runtime = _prepare(0, 0, 100, 0, 1000);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_YieldFloorRejectsMint() public {
        bytes[] memory runtime = _prepare(30, 70, 100, 11, 1000);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_PeriodBudgetRejectsMint() public {
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 99);
        vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_PeriodBudgetIncludesExistingRequests() public {
        _execute(_prepare(30, 70, 100, 10, 150));
        _request = _newRequest(2, 100);
        bytes[] memory runtime = _prepare(0, 100, 100, 10, 150);
        vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(_request), 0);
        assertEq(IERC20(_asset).allowance(account, _request), 0);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 70);
    }

    function test_MintRequestAddressIsPinnedByLeaf() public {
        address other = _newRequest(2, 100);
        address otherUnderlying = address(new Token("Other RWA"));
        ThreeFFacilityMock(_facility)
            .setIntent(
                2,
                other,
                address(new ThreeFPositionManagerMock(address(new ThreeFUnderlyingAssetMock(otherUnderlying)), _asset)),
                true
            );
        vm.prank(account);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(otherUnderlying, 1000, 1 days);
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        IMerkleAccount.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAccount.Action[]));
        IMerkleAccount.Action memory substitute = _mintAction(other);
        actions[0].target = substitute.target;
        actions[0].data = substitute.data;
        actions[0].dataMask = substitute.dataMask;
        runtime[_layout.operation] = abi.encode(actions);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        _execute(runtime);
        bytes32 root = MerkleAccount(payable(account)).root();
        bytes32 recipeHash = RecipeExecutor(_executor).recipeHash();
        _request = _newRequest(2, 75);
        _principalInput = 75;
        _execute(runtime);
        assertEq(MerkleAccount(payable(account)).root(), root);
        assertEq(RecipeExecutor(_executor).recipeHash(), recipeHash);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset, _rwa), 825);
        assertEq(IERC20(_asset).balanceOf(_request), 75);
        assertEq(IERC20(_asset).allowance(account, _request), 0);
    }

    function test_RequestMustBelongToConfiguredFactory() public {
        ThreeFRequestFactoryMock(_requestsFactory).set(_request, false);
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        vm.expectRevert(IThreeFPolicy.InvalidRequest.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_FacilityRequestMismatchRollsBackFundingAndMint() public {
        ThreeFFacilityMock(_facility).setIntent(1, address(1), _positionManager, true);
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        vm.expectRevert(IThreeFPolicy.RequestMismatch.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_CollateralTargetMustBeAPositionManager() public {
        ThreeFFacilityMock(_facility).setIntent(1, _request, _positionManager, false);
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        vm.expectRevert(IThreeFPolicy.UnsupportedTarget.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_BothPolicyArgumentsUseCommittedTemplateAndCalculatedValues() public {
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        assertEq(runtime.length, 5);
        _execute(runtime);
        (uint256 principal, uint256 yieldAssets) = ThreeFRequestMock(_request).balancesOf(account);
        assertEq(principal, 100);
        assertEq(yieldAssets, 10);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_rwa), 900);
    }

    function test_ExecutorKeeperAndOwnerCannotConsumePolicyDirectly() public {
        address[3] memory callers = [_executor, _provider, address(this)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(IThreeFPolicy.InvalidCaller.selector);
            ThreeFPolicy(_policy).consume(_request, 100, 10);
        }
    }

    function test_KeeperCannotCallCapabilityDirectlyAtTheAccount() public {
        ThreeFGuardedMint.Leaf memory leaf = ThreeFGuardedMint.build(
            ThreeFGuardedMint.Config({account: account, asset: _asset, policy: _policy, request: _request})
        );
        vm.prank(_provider);
        (bool success, bytes memory result) = account.call(leaf.data);
        assertFalse(success);
        assertEq(bytes4(result), IRecipeCapability.InvalidCaller.selector);
    }

    function test_ExecutorCannotBypassPolicyWithRawMint() public {
        _prepare(30, 70, 100, 10, 1000);
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = _action(_request, abi.encodeCall(IThreeFPushRequest.mint, (100, 10)), 4);
        vm.prank(_executor);
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        IMerkleAccount(account).manage(actions);
        _assertRollback();
    }

    function test_KeeperCannotRemovePolicyCallFromCommittedCapability() public {
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        IMerkleAccount.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAccount.Action[]));
        (bytes[] memory queries, bytes[] memory steps, uint256[] memory inputs) =
            abi.decode(Bytes.slice(actions[0].data, 4), (bytes[], bytes[], uint256[]));
        // Retain the encoded length and offsets, but replace consume with arithmetic.
        steps[10][0] = bytes1(OP_ADD);
        actions[0].data = abi.encodeCall(IRecipeCapability.execute, (queries, steps, inputs));
        runtime[_layout.operation] = abi.encode(actions);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_CurrentYieldAppliesToExistingRecipe() public {
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        vm.prank(account);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_rwa, 10_000_001);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        _execute(runtime);
        vm.prank(account);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_rwa, 10_000_000);
        _execute(runtime);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_rwa), 900);
    }

    function test_MissingLeafRoleCannotBeReplacedByCallerRole() public {
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        IMerkleAccount.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAccount.Action[]));
        bytes32 leaf = _leaf(actions[0]);
        MerkleAccount(payable(account)).revokeRole(leaf, _executor);
        MerkleAccount(payable(account)).grantRole(leaf, _provider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _executor, leaf)
        );
        _execute(runtime);
        _assertRollback();
    }

    function test_InvalidMintProofRollsBackAllFunding() public {
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        IMerkleAccount.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAccount.Action[]));
        actions[0].proof[0] ^= bytes32(uint256(1));
        runtime[_layout.operation] = abi.encode(actions);
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_InvalidClearApprovalProofRollsBackSuccessfulMint() public {
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        address other = _newRequest(2, 90);
        ThreeFFacilityMock(_facility).setIntent(2, other, address(0), false);
        IMerkleAccount.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAccount.Action[]));
        ThreeFGuardedMint.Leaf memory leaf = ThreeFGuardedMint.build(
            ThreeFGuardedMint.Config({account: account, asset: _asset, policy: _policy, request: other}),
            _reuseTupleReads
        );
        for (uint256 i; i < leaf.requestOffsets.length; ++i) {
            ThreeFGuardedMint.write(actions[0].data, leaf.requestOffsets[i], uint160(other));
        }
        runtime[_layout.operation] = abi.encode(actions);
        _execute(runtime);
        _assertRollback();
    }

    function testFuzz_EachRequestSlotIsBoundToTheSelectedAuction(uint8 slot) public {
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        address other = _newRequest(2, 90);
        ThreeFFacilityMock(_facility).setIntent(2, other, address(0), false);
        IMerkleAccount.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAccount.Action[]));
        ThreeFGuardedMint.Leaf memory leaf = ThreeFGuardedMint.build(
            ThreeFGuardedMint.Config({
                account: account, asset: _asset, underlyingAsset: _rwa, policy: _policy, request: _request
            })
        );
        assertEq(leaf.requestOffsets.length, 7);
        ThreeFGuardedMint.write(actions[0].data, leaf.requestOffsets[slot % 7], uint160(other));
        runtime[_layout.operation] = abi.encode(actions);
        _execute(runtime);
        assertEq(ThreeFRequestMock(other).mintCalls(), 0);
        assertEq(IERC20(_asset).balanceOf(other), 0);
        assertEq(IERC20(_asset).balanceOf(_request), 100);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset, _rwa), 900);
    }

    function test_ResetsExistingApprovalAndLeavesNoAllowance() public {
        _manage(_asset, abi.encodeCall(IERC20.approve, (_request, 500)));
        _execute(_prepare(30, 70, 100, 10, 1000));
        assertEq(ThreeFRequestMock(_request).allowanceAtMint(), 100);
        assertEq(IERC20(_asset).allowance(account, _request), 0);
    }

    function _mintAction(address request) internal view returns (IMerkleAccount.Action memory) {
        ThreeFGuardedMint.Leaf memory leaf = ThreeFGuardedMint.build(
            ThreeFGuardedMint.Config({account: account, asset: _asset, policy: _policy, request: request}),
            _reuseTupleReads
        );
        return IMerkleAccount.Action({
            target: account, value: 0, data: leaf.data, dataMask: leaf.dataMask, proof: new bytes32[](0)
        });
    }

    function _newRequest(uint256 id, uint128 principal) internal returns (address request) {
        request = address(new ThreeFRequestMock(_asset, string.concat("request-", vm.toString(id))));
        ThreeFRequestFactoryMock(_requestsFactory).set(request, true);
        ThreeFFacilityMock(_facility).setIntent(id, request, _positionManager, true);
        ThreeFRequestMock(request).authorizeMinting(account, principal, 10);
    }

    function _prepare(
        uint256 firstAmount,
        uint256 secondAmount,
        uint256 maxPrincipal,
        uint256 minYield,
        uint256 maxPosition
    ) internal returns (bytes[] memory runtime) {
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](4);
        actions[0] = _action(_first, abi.encodeCall(RecipeLiquiditySource.withdraw, (account, firstAmount)), 36);
        actions[1] = _action(_second, abi.encodeCall(RecipeLiquiditySource.withdraw, (account, secondAmount)), 36);
        actions[2] = _action(_asset, abi.encodeCall(IERC20.approve, (_request, 0)), 36);
        actions[3] = _mintAction(_request);
        _publish(actions);
        ExecutingRecipe.Source[] memory sources = new ExecutingRecipe.Source[](2);
        for (uint256 i; i < sources.length; ++i) {
            bytes32[] memory leaves = new bytes32[](1);
            leaves[0] = _leaf(actions[i]);
            sources[i] = ExecutingRecipe.Source({
                prepare: ExecutingRecipe.Call({target: address(0), data: ""}),
                capacity: ExecutingRecipe.Read({
                    target: actions[i].target, data: abi.encodeCall(RecipeLiquiditySource.getLiquidity, ()), offset: 0
                }),
                leaves: leaves,
                amountOffsets: _sourceOffsets()
            });
        }
        (ExecutingRecipe.Recipe memory recipe, ThreeFExecuting.Layout memory layout) = ThreeFExecuting.build(
            ThreeFExecuting.Config({
                funding: ExecutingRecipe.Funding({
                    adapter: address(adapter),
                    account: account,
                    pushLeaf: bytes32(0),
                    asset: _asset,
                    skipUnusedReads: false,
                    sources: sources
                }),
                request: _request,
                policy: _policy,
                approvalLeaf: _leaf(actions[2]),
                mintLeaf: _leaf(actions[3]),
                maxPrincipal: maxPrincipal,
                skipZeroApprovals: false,
                reuseTupleReads: _reuseTupleReads
            })
        );
        vm.prank(account);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_rwa, maxPosition, 1 days);
        vm.prank(account);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_rwa, minYield * 1e8 / maxPrincipal);
        (_principalInput, _yieldInput) = IThreeFPushRequest(_request).mintAuthorization(account);
        _layout = layout;
        _recipe = abi.encode(recipe.queries, recipe.steps);
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        runtime = new bytes[](ExecutingRecipe.runtimeSteps(recipe).length);
        for (uint256 i; i < sources.length; ++i) {
            IMerkleAccount.Action[] memory group = new IMerkleAccount.Action[](1);
            group[0] = actions[i];
            runtime[layout.sourceCalls[i]] = abi.encode(group);
        }
        runtime[layout.approve] = abi.encode(actions[2].dataMask, actions[2].proof);
        runtime[layout.clearApproval] = runtime[layout.approve];
        IMerkleAccount.Action[] memory mint = new IMerkleAccount.Action[](1);
        mint[0] = actions[3];
        runtime[layout.operation] = abi.encode(mint);
    }

    function _sourceOffsets() internal pure returns (uint256[][] memory offsets) {
        offsets = new uint256[][](1);
        offsets[0] = new uint256[](1);
        offsets[0][0] = 36;
    }

    function _publish(IMerkleAccount.Action[] memory actions) internal {
        bytes32[] memory tree = new bytes32[](8);
        for (uint256 i; i < actions.length; ++i) {
            tree[4 + i] = _leaf(actions[i]);
            MerkleAccount(payable(account)).grantRole(tree[4 + i], _executor);
        }
        for (uint256 i = 3; i > 0; --i) {
            bytes32 a = tree[i * 2];
            bytes32 b = tree[i * 2 + 1];
            tree[i] = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        }
        for (uint256 i; i < actions.length; ++i) {
            actions[i].proof = new bytes32[](2);
            actions[i].proof[0] = tree[(4 + i) ^ 1];
            actions[i].proof[1] = tree[((4 + i) / 2) ^ 1];
        }
        roots.setRoot(account, tree[1]);
        MerkleAccount(payable(account)).acceptRoot(tree[1]);
    }

    function _action(address target, bytes memory data, uint256 maskStart)
        internal
        pure
        returns (IMerkleAccount.Action memory action)
    {
        action = IMerkleAccount.Action({
            target: target, value: 0, data: data, dataMask: new bytes(data.length), proof: new bytes32[](0)
        });
        for (uint256 i = maskStart; i < data.length; ++i) {
            action.dataMask[i] = 0xff;
        }
    }

    function _leaf(IMerkleAccount.Action memory action) internal pure returns (bytes32) {
        return ActionMasker.mask(action.target, action.value, action.data, action.dataMask);
    }

    function _requestInput() internal view returns (uint256[] memory inputs) {
        inputs = new uint256[](3);
        inputs[0] = uint160(_request);
        // These are the authorization values selected by this fixture before submission.
        inputs[1] = _principalInput;
        inputs[2] = _yieldInput;
    }

    function _execute(bytes[] memory runtime) internal returns (uint256[] memory) {
        (bytes[] memory queries, bytes[] memory steps) = abi.decode(_recipe, (bytes[], bytes[]));
        uint256[] memory inputs = _requestInput();
        vm.prank(_provider);
        return RecipeExecutor(_executor).execute(queries, steps, inputs, runtime);
    }

    function _assertRollback() internal view {
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 0);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 0);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).balanceOf(_request), 0);
        assertEq(IERC20(_asset).allowance(account, _request), 0);
        assertEq(ThreeFRequestMock(_request).mintCalls(), 0);
        (,,, uint256 spent) = ThreeFPolicy(_policy).assetLimits(_rwa);
        assertEq(spent, 0);
    }
}

contract ThreeFCachedExecutingTest is ThreeFExecutingTest {
    function setUp() public override {
        super.setUp();
        _reuseTupleReads = true;
    }
}
