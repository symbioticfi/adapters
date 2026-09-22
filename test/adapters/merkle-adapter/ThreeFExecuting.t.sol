// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {AssetRateLimits} from "src/contracts/merkle-adapter/libraries/AssetRateLimits.sol";

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {GuardedCallsCapability} from "src/contracts/merkle-adapter/capabilities/GuardedCallsCapability.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapterDelegatorMock, MerkleAdapterOracleMock, MerkleAdapterVaultMock} from "../MerkleAdapter.t.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {RecipeLiquiditySource} from "./mocks/RecipeMocks.sol";
import {ThreeFPolicy} from "src/contracts/merkle-adapter/automations/policies/ThreeFPolicy.sol";

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IGuardedCallsCapability} from "src/interfaces/merkle-adapter/capabilities/IGuardedCallsCapability.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFVaultController} from "src/interfaces/3f-adapter/IThreeFVaultController.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/automations/policies/IThreeFPolicy.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {ThreeFExecuting} from "script/recipes/ThreeFExecuting.sol";
import {ThreeFGuardedMint} from "script/recipes/ThreeFGuardedMint.sol";

import {ThreeFRequestMock, ThreeFRequestFactoryMock} from "test/mocks/ThreeFRequestMocks.sol";
import {Token} from "test/mocks/Token.sol";
import {createThreeFPolicy} from "test/helpers/ThreeFPolicyFactory.sol";

contract ThreeFExecutingTest is CapabilityTestBase {
    bytes internal _recipe;

    address internal _asset;
    address internal _rwa;
    address internal _executor;
    address internal _first;
    address internal _second;
    address internal _request;
    address internal _requestsFactory;
    address internal _policy;
    address internal _delegator;
    address internal _provider = makeAddr("provider");
    ThreeFExecuting.Layout internal _layout;
    bool internal _guardedMintMode = true;

    function setUp() public virtual {
        _asset = address(new Token("Funding"));
        _rwa = address(new Token("RWA"));
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
        _policy = address(createThreeFPolicy(address(this), account));
        _installCapability(adapter, address(new GuardedCallsCapability()), _guardedSelectors());
        _request = _newRequest(1, 100);
    }

    function test_ExecutesDirectlyFromAdapterWithIdleThenOrderedSources() public {
        IERC20(_asset).transfer(account, 20);
        uint256[] memory values = _execute(_prepare(30, 50, 100, 10, 1000));
        assertEq(values[_layout.principal.value], 100);
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

    function test_ReleasesOnlyFundingShortfallWhilePreservingAdapterReserves() public {
        IERC20(_asset).transfer(adapter.vault(), 50);
        MerkleAdapterDelegatorMock(_delegator).allocate(address(adapter), 50);
        IERC20(_asset).transfer(address(adapter), 100);
        IERC20(_asset).transfer(account, 20);
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](3);
        actions[0] = _action(address(adapter), abi.encodeCall(IMerkleAdapter.push, (0)), 4);
        actions[1] = _action(_asset, abi.encodeCall(IERC20.approve, (_request, 0)), 36);
        actions[2] = _mintAction(_request);
        _publish(actions);
        (ExecutingRecipe.Recipe memory recipe, ThreeFExecuting.Layout memory layout) = ThreeFExecuting.build(
            ThreeFExecuting.Config({
                funding: ExecutingRecipe.Funding({
                    adapter: address(adapter),
                    account: account,
                    pushLeaf: _leaf(actions[0]),
                    asset: _asset,
                    sources: new ExecutingRecipe.Source[](0)
                }),
                request: _request,
                requestsFactory: _requestsFactory,
                policy: _policy,
                approvalLeaf: _leaf(actions[1]),
                mintLeaf: _leaf(actions[2]),
                maxPrincipal: 100,
                guardedMint: _guardedMintMode
            })
        );
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_asset, 1000, 1 days);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_asset, 100_000);
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        bytes[] memory runtime = new bytes[](ExecutingRecipe.runtimeSteps(recipe).length);
        IMerkleAccount.Action[] memory call = new IMerkleAccount.Action[](1);
        call[0] = actions[0];
        runtime[layout.sourceCalls[0]] = abi.encode(call);
        runtime[layout.approve] = abi.encode(actions[1].dataMask, actions[1].proof);
        runtime[layout.clearApproval] = runtime[layout.approve];
        call[0] = actions[2];
        runtime[layout.operation] = abi.encode(call);
        vm.prank(_provider);
        uint256[] memory values =
            RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](0), runtime);
        assertEq(values[layout.sourceAmounts[0]], 80);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 70);
        assertEq(adapter.reservedAssets(), 50);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).balanceOf(_request), 100);
        assertEq(ThreeFRequestMock(_request).mintCaller(), account);
    }

    function test_PreservesReservedAllocationAndUsesOnlyFreeIdleFunds() public {
        IERC20(_asset).transfer(adapter.vault(), 50);
        MerkleAdapterDelegatorMock(_delegator).allocate(address(adapter), 50);
        IERC20(_asset).transfer(account, 20);
        _execute(_prepare(30, 50, 100, 10, 1000));
        assertEq(adapter.reservedAssets(), 50);
        (uint256 pending,) = adapter.nextBatch();
        assertEq(pending, 50);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 50);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 50);
    }

    function test_ReservedWithdrawalsRemainInAdapterWhileAccountFundsMint() public {
        IERC20(_asset).transfer(address(adapter), 50);
        MerkleAdapterDelegatorMock(_delegator).requestDeallocate(address(adapter), 50);
        MerkleAdapterOracleMock(adapter.oracle()).setNonce(2);
        RecipeLiquiditySource(_first).setLiquidity(80);
        _execute(_prepare(80, 20, 100, 10, 1000));
        assertEq(adapter.reservedAssets(), 50);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 50);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 20);
    }

    function test_ReservationMaturationDoesNotChangeAccountFunding() public {
        IERC20(_asset).transfer(address(adapter), 50);
        MerkleAdapterDelegatorMock(_delegator).requestDeallocate(address(adapter), 50);
        assertEq(adapter.reservedAssets(), 0);
        RecipeLiquiditySource(_first).setLiquidity(60);
        RecipeLiquiditySource(_first)
            .setCallback(adapter.oracle(), abi.encodeCall(MerkleAdapterOracleMock.setNonce, (2)));
        _execute(_prepare(60, 40, 100, 10, 1000));
        assertEq(adapter.reservedAssets(), 50);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 50);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 40);
    }

    function test_NewReservationDuringMintStaysInSeparateAdapter() public {
        IERC20(_asset).transfer(address(adapter), 50);
        MerkleAdapterDelegatorMock(_delegator).requestDeallocate(address(adapter), 50);
        ThreeFRequestMock(_request)
            .setMintCallback(adapter.oracle(), abi.encodeCall(MerkleAdapterOracleMock.setNonce, (2)));
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 50);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(adapter.reservedAssets(), 50);
    }

    function test_InsufficientLiquidityRollsBackBothSources() public {
        RecipeLiquiditySource(_second).setLiquidity(69);
        bytes[] memory runtime = _prepare(30, 69, 100, 10, 1000);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, account, 99, 100));
        _execute(runtime);
        _assertRollback();
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 1000);
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
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_ChangedPrincipalDuringFundingCannotUseStaleRead() public {
        RecipeLiquiditySource(_first)
            .setCallback(_request, abi.encodeCall(ThreeFRequestMock.authorizeMinting, (account, 90, 10)));
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(runtime);
        _assertRollback();
        (uint128 principal,) = ThreeFRequestMock(_request).mintAuthorization(account);
        assertEq(principal, 100);
    }

    function test_ChangedYieldDuringFundingCannotBypassConfiguredMinimum() public {
        RecipeLiquiditySource(_first)
            .setCallback(_request, abi.encodeCall(ThreeFRequestMock.authorizeMinting, (account, 100, 9)));
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_PrincipalCapFailsBeforeFunding() public {
        bytes[] memory runtime = _prepare(30, 70, 99, 10, 1000);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_ZeroAuthorizationCannotExecute() public {
        ThreeFRequestMock(_request).authorizeMinting(account, 0, 0);
        bytes[] memory runtime = _prepare(0, 0, 100, 0, 1000);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
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
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        IMerkleAccount.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAccount.Action[]));
        IMerkleAccount.Action memory substitute = _mintAction(other);
        actions[0].target = substitute.target;
        actions[0].data = substitute.data;
        actions[0].dataMask = substitute.dataMask;
        runtime[_layout.operation] = abi.encode(actions);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        _execute(runtime);
        _assertRollback();
        assertEq(IERC20(_asset).balanceOf(other), 0);
    }

    function test_RequestMustBelongToConfiguredFactory() public {
        ThreeFRequestFactoryMock(_requestsFactory).set(_request, false);
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        vm.expectRevert(
            _guardedMintMode ? IGuardedCallsCapability.CheckFailed.selector : IRecipeExecutor.CheckFailed.selector
        );
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
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 900);
    }

    function test_OwnerUpdatesYieldWithoutReplacingRecipeOrRoot() public {
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_asset, 100_001);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        _execute(runtime);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_asset, 100_000);
        _execute(runtime);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 900);
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
        (bytes memory dataMask, bytes32[] memory proof) = abi.decode(runtime[_layout.clearApproval], (bytes, bytes32[]));
        proof[0] ^= bytes32(uint256(1));
        runtime[_layout.clearApproval] = abi.encode(dataMask, proof);
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_ResetsExistingApprovalAndLeavesNoAllowance() public {
        _manage(_asset, abi.encodeCall(IERC20.approve, (_request, 500)));
        _execute(_prepare(30, 70, 100, 10, 1000));
        assertEq(ThreeFRequestMock(_request).allowanceAtMint(), 100);
        assertEq(IERC20(_asset).allowance(account, _request), 0);
    }

    function _mintAction(address request) internal view returns (IMerkleAccount.Action memory) {
        if (!_guardedMintMode) return _action(request, abi.encodeCall(IThreeFPushRequest.mint, (0, 0)), 4);
        ThreeFGuardedMint.Leaf memory leaf = ThreeFGuardedMint.build(
            ThreeFGuardedMint.Config({
                account: account, asset: _asset, policy: _policy, request: request, requestsFactory: _requestsFactory
            })
        );
        return IMerkleAccount.Action({
            target: account, value: 0, data: leaf.data, dataMask: leaf.dataMask, proof: new bytes32[](0)
        });
    }

    function _newRequest(uint256 id, uint128 principal) internal returns (address request) {
        request = address(new ThreeFRequestMock(_asset, string.concat("request-", vm.toString(id))));
        ThreeFRequestFactoryMock(_requestsFactory).set(request, true);
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
                    adapter: address(adapter), account: account, pushLeaf: bytes32(0), asset: _asset, sources: sources
                }),
                request: _request,
                requestsFactory: _requestsFactory,
                policy: _policy,
                approvalLeaf: _leaf(actions[2]),
                mintLeaf: _leaf(actions[3]),
                maxPrincipal: maxPrincipal,
                guardedMint: _guardedMintMode
            })
        );
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_asset, maxPosition, 1 days);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_asset, minYield * 1_000_000 / maxPrincipal);
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
        return MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask);
    }

    function _execute(bytes[] memory runtime) internal returns (uint256[] memory) {
        (bytes[] memory queries, IRecipeExecutor.Step[] memory steps) =
            abi.decode(_recipe, (bytes[], IRecipeExecutor.Step[]));
        vm.prank(_provider);
        return RecipeExecutor(_executor).execute(queries, steps, new uint256[](0), runtime);
    }

    function _assertRollback() internal view {
        assertEq(RecipeLiquiditySource(_first).withdrawn(), 0);
        assertEq(RecipeLiquiditySource(_second).withdrawn(), 0);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).balanceOf(_request), 0);
        assertEq(IERC20(_asset).allowance(account, _request), 0);
        assertEq(ThreeFRequestMock(_request).mintCalls(), 0);
        (,,, uint256 spent) = ThreeFPolicy(_policy).assetLimits(_asset);
        assertEq(spent, 0);
    }
}

contract ThreeFDirectExecutingTest is ThreeFExecutingTest {
    function setUp() public override {
        super.setUp();
        _guardedMintMode = false;
        ThreeFPolicy(_policy).setConsumer(_executor);
        address[] memory capabilities = IMerkleAccount(account).getCapabilities();
        IMerkleAccount(account).removeCapability(capabilities[0]);
    }

    function test_DirectPolicyNeedsNoInstalledCapability() public {
        assertEq(IMerkleAccount(account).getCapabilities().length, 0);
        _execute(_prepare(30, 70, 100, 10, 1000));
        assertEq(ThreeFPolicy(_policy).consumer(), _executor);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 900);
    }

    function test_FailedDirectMintRollsBackPolicyCharge() public {
        ThreeFRequestMock(_request).setFailMint(true);
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        vm.expectRevert(ThreeFRequestMock.MintFailed.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_NoOpDirectMintCannotConsumeBudget() public {
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        vm.mockCall(_request, abi.encodeCall(IThreeFPushRequest.mint, (100, 10)), "");
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(runtime);
        _assertRollback();
    }

    function testFuzz_DirectPolicyRequiresExactShareDeltas(bool wrongYield, uint128 wrongAmount) public {
        vm.assume(wrongAmount != (wrongYield ? 10 : 100));
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        bytes[] memory balances = new bytes[](4);
        balances[0] = abi.encode(0, 0);
        balances[1] = balances[0];
        balances[2] = abi.encode(wrongYield ? 100 : wrongAmount, wrongYield ? wrongAmount : 10);
        balances[3] = balances[2];
        vm.mockCalls(_request, abi.encodeCall(IThreeFVaultController.balancesOf, (account)), balances);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_DirectPolicyRequiresExactCashDebit() public {
        // A request returning one unit still mints the declared shares, but must not spend the full budget.
        deal(_asset, _request, 1);
        ThreeFRequestMock(_request).setMintCallback(_asset, abi.encodeCall(IERC20.transfer, (account, 1)));
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(_request), 1);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 1000);
        assertEq(ThreeFRequestMock(_request).mintCalls(), 0);
    }

    function test_ChangingConsumerBlocksDirectRecipeWithoutResettingUsage() public {
        _execute(_prepare(30, 70, 100, 10, 1000));
        _request = _newRequest(2, 100);
        bytes[] memory runtime = _prepare(0, 100, 100, 10, 1000);
        ThreeFPolicy(_policy).setConsumer(account);
        vm.expectRevert(IThreeFPolicy.InvalidCaller.selector);
        _execute(runtime);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 900);
        assertEq(ThreeFRequestMock(_request).mintCalls(), 0);
    }
}
