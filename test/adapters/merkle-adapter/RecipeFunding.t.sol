// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {IRecipes, OP_ADD, OP_EQUAL} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {Token} from "test/mocks/Token.sol";

/// @dev Executes conditional calls in the production executor and account capability.
contract RecipeFundingTest is CapabilityTestBase {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    address internal _asset;
    address internal _executor;
    address internal _source;

    function setUp() public {
        _asset = address(new Token("Funding"));
        _source = address(new ConditionalFundingSourceMock(_asset));
        _deployAdapter(_asset);
        _executor = address(new RecipeExecutor(address(this), account));
        RecipeExecutor(_executor).setCaller(address(this));
        _installCapability(adapter, address(new RecipeCapability()), _recipeSelectors());
        IERC20(_asset).transfer(_source, 100);
    }

    function testFuzz_AlreadyFundedSourceStillRunsPreparation(bool skipUnusedReads) public {
        IERC20(_asset).transfer(account, 10);
        ExecutingRecipe.Funding memory funding = _funding(1, skipUnusedReads);
        funding.sources[0].prepare =
            ExecutingRecipe.Call({target: _source, data: abi.encodeCall(ConditionalFundingSourceMock.fail, ())});
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        builder.fund(funding, 10);
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(ConditionalFundingSourceMock.Failed.selector);
        RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](1));
        assertEq(IERC20(_asset).balanceOf(account), 10);
        assertEq(ConditionalFundingSourceMock(_source).preparations(), 0);
    }

    function testFuzz_LaterPreparationFailureRollsBackEarlierFunding(bool skipUnusedReads) public {
        ConditionalFundingSourceMock(_source).prepare(10);
        ExecutingRecipe.Funding memory funding = _funding(2, skipUnusedReads);
        IMerkleAccount.Action memory action = _fundingAction();
        funding.sources[0].leaves = new bytes32[](1);
        funding.sources[0].leaves[0] = _authorize(action);
        funding.sources[0].amountOffsets = new uint256[][](1);
        funding.sources[0].amountOffsets[0] = new uint256[](1);
        funding.sources[0].amountOffsets[0][0] = 4;
        funding.sources[1].prepare =
            ExecutingRecipe.Call({target: _source, data: abi.encodeCall(ConditionalFundingSourceMock.fail, ())});
        bytes[] memory runtime = new bytes[](2);
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = action;
        runtime[0] = abi.encode(actions);
        runtime[1] = hex"deadbeef";
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        builder.fund(funding, 10);
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        vm.expectRevert(ConditionalFundingSourceMock.Failed.selector);
        RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](0), runtime);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(ConditionalFundingSourceMock(_source).preparations(), 1);
        assertEq(ConditionalFundingSourceMock(_source).withdrawals(), 0);
        assertEq(ConditionalFundingSourceMock(_source).caller(), address(0));
    }

    function testFuzz_NeededPreparationUsesExecutorBeforeCapacity(bool skipUnusedReads) public {
        ExecutingRecipe.Funding memory funding = _funding(1, skipUnusedReads);
        funding.sources[0].prepare =
            ExecutingRecipe.Call({target: _source, data: abi.encodeCall(ConditionalFundingSourceMock.prepare, (10))});
        IMerkleAccount.Action memory action = _fundingAction();
        funding.sources[0].leaves = new bytes32[](1);
        funding.sources[0].leaves[0] = _authorize(action);
        funding.sources[0].amountOffsets = new uint256[][](1);
        funding.sources[0].amountOffsets[0] = new uint256[](1);
        funding.sources[0].amountOffsets[0][0] = 4;
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = action;
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = abi.encode(actions);
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        builder.fund(funding, 10);
        _executeFunding(builder.finish(), runtime);
        assertEq(IERC20(_asset).balanceOf(account), 10);
        assertEq(ConditionalFundingSourceMock(_source).prepareCaller(), _executor);
        assertEq(ConditionalFundingSourceMock(_source).capacity(), 0);
        assertEq(ConditionalFundingSourceMock(_source).withdrawals(), 1);
    }

    function testFuzz_ZeroGateSkipsInvalidTargetDataAndBindings(bool capability) public {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        uint256[] memory bindings = new uint256[](1);
        bindings[0] = ExecutingRecipe.binding(0, builder.input(99));
        builder.callIf(0, address(0), hex"deadbeef", bindings);
        _execute(builder.finish(), new uint256[](0), capability);
    }

    function testFuzz_NonzeroGateBubblesTargetRevert(bool capability) public {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        builder.callIf(1, _source, abi.encodeCall(ConditionalFundingSourceMock.fail, ()), new uint256[](0));
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        if (capability) {
            IMerkleAccount.Action[] memory actions = _publishCall(
                account, abi.encodeCall(IRecipeCapability.execute, (recipe.queries, recipe.steps, new uint256[](0)))
            );
            vm.expectRevert(ConditionalFundingSourceMock.Failed.selector);
            MerkleAccount(payable(account)).manage(actions);
        } else {
            RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
            vm.expectRevert(ConditionalFundingSourceMock.Failed.selector);
            RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        }
    }

    function testFuzz_NonzeroGateBindsFullWidthValueAndPreservesCaller(uint256 value, bool capability) public {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        uint256[] memory bindings = new uint256[](1);
        bindings[0] = ExecutingRecipe.binding(4, builder.input(1));
        builder.callIf(1, _source, abi.encodeCall(ConditionalFundingSourceMock.prepare, (0)), bindings);
        uint256[] memory inputs = new uint256[](2);
        inputs[0] = type(uint256).max;
        inputs[1] = value;
        uint256[] memory values = _execute(builder.finish(), inputs, capability);
        assertEq(ConditionalFundingSourceMock(_source).capacity(), value);
        assertEq(ConditionalFundingSourceMock(_source).prepareCaller(), capability ? account : _executor);
        assertEq(values[0], 0);
    }

    function testFuzz_NonzeroGateRejectsInvalidBindings(bool capability) public {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        uint256[] memory bindings = new uint256[](1);
        bindings[0] = ExecutingRecipe.binding(0, 1);
        builder.callIf(1, _source, abi.encodeCall(ConditionalFundingSourceMock.prepare, (0)), bindings);
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        if (capability) {
            IMerkleAccount.Action[] memory actions = _publishCall(
                account, abi.encodeCall(IRecipeCapability.execute, (recipe.queries, recipe.steps, new uint256[](0)))
            );
            vm.expectRevert(IRecipes.InvalidCall.selector);
            MerkleAccount(payable(account)).manage(actions);
        } else {
            RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
            vm.expectRevert(IRecipes.InvalidCall.selector);
            RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        }
        assertEq(ConditionalFundingSourceMock(_source).preparations(), 0);
    }

    function testFuzz_ConditionalCallCannotBeReferencedAsNumber(bool capability, bool skipped) public {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        uint256 callIndex = builder.callIf(
            skipped ? 0 : 1, _source, abi.encodeCall(ConditionalFundingSourceMock.prepare, (10)), new uint256[](0)
        );
        builder.instruction(OP_ADD, abi.encode(ExecutingRecipe.result(callIndex), uint256(1)));
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        if (capability) {
            IMerkleAccount.Action[] memory actions = _publishCall(
                account, abi.encodeCall(IRecipeCapability.execute, (recipe.queries, recipe.steps, new uint256[](0)))
            );
            vm.expectRevert(IRecipes.InvalidReference.selector);
            MerkleAccount(payable(account)).manage(actions);
        } else {
            RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
            vm.expectRevert(IRecipes.InvalidReference.selector);
            RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](0), new bytes[](0));
        }
        assertEq(ConditionalFundingSourceMock(_source).preparations(), 0);
    }

    function testFuzz_ConditionalCallInvalidatesBalanceCache(bool capability) public {
        address holder = capability ? account : _executor;
        IERC20(_asset).transfer(holder, 10);
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        uint256 beforeValue = builder.balance(_asset, holder);
        builder.callIf(1, _asset, abi.encodeCall(IERC20.transfer, (_source, 3)), new uint256[](0));
        uint256 afterValue = builder.balance(_asset, holder);
        builder.check(OP_EQUAL, afterValue, 7);
        uint256[] memory values = _execute(builder.finish(), new uint256[](0), capability);
        assertEq(values[uint216(beforeValue)], 10);
        assertEq(values[uint216(afterValue)], 7);
        assertEq(IERC20(_asset).balanceOf(holder), 7);
    }

    /// forge-config: default.isolate = true
    function test_GasCallIfTakenExecutor() public {
        _snapshotCallIf(1, false, "callIfTakenExecutor");
    }

    /// forge-config: default.isolate = true
    function test_GasCallIfSkippedExecutor() public {
        _snapshotCallIf(0, false, "callIfSkippedExecutor");
    }

    /// forge-config: default.isolate = true
    function test_GasCallIfTakenCapability() public {
        _snapshotCallIf(1, true, "callIfTakenCapability");
    }

    /// forge-config: default.isolate = true
    function test_GasCallIfSkippedCapability() public {
        _snapshotCallIf(0, true, "callIfSkippedCapability");
    }

    function _snapshotCallIf(uint256 gate, bool capability, string memory name) internal {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(0);
        builder.callIf(gate, _source, abi.encodeCall(ConditionalFundingSourceMock.prepare, (10)), new uint256[](0));
        _execute(builder.finish(), new uint256[](0), capability);
        vm.snapshotGasLastCall("RecipeFunding", name);
        assertEq(ConditionalFundingSourceMock(_source).preparations(), gate);
    }

    function _funding(uint256 length, bool skipUnusedReads)
        internal
        view
        returns (ExecutingRecipe.Funding memory funding)
    {
        funding.account = account;
        funding.asset = _asset;
        funding.skipUnusedReads = skipUnusedReads;
        funding.sources = new ExecutingRecipe.Source[](length);
        for (uint256 i; i < length; ++i) {
            funding.sources[i].capacity =
                ExecutingRecipe.Read({target: _source, data: abi.encodeWithSignature("capacity()"), offset: 0});
        }
    }

    function _fundingAction() internal view returns (IMerkleAccount.Action memory action) {
        bytes memory data = abi.encodeCall(ConditionalFundingSourceMock.withdraw, (0, account));
        bytes memory mask = new bytes(data.length);
        for (uint256 i = 4; i < 36; ++i) {
            mask[i] = 0xff;
        }
        action = IMerkleAccount.Action({target: _source, value: 0, data: data, dataMask: mask, proof: new bytes32[](0)});
    }

    function _authorize(IMerkleAccount.Action memory action) internal returns (bytes32 leaf) {
        leaf = MerkleAdapterVerifier.leaf(action.target, 0, action.data, action.dataMask);
        roots.setRoot(account, leaf);
        MerkleAccount(payable(account)).acceptRoot(leaf);
        MerkleAccount(payable(account)).grantRole(leaf, _executor);
    }

    function _executeFunding(ExecutingRecipe.Recipe memory recipe, bytes[] memory runtime) internal {
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, new uint256[](0), runtime);
    }

    function _execute(ExecutingRecipe.Recipe memory recipe, uint256[] memory inputs, bool capability)
        internal
        returns (uint256[] memory)
    {
        if (capability) {
            return abi.decode(
                _manage(account, abi.encodeCall(IRecipeCapability.execute, (recipe.queries, recipe.steps, inputs))),
                (uint256[])
            );
        }
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        return RecipeExecutor(_executor).execute(recipe.queries, recipe.steps, inputs, new bytes[](0));
    }
}

/// @dev Local source whose capacity becomes available only after executor preparation.
contract ConditionalFundingSourceMock {
    error Failed();

    address public immutable asset;
    uint256 public capacity;
    uint256 public preparations;
    uint256 public withdrawals;
    address public prepareCaller;
    address public caller;

    constructor(address newAsset) {
        asset = newAsset;
    }

    function prepare(uint256 newCapacity) public {
        capacity = newCapacity;
        ++preparations;
        prepareCaller = msg.sender;
    }

    function withdraw(uint256 amount, address recipient) public {
        capacity -= amount;
        ++withdrawals;
        caller = msg.sender;
        IERC20(asset).transfer(recipient, amount);
    }

    function fail() public pure {
        revert Failed();
    }
}
