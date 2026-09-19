// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {ExecutorLiquiditySource} from "./Executor.t.sol";
import {ExecutorPostActionToken} from "./ExecutorPostActions.t.sol";
import {ExecutorTestHelper} from "./ExecutorTestHelper.sol";
import {ActionOracleMock} from "./LiquidLaneConnector.t.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {LiquidLaneConnector} from "src/contracts/merkle-adapter/LiquidLaneConnector.sol";
import {LiquidLaneExecutor} from "src/contracts/periphery/LiquidLaneExecutor.sol";
import {OracleRegistry} from "src/contracts/merkle-adapter/OracleRegistry.sol";
import {RecipeExecutor} from "src/contracts/periphery/RecipeExecutor.sol";

import {Token} from "test/mocks/Token.sol";

import {LiquidityRecipe} from "script/recipes/LiquidityRecipe.sol";
import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IAssetRateLimits} from "src/interfaces/merkle-adapter/IAssetRateLimits.sol";
import {IExecutor} from "src/interfaces/periphery/IExecutor.sol";
import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";
import {ILiquidLaneConnector} from "src/interfaces/merkle-adapter/ILiquidLaneConnector.sol";
import {ILiquidLaneExecutor} from "src/interfaces/periphery/ILiquidLaneExecutor.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IRecipeExecutor} from "src/interfaces/periphery/IRecipeExecutor.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

contract RecipeLiquidityTest is CapabilityTestBase, ExecutorTestHelper {
    address internal _asset;
    address internal _rwa;
    address internal _executor;
    address internal _recipeExecutor;
    address internal _lane;
    address internal _first;
    address internal _second;
    address internal _issuer;
    address internal _recipient = makeAddr("recipient");
    address internal _provider = makeAddr("provider");

    function setUp() public {
        _asset = address(new Token("Funding"));
        _rwa = address(new ExecutorPostActionToken());
        _deployAdapter(_asset);
        address registry = address(new OracleRegistry(address(this)));
        address prices = address(new MigratablesFactory(address(this)));
        MigratablesFactory(prices).whitelist(address(new ActionOracleMock(prices, 1e18)));
        address lanes = address(new MigratablesFactory(address(this)));
        MigratablesFactory(lanes).whitelist(address(new LiquidLaneConnector(lanes, registry)));
        _lane =
            MigratablesFactory(lanes).create(1, address(this), abi.encode(address(adapter), _asset, new address[](0)));
        _executor = IImmutableFactory(address(new ImmutableFactory(type(LiquidLaneExecutor).creationCode)))
            .create(abi.encode(address(this), address(adapter), _lane));
        _recipeExecutor = address(new RecipeExecutor(address(this), address(adapter)));
        LiquidLaneExecutor(_executor).setCaller(_recipeExecutor);
        RecipeExecutor(_recipeExecutor).setCaller(_provider);
        OracleRegistry(registry)
            .setOracle(_lane, _rwa, MigratablesFactory(prices).create(1, address(this), abi.encode(_asset, _lane)));
        _manage(_lane, abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (_rwa)));
        _manage(_lane, abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (_rwa, type(uint256).max, 1 days)));
        IERC20(_rwa).transfer(_lane, 1_000_000);
        _first = address(new ExecutorLiquiditySource(IERC20(_asset), address(adapter)));
        _second = address(new ExecutorLiquiditySource(IERC20(_asset), address(adapter)));
        IERC20(_asset).transfer(_first, 1_000_000);
        IERC20(_asset).transfer(_second, 1_000_000);
        ExecutorLiquiditySource(_first).setLiquidity(30);
        ExecutorLiquiditySource(_second).setLiquidity(1_000_000);
        _issuer = address(new RecipeIssuerReceipt(_rwa));
    }

    function test_OrderedSourcesSignedSwapAndIssuerReceipt() public {
        (IMerkleAdapter.Action[] memory calls, IMerkleAdapter.Action[] memory posts) = _configure(100, 100);
        IRecipeExecutor.Step[] memory recipe = _recipe(_issuer, 100, 100, 1_000_000);
        uint256[] memory values = _execute(recipe, _liquidLaneCall(_executor, calls, posts, 0));
        assertEq(values[1], 100);
        assertEq(values[13], 100);
        assertEq(ExecutorLiquiditySource(_first).withdrawn(), 30);
        assertEq(ExecutorLiquiditySource(_second).withdrawn(), 70);
        assertEq(IERC20(_asset).balanceOf(_recipient), 100);
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 0);
        assertEq(IERC20(_issuer).balanceOf(address(adapter)), 100);
        assertEq(ExecutorPostActionToken(_rwa).redeemed(), 100);
        assertEq(IERC20(_asset).allowance(address(adapter), _lane), 0);
        assertEq(IERC20(_rwa).allowance(address(adapter), _issuer), 0);
        assertFalse(adapter.hasRole(_leaf(calls[0]), _provider));
        assertFalse(adapter.hasRole(_leaf(calls[0]), _recipeExecutor));
        assertTrue(adapter.hasRole(_leaf(calls[0]), _executor));
    }

    function testFuzz_ActualCalldataAmountBoundAndSourcePriority(uint256 amount) public {
        amount = bound(amount, 1, 1000);
        (IMerkleAdapter.Action[] memory calls, IMerkleAdapter.Action[] memory posts) = _configure(amount, amount);
        _execute(_recipe(_issuer, 1000, 1000, 1000), _liquidLaneCall(_executor, calls, posts, 0));
        assertEq(ExecutorLiquiditySource(_first).withdrawn(), amount < 30 ? amount : 30);
        assertEq(ExecutorLiquiditySource(_second).withdrawn(), amount > 30 ? amount - 30 : 0);
        assertEq(IERC20(_issuer).balanceOf(address(adapter)), amount);
    }

    function test_ExcessActualSwapAmountFailsBeforeFunding() public {
        (IMerkleAdapter.Action[] memory calls, IMerkleAdapter.Action[] memory posts) = _configure(101, 101);
        IRecipeExecutor.Step[] memory recipe = _recipe(_issuer, 100, 100, 1000);
        bytes memory callData = _liquidLaneCall(_executor, calls, posts, 0);
        RecipeExecutor(_recipeExecutor).setRecipe(recipe);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _submit(recipe.length, callData);
        _assertRollback();
    }

    function test_GrossFundingQuoteCapFailsBeforeFunding() public {
        (IMerkleAdapter.Action[] memory calls, IMerkleAdapter.Action[] memory posts) = _configure(100, 100);
        IRecipeExecutor.Step[] memory recipe = _recipe(_issuer, 100, 99, 1000);
        bytes memory callData = _liquidLaneCall(_executor, calls, posts, 0);
        RecipeExecutor(_recipeExecutor).setRecipe(recipe);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _submit(recipe.length, callData);
        _assertRollback();
    }

    function test_WrongSelectorCannotUseTrustedExecutor() public {
        (IMerkleAdapter.Action[] memory calls, IMerkleAdapter.Action[] memory posts) = _configure(100, 100);
        IRecipeExecutor.Step[] memory recipe = _recipe(_issuer, 100, 100, 1000);
        bytes memory callData = _liquidLaneCall(_executor, calls, posts, 0);
        bytes4 selector = ILiquidLaneExecutor.invalidateNonce.selector;
        for (uint256 i; i < 4; ++i) {
            callData[i] = selector[i];
        }
        RecipeExecutor(_recipeExecutor).setRecipe(recipe);
        vm.expectRevert(IRecipeExecutor.InvalidCall.selector);
        _submit(recipe.length, callData);
        _assertRollback();
    }

    function test_ProviderCannotBypassRecipeThroughTypedExecutor() public {
        (IMerkleAdapter.Action[] memory calls, IMerkleAdapter.Action[] memory posts) = _configure(101, 101);
        bytes memory callData = _liquidLaneCall(_executor, calls, posts, 0);
        vm.prank(_provider);
        (bool success, bytes memory result) = _executor.call(callData);
        assertFalse(success);
        assertEq(result, abi.encodeWithSelector(IExecutor.InvalidCaller.selector));
        _assertRollback();
    }

    function test_SkippedRequiredRedemptionRollsBackSwapAndSources() public {
        (IMerkleAdapter.Action[] memory calls,) = _configure(100, 100);
        IRecipeExecutor.Step[] memory recipe = _recipe(_issuer, 100, 100, 1000);
        bytes memory callData = _liquidLaneCall(_executor, calls, new IMerkleAdapter.Action[](0), 0);
        RecipeExecutor(_recipeExecutor).setRecipe(recipe);
        vm.expectRevert(ILiquidLaneExecutor.InvalidPostActions.selector);
        _submit(recipe.length, callData);
        _assertRollback();
    }

    function test_BurningRwaWithoutIssuerReceiptRollsBackEverything() public {
        (IMerkleAdapter.Action[] memory calls, IMerkleAdapter.Action[] memory posts) = _configure(100, 0);
        IRecipeExecutor.Step[] memory recipe = _recipe(_issuer, 100, 100, 1000);
        bytes memory callData = _liquidLaneCall(_executor, calls, posts, 0);
        RecipeExecutor(_recipeExecutor).setRecipe(recipe);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _submit(recipe.length, callData);
        _assertRollback();
    }

    function testFuzz_UnderpaidIssuerReceiptRollsBack(uint256 receipt) public {
        receipt = bound(receipt, 0, 99);
        (IMerkleAdapter.Action[] memory calls, IMerkleAdapter.Action[] memory posts) = _configure(100, receipt);
        IRecipeExecutor.Step[] memory recipe = _recipe(_issuer, 100, 100, 1000);
        bytes memory callData = _liquidLaneCall(_executor, calls, posts, 0);
        RecipeExecutor(_recipeExecutor).setRecipe(recipe);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _submit(recipe.length, callData);
        _assertRollback();
    }

    function test_RepeatedFillsCannotExceedReceiptPositionCap() public {
        (IMerkleAdapter.Action[] memory calls, IMerkleAdapter.Action[] memory posts) = _configure(100, 100);
        IRecipeExecutor.Step[] memory recipe = _recipe(_issuer, 100, 100, 150);
        _execute(recipe, _liquidLaneCall(_executor, calls, posts, 0));
        (calls, posts) = _configure(100, 100);
        bytes memory callData = _liquidLaneCall(_executor, calls, posts, 0);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _submit(recipe.length, callData);
        assertEq(IERC20(_issuer).balanceOf(address(adapter)), 100);
        assertEq(IERC20(_asset).balanceOf(_recipient), 100);
        assertEq(ExecutorLiquiditySource(_first).withdrawn(), 30);
        assertEq(ExecutorLiquiditySource(_second).withdrawn(), 70);
        assertEq(ExecutorPostActionToken(_rwa).redeemed(), 100);
    }

    function test_CuratorsCanDisableRedemptionAndRetainAcquiredRwa() public {
        (IMerkleAdapter.Action[] memory calls,) = _configure(100, 100);
        LiquidLaneExecutor(_executor).setPostActionLeaves(_rwa, new bytes32[](0));
        _execute(_recipe(_rwa, 100, 100, 1000), _liquidLaneCall(_executor, calls, new IMerkleAdapter.Action[](0), 0));
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 100);
        assertEq(IERC20(_issuer).balanceOf(address(adapter)), 0);
        assertEq(IERC20(_asset).balanceOf(_recipient), 100);
    }

    function test_MissingTypedExecutorRoleStillRevertsWithValidRecipe() public {
        (IMerkleAdapter.Action[] memory calls, IMerkleAdapter.Action[] memory posts) = _configure(100, 100);
        bytes32 leaf = _leaf(calls[0]);
        adapter.revokeRole(leaf, _executor);
        IRecipeExecutor.Step[] memory recipe = _recipe(_issuer, 100, 100, 1000);
        bytes memory callData = _liquidLaneCall(_executor, calls, posts, 0);
        RecipeExecutor(_recipeExecutor).setRecipe(recipe);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _executor, leaf)
        );
        _submit(recipe.length, callData);
        _assertRollback();
    }

    function test_InvalidIssuerProofRollsBackBothSources() public {
        (IMerkleAdapter.Action[] memory calls, IMerkleAdapter.Action[] memory posts) = _configure(100, 100);
        posts[1].proof[0] ^= bytes32(uint256(1));
        IRecipeExecutor.Step[] memory recipe = _recipe(_issuer, 100, 100, 1000);
        bytes memory callData = _liquidLaneCall(_executor, calls, posts, 0);
        RecipeExecutor(_recipeExecutor).setRecipe(recipe);
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        _submit(recipe.length, callData);
        _assertRollback();
    }

    function _execute(IRecipeExecutor.Step[] memory recipe, bytes memory callData) internal returns (uint256[] memory) {
        RecipeExecutor(_recipeExecutor).setRecipe(recipe);
        return _submit(recipe.length, callData);
    }

    function _submit(uint256 length, bytes memory callData) internal returns (uint256[] memory) {
        bytes[] memory runtime = new bytes[](length);
        runtime[LiquidityRecipe.INVOKE_STEP] = callData;
        vm.prank(_provider);
        return RecipeExecutor(_recipeExecutor).execute(new uint256[](0), runtime);
    }

    function _recipe(address receipt, uint256 maxAmount, uint256 maxFunding, uint256 maxBalance)
        internal
        view
        returns (IRecipeExecutor.Step[] memory)
    {
        return LiquidityRecipe.liquidLane(
            LiquidityRecipe.Configuration(
                _executor, address(adapter), _lane, _rwa, receipt, maxAmount, maxFunding, 1, 1, maxBalance
            )
        );
    }

    function _configure(uint256 amount, uint256 receipt)
        internal
        returns (IMerkleAdapter.Action[] memory calls, IMerkleAdapter.Action[] memory posts)
    {
        calls = new IMerkleAdapter.Action[](4);
        uint256 firstLiquidity = ExecutorLiquiditySource(_first).getLiquidity();
        uint256 firstAmount = amount < firstLiquidity ? amount : firstLiquidity;
        calls[0] = _action(_first, abi.encodeCall(ExecutorLiquiditySource.withdraw, (address(adapter), firstAmount)));
        calls[1] = _action(
            _second, abi.encodeCall(ExecutorLiquiditySource.withdraw, (address(adapter), amount - firstAmount))
        );
        calls[2] = _action(_asset, abi.encodeCall(IERC20.approve, (_lane, amount)));
        calls[3] = _action(
            _lane,
            abi.encodeCall(ILiquidLaneConnector.swap, (ILiquidLaneConnector.Swap(_recipient, _rwa, amount, amount)))
        );
        _mask(calls[0], 36, 68);
        _mask(calls[1], 36, 68);
        _mask(calls[2], 36, 68);
        _mask(calls[3], 68, 132);
        posts = new IMerkleAdapter.Action[](2);
        posts[0] = _action(_rwa, abi.encodeCall(IERC20.approve, (_issuer, amount)));
        posts[1] = _action(_issuer, abi.encodeCall(RecipeIssuerReceipt.redeem, (amount, receipt)));
        _mask(posts[0], 36, 68);
        _mask(posts[1], 4, 68);
        _publish(calls, posts, _executor);
        IExecutor.Action[] memory sources = new IExecutor.Action[](2);
        sources[0] = IExecutor.Action(_first, abi.encodeCall(ExecutorLiquiditySource.getLiquidity, ()), _leaf(calls[0]));
        sources[1] =
            IExecutor.Action(_second, abi.encodeCall(ExecutorLiquiditySource.getLiquidity, ()), _leaf(calls[1]));
        LiquidLaneExecutor(_executor).setActions(sources, _leaf(calls[2]), _leaf(calls[3]));
        bytes32[] memory postLeaves = new bytes32[](2);
        postLeaves[0] = _leaf(posts[0]);
        postLeaves[1] = _leaf(posts[1]);
        LiquidLaneExecutor(_executor).setPostActionLeaves(_rwa, postLeaves);
    }

    function _publish(IMerkleAdapter.Action[] memory calls, IMerkleAdapter.Action[] memory posts, address executor)
        internal
    {
        uint256 count = calls.length + posts.length;
        uint256 width = 1;
        uint256 depth;
        while (width < count) {
            width *= 2;
            ++depth;
        }
        bytes32[] memory tree = new bytes32[](width * 2);
        for (uint256 i; i < count; ++i) {
            bytes32 leaf = _leaf(i < calls.length ? calls[i] : posts[i - calls.length]);
            tree[width + i] = leaf;
            adapter.grantRole(leaf, executor);
        }
        for (uint256 i = width - 1; i > 0; --i) {
            bytes32 a = tree[i * 2];
            bytes32 b = tree[i * 2 + 1];
            tree[i] = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        }
        for (uint256 i; i < count; ++i) {
            bytes32[] memory proof = new bytes32[](depth);
            uint256 index = width + i;
            for (uint256 j; j < depth; ++j) {
                proof[j] = tree[index ^ 1];
                index /= 2;
            }
            if (i < calls.length) calls[i].proof = proof;
            else posts[i - calls.length].proof = proof;
        }
        roots.setRoot(address(adapter), tree[1]);
        adapter.acceptRoot(tree[1]);
    }

    function _action(address target, bytes memory data) internal pure returns (IMerkleAdapter.Action memory) {
        return IMerkleAdapter.Action(target, 0, data, new bytes(data.length), new bytes32[](0));
    }

    function _mask(IMerkleAdapter.Action memory action, uint256 start, uint256 end) internal pure {
        for (uint256 i = start; i < end; ++i) {
            action.dataMask[i] = 0xff;
        }
    }

    function _leaf(IMerkleAdapter.Action memory action) internal pure returns (bytes32) {
        return MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask);
    }

    function _assertRollback() internal view {
        assertEq(ExecutorLiquiditySource(_first).withdrawn(), 0);
        assertEq(ExecutorLiquiditySource(_second).withdrawn(), 0);
        assertEq(IERC20(_asset).balanceOf(_first), 1_000_000);
        assertEq(IERC20(_asset).balanceOf(_second), 1_000_000);
        assertEq(IERC20(_asset).balanceOf(_recipient), 0);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 0);
        assertEq(IERC20(_asset).allowance(address(adapter), _lane), 0);
        assertEq(IERC20(_rwa).balanceOf(_lane), 1_000_000);
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 0);
        assertEq(IERC20(_rwa).allowance(address(adapter), _issuer), 0);
        assertEq(IERC20(_issuer).balanceOf(address(adapter)), 0);
        assertEq(ExecutorPostActionToken(_rwa).redeemed(), 0);
        assertEq(LiquidLaneConnector(_lane).remainingAssets(_rwa), type(uint256).max);
    }
}

/// @dev Issuer integration fixture: redeemed RWA is burned and asynchronous claims are minted to the adapter.
contract RecipeIssuerReceipt is ERC20 {
    address public immutable rwa;

    constructor(address newRwa) ERC20("Issuer redemption receipt", "RECEIPT") {
        rwa = newRwa;
    }

    function redeem(uint256 amount, uint256 receipts) public {
        IERC20(rwa).transferFrom(msg.sender, address(this), amount);
        ExecutorPostActionToken(rwa).redeem(amount);
        _mint(msg.sender, receipts);
    }
}
