// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {ExecutorLiquiditySource} from "./Executor.t.sol";
import {MerkleAdapterDelegatorMock, MerkleAdapterOracleMock, MerkleAdapterVaultMock} from "../MerkleAdapter.t.sol";
import {RecipeExecutor} from "src/contracts/periphery/RecipeExecutor.sol";
import {ThreeFPolicy} from "src/contracts/periphery/ThreeFPolicy.sol";
import {ThreeFRequestMock, ThreeFRequestFactoryMock} from "test/mocks/ThreeFRequestMocks.sol";
import {Token} from "test/mocks/Token.sol";

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {ThreeFExecuting} from "script/recipes/ThreeFExecuting.sol";
import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IAssetRateLimits} from "src/interfaces/merkle-adapter/IAssetRateLimits.sol";
import {IExecutor} from "src/interfaces/periphery/IExecutor.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IRecipeExecutor} from "src/interfaces/periphery/IRecipeExecutor.sol";
import {IThreeFPolicy} from "src/interfaces/periphery/IThreeFPolicy.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ThreeFExecutingTest is CapabilityTestBase {
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

    function setUp() public {
        _asset = address(new Token("Funding"));
        _rwa = address(new Token("RWA"));
        _deployAdapter(_asset);
        _delegator = address(new MerkleAdapterDelegatorMock(adapter.vault()));
        MerkleAdapterVaultMock(adapter.vault()).setDelegator(_delegator);
        _executor = address(new RecipeExecutor(address(this), address(adapter)));
        RecipeExecutor(_executor).setCaller(_provider);
        _first = address(new ExecutorLiquiditySource(IERC20(_asset), address(adapter)));
        _second = address(new ExecutorLiquiditySource(IERC20(_asset), address(adapter)));
        IERC20(_asset).transfer(_first, 1_000_000);
        IERC20(_asset).transfer(_second, 1_000_000);
        ExecutorLiquiditySource(_first).setLiquidity(30);
        ExecutorLiquiditySource(_second).setLiquidity(1_000_000);
        _requestsFactory = address(new ThreeFRequestFactoryMock());
        _policy = address(new ThreeFPolicy(address(this), _executor));
        _request = _newRequest(1, 100);
    }

    function test_ExecutesDirectlyFromAdapterWithIdleThenOrderedSources() public {
        IERC20(_asset).transfer(address(adapter), 20);
        uint256[] memory values = _execute(_prepare(30, 50, 100, 10, 1000));
        assertEq(values[_layout.principal], 100);
        assertEq(values[_layout.sourceAmounts[0]], 30);
        assertEq(values[_layout.sourceAmounts[1]], 50);
        assertEq(ExecutorLiquiditySource(_first).withdrawn(), 30);
        assertEq(ExecutorLiquiditySource(_second).withdrawn(), 50);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 0);
        assertEq(IERC20(_asset).balanceOf(_request), 100);
        assertEq(ThreeFRequestMock(_request).mintCaller(), address(adapter));
        assertEq(ThreeFRequestMock(_request).allowanceAtMint(), 100);
        assertEq(IERC20(_asset).allowance(address(adapter), _request), 0);
        (uint256 principal, uint256 yieldAmount) = ThreeFRequestMock(_request).balancesOf(address(adapter));
        assertEq(principal, 100);
        assertEq(yieldAmount, 10);
    }

    function testFuzz_PrincipalIsReadLiveAndUsesSourcesInOrder(uint128 principal) public {
        principal = uint128(bound(principal, 1, 1000));
        ThreeFRequestMock(_request).authorizeMinting(address(adapter), principal, 10);
        uint256 firstAmount = principal < 30 ? principal : 30;
        _execute(_prepare(firstAmount, principal - firstAmount, 1000, 10, 1000));
        assertEq(ExecutorLiquiditySource(_first).withdrawn(), firstAmount);
        assertEq(ExecutorLiquiditySource(_second).withdrawn(), principal - firstAmount);
        assertEq(IERC20(_asset).balanceOf(_request), principal);
        assertEq(IERC20(_asset).allowance(address(adapter), _request), 0);
    }

    function test_SkipsAllSourcesWhenIdleFundsSuffice() public {
        IERC20(_asset).transfer(address(adapter), 150);
        bytes[] memory runtime = _prepare(0, 0, 100, 10, 1000);
        runtime[_layout.sourceCalls[0]] = "";
        runtime[_layout.sourceCalls[1]] = "";
        _execute(runtime);
        assertEq(ExecutorLiquiditySource(_first).calls(), 0);
        assertEq(ExecutorLiquiditySource(_second).calls(), 0);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 50);
    }

    function test_SkipsZeroCapacitySourceWithoutDecodingRuntime() public {
        ExecutorLiquiditySource(_first).setLiquidity(0);
        bytes[] memory runtime = _prepare(0, 100, 100, 10, 1000);
        runtime[_layout.sourceCalls[0]] = hex"dead";
        _execute(runtime);
        assertEq(ExecutorLiquiditySource(_first).calls(), 0);
        assertEq(ExecutorLiquiditySource(_second).withdrawn(), 100);
    }

    function test_ReadsSecondSourceCapacityAfterFirstSourceRuns() public {
        ExecutorLiquiditySource(_second).setLiquidity(1);
        ExecutorLiquiditySource(_first).setCallback(_second, abi.encodeCall(ExecutorLiquiditySource.setLiquidity, (70)));
        _execute(_prepare(30, 70, 100, 10, 1000));
        assertEq(ExecutorLiquiditySource(_second).withdrawn(), 70);
    }

    function test_PreservesReservedAllocationAndUsesOnlyFreeIdleFunds() public {
        IERC20(_asset).transfer(adapter.vault(), 50);
        MerkleAdapterDelegatorMock(_delegator).allocate(address(adapter), 50);
        IERC20(_asset).transfer(address(adapter), 20);
        _execute(_prepare(30, 50, 100, 10, 1000));
        assertEq(adapter.reservedAssets(), 50);
        assertEq(adapter.pendingAllocation(1), 50);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 50);
        assertEq(ExecutorLiquiditySource(_second).withdrawn(), 50);
    }

    function test_ReserveDeficitIsFundedBeforeMinting() public {
        MerkleAdapterDelegatorMock(_delegator).requestDeallocate(address(adapter), 50);
        MerkleAdapterOracleMock(adapter.oracle()).setNonce(2);
        ExecutorLiquiditySource(_first).setLiquidity(80);
        _execute(_prepare(80, 70, 100, 10, 1000));
        assertEq(adapter.reservedAssets(), 50);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 50);
        assertEq(ExecutorLiquiditySource(_second).withdrawn(), 70);
    }

    function test_ReservationsAreReadAgainAfterEachSource() public {
        MerkleAdapterDelegatorMock(_delegator).requestDeallocate(address(adapter), 50);
        assertEq(adapter.reservedAssets(), 0);
        ExecutorLiquiditySource(_first).setLiquidity(60);
        ExecutorLiquiditySource(_first)
            .setCallback(adapter.oracle(), abi.encodeCall(MerkleAdapterOracleMock.setNonce, (2)));
        _execute(_prepare(60, 90, 100, 10, 1000));
        assertEq(adapter.reservedAssets(), 50);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 50);
        assertEq(ExecutorLiquiditySource(_second).withdrawn(), 90);
    }

    function test_NewReservationDuringMintCannotConsumeReservedBalance() public {
        MerkleAdapterDelegatorMock(_delegator).requestDeallocate(address(adapter), 50);
        ThreeFRequestMock(_request)
            .setMintCallback(adapter.oracle(), abi.encodeCall(MerkleAdapterOracleMock.setNonce, (2)));
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        vm.expectRevert(IMerkleAdapter.InsufficientIdleAssets.selector);
        _execute(runtime);
        _assertRollback();
        assertEq(adapter.reservedAssets(), 0);
    }

    function test_InsufficientLiquidityRollsBackBothSources() public {
        ExecutorLiquiditySource(_second).setLiquidity(69);
        bytes[] memory runtime = _prepare(30, 69, 100, 10, 1000);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_WrongSourceAmountRollsBackDespiteValidMaskedLeaf() public {
        bytes[] memory runtime = _prepare(29, 71, 100, 10, 1000);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(runtime);
        _assertRollback();
    }

    function testFuzz_WrongFundingDeltaRollsBack(int256 adjustment) public {
        adjustment = bound(adjustment, -29, 30);
        vm.assume(adjustment != 0);
        ExecutorLiquiditySource(_first).setAdjustment(adjustment);
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_ChangedPrincipalDuringFundingCannotUseStaleRead() public {
        ExecutorLiquiditySource(_first)
            .setCallback(_request, abi.encodeCall(ThreeFRequestMock.authorizeMinting, (address(adapter), 90, 10)));
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(runtime);
        _assertRollback();
        (uint128 principal,) = ThreeFRequestMock(_request).mintAuthorization(address(adapter));
        assertEq(principal, 100);
    }

    function test_ChangedYieldDuringFundingCannotBypassConfiguredMinimum() public {
        ExecutorLiquiditySource(_first)
            .setCallback(_request, abi.encodeCall(ThreeFRequestMock.authorizeMinting, (address(adapter), 100, 9)));
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        IMerkleAdapter.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAdapter.Action[]));
        actions[0].data = abi.encodeCall(IThreeFPushRequest.mint, (100, 0));
        runtime[_layout.operation] = abi.encode(actions);
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
        ThreeFRequestMock(_request).authorizeMinting(address(adapter), 0, 0);
        bytes[] memory runtime = _prepare(0, 0, 100, 0, 1000);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_YieldFloorFailsBeforeFunding() public {
        bytes[] memory runtime = _prepare(30, 70, 100, 11, 1000);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_PeriodBudgetRejectsMint() public {
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 99);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_PeriodBudgetIncludesExistingRequests() public {
        _execute(_prepare(30, 70, 100, 10, 150));
        _request = _newRequest(2, 100);
        bytes[] memory runtime = _prepare(0, 100, 100, 10, 150);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        _execute(runtime);
        assertEq(IERC20(_asset).balanceOf(_request), 0);
        assertEq(IERC20(_asset).allowance(address(adapter), _request), 0);
        assertEq(ExecutorLiquiditySource(_second).withdrawn(), 70);
    }

    function test_MintRequestAddressIsPinnedByLeaf() public {
        address other = _newRequest(2, 100);
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        IMerkleAdapter.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAdapter.Action[]));
        actions[0].target = other;
        runtime[_layout.operation] = abi.encode(actions);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        _execute(runtime);
        _assertRollback();
        assertEq(IERC20(_asset).balanceOf(other), 0);
    }

    function test_RequestMustBelongToConfiguredFactory() public {
        ThreeFRequestFactoryMock(_requestsFactory).set(_request, false);
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_PolicyAmountsCannotBeSubstituted() public {
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        runtime[_layout.consume] = abi.encodeCall(IThreeFPolicy.consume, (1, 1000));
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_OwnerUpdatesYieldWithoutReplacingRecipeOrRoot() public {
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        ThreeFPolicy(_policy).setMinYieldPerRequest(100_001);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        _execute(runtime);
        ThreeFPolicy(_policy).setMinYieldPerRequest(100_000);
        _execute(runtime);
        assertEq(ThreeFPolicy(_policy).remainingAssets(), 900);
    }

    function test_MissingLeafRoleCannotBeReplacedByCallerRole() public {
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        IMerkleAdapter.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAdapter.Action[]));
        bytes32 leaf = _leaf(actions[0]);
        adapter.revokeRole(leaf, _executor);
        adapter.grantRole(leaf, _provider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _executor, leaf)
        );
        _execute(runtime);
        _assertRollback();
    }

    function test_InvalidMintProofRollsBackAllFunding() public {
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        IMerkleAdapter.Action[] memory actions = abi.decode(runtime[_layout.operation], (IMerkleAdapter.Action[]));
        actions[0].proof[0] ^= bytes32(uint256(1));
        runtime[_layout.operation] = abi.encode(actions);
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_InvalidClearApprovalProofRollsBackSuccessfulMint() public {
        bytes[] memory runtime = _prepare(30, 70, 100, 10, 1000);
        IExecutor.Permission memory permission = abi.decode(runtime[_layout.clearApproval], (IExecutor.Permission));
        permission.proof[0] ^= bytes32(uint256(1));
        runtime[_layout.clearApproval] = abi.encode(permission);
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        _execute(runtime);
        _assertRollback();
    }

    function test_ResetsExistingApprovalAndLeavesNoAllowance() public {
        _manage(_asset, abi.encodeCall(IERC20.approve, (_request, 500)));
        _execute(_prepare(30, 70, 100, 10, 1000));
        assertEq(ThreeFRequestMock(_request).allowanceAtMint(), 100);
        assertEq(IERC20(_asset).allowance(address(adapter), _request), 0);
    }

    function _newRequest(uint256 id, uint128 principal) internal returns (address request) {
        request = address(new ThreeFRequestMock(_asset, string.concat("request-", vm.toString(id))));
        ThreeFRequestFactoryMock(_requestsFactory).set(request, true);
        ThreeFRequestMock(request).authorizeMinting(address(adapter), principal, 10);
    }

    function _prepare(
        uint256 firstAmount,
        uint256 secondAmount,
        uint256 maxPrincipal,
        uint256 minYield,
        uint256 maxPosition
    ) internal returns (bytes[] memory runtime) {
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](4);
        actions[0] =
            _action(_first, abi.encodeCall(ExecutorLiquiditySource.withdraw, (address(adapter), firstAmount)), 36);
        actions[1] =
            _action(_second, abi.encodeCall(ExecutorLiquiditySource.withdraw, (address(adapter), secondAmount)), 36);
        actions[2] = _action(_asset, abi.encodeCall(IERC20.approve, (_request, 0)), 36);
        actions[3] = _action(_request, abi.encodeCall(IThreeFPushRequest.mint, (type(uint128).max, 0)), 4);
        _publish(actions);
        ExecutingRecipe.Source[] memory sources = new ExecutingRecipe.Source[](2);
        for (uint256 i; i < sources.length; ++i) {
            bytes32[] memory leaves = new bytes32[](1);
            leaves[0] = _leaf(actions[i]);
            sources[i] = ExecutingRecipe.Source(
                ExecutingRecipe.Read(actions[i].target, abi.encodeCall(ExecutorLiquiditySource.getLiquidity, ()), 0),
                leaves
            );
        }
        (IRecipeExecutor.Step[] memory recipe, ThreeFExecuting.Layout memory layout) = ThreeFExecuting.build(
            ThreeFExecuting.Config(
                ExecutingRecipe.Funding(address(adapter), adapter.vault(), _asset, sources),
                _request,
                _requestsFactory,
                _policy,
                _leaf(actions[2]),
                _leaf(actions[3]),
                maxPrincipal
            )
        );
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(maxPosition, 1 days);
        ThreeFPolicy(_policy).setMinYieldPerRequest(minYield * 1_000_000 / maxPrincipal);
        _layout = layout;
        RecipeExecutor(_executor).setRecipe(recipe);
        runtime = new bytes[](recipe.length);
        (uint128 principal, uint128 yieldAssets) = ThreeFRequestMock(_request).mintAuthorization(address(adapter));
        runtime[layout.consume] = abi.encodeCall(IThreeFPolicy.consume, (principal, yieldAssets));
        for (uint256 i; i < sources.length; ++i) {
            IMerkleAdapter.Action[] memory group = new IMerkleAdapter.Action[](1);
            group[0] = actions[i];
            runtime[layout.sourceCalls[i]] = abi.encode(group);
        }
        runtime[layout.approve] = abi.encode(IExecutor.Permission(actions[2].dataMask, actions[2].proof));
        runtime[layout.clearApproval] = runtime[layout.approve];
        IMerkleAdapter.Action[] memory mint = new IMerkleAdapter.Action[](1);
        mint[0] = actions[3];
        runtime[layout.operation] = abi.encode(mint);
        for (uint256 i; i < recipe.length; ++i) {
            assertTrue(recipe[i].operation != IRecipeExecutor.Operation.Input);
        }
    }

    function _publish(IMerkleAdapter.Action[] memory actions) internal {
        bytes32[] memory tree = new bytes32[](8);
        for (uint256 i; i < actions.length; ++i) {
            tree[4 + i] = _leaf(actions[i]);
            adapter.grantRole(tree[4 + i], _executor);
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
        roots.setRoot(address(adapter), tree[1]);
        adapter.acceptRoot(tree[1]);
    }

    function _action(address target, bytes memory data, uint256 maskStart)
        internal
        pure
        returns (IMerkleAdapter.Action memory action)
    {
        action = IMerkleAdapter.Action(target, 0, data, new bytes(data.length), new bytes32[](0));
        for (uint256 i = maskStart; i < data.length; ++i) {
            action.dataMask[i] = 0xff;
        }
    }

    function _leaf(IMerkleAdapter.Action memory action) internal pure returns (bytes32) {
        return MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask);
    }

    function _execute(bytes[] memory runtime) internal returns (uint256[] memory) {
        vm.prank(_provider);
        return RecipeExecutor(_executor).execute(new uint256[](0), runtime);
    }

    function _assertRollback() internal view {
        assertEq(ExecutorLiquiditySource(_first).withdrawn(), 0);
        assertEq(ExecutorLiquiditySource(_second).withdrawn(), 0);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 0);
        assertEq(IERC20(_asset).balanceOf(_request), 0);
        assertEq(IERC20(_asset).allowance(address(adapter), _request), 0);
        assertEq(ThreeFRequestMock(_request).mintCalls(), 0);
        (,,, uint256 spent) = ThreeFPolicy(_policy).assetLimit();
        assertEq(spent, 0);
    }
}
