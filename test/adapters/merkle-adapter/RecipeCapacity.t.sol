// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {ExecutingRecipe} from "../../../script/recipes/ExecutingRecipe.sol";
import {RecipeExecutor} from "../../../src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {MerkleAccount} from "../../../src/contracts/merkle-adapter/MerkleAccount.sol";

import {ActionMasker} from "../../../src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IMerkleAccount} from "../../../src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeExecutor} from "../../../src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {IRecipes, OP_LESS_OR_EQUAL} from "../../../src/interfaces/merkle-adapter/IRecipes.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {SSTORE2} from "solady/utils/SSTORE2.sol";

contract RecipeCapacityTest is CapabilityTestBase {
    using ExecutingRecipe for ExecutingRecipe.Builder;

    RecipeExecutor internal executor;
    CapacityToken internal token;
    CapacityLiquidityPool internal pool;
    CapacityEffect internal effect;
    bytes[] internal _runtime;
    uint256 internal _prefixEnd;

    function setUp() public {
        token = new CapacityToken();
        _deployAdapter(address(token));
        executor = new RecipeExecutor(address(this), account);
        executor.setCaller(address(this));
        pool = new CapacityLiquidityPool(address(token), account);
        effect = new CapacityEffect();
        token.mint(address(pool), 100);
        token.mint(account, 10);
    }

    function test_CapacityRunsOrderedFundingWithSharedLiquidityAndRollsBack() public {
        _configure(false, false);
        (address asset, uint256 amount) = executor.capacity();
        assertEq(asset, address(token));
        assertEq(amount, 110);
        _assertUnchanged();
    }

    /// forge-config: default.isolate = true
    function test_GasCapacityConfigurationAndRollback() public {
        _configure(false, false);
        vm.snapshotGasLastCall("RecipeExecutor", "setCapacity");
        (, uint256 amount) = executor.capacity();
        vm.snapshotGasLastCall("RecipeExecutor", "capacity");
        assertEq(amount, 110);
        _assertUnchanged();
    }

    function test_CapacityPreparesSourcesBeforeReadingAndRollsPreparationBack() public {
        _configure(true, false);
        pool.setLimits(0, 20);
        (, uint256 amount) = executor.capacity();
        assertEq(amount, 110);
        assertEq(pool.limits(0), 0);
        assertEq(pool.limits(1), 20);
        assertEq(pool.prepared(), 0);
        assertEq(pool.withdrawn(), 0);
        assertEq(token.balanceOf(account), 10);
        assertEq(token.balanceOf(address(pool)), 100);
    }

    function test_CapacityRejectsSpoofedThirtyTwoByteSourceRevert() public {
        _configure(false, false);
        pool.setFailure(true);
        vm.expectRevert(IRecipeExecutor.CapacityUnavailable.selector);
        executor.capacity();
        _assertUnchanged();
    }

    function test_CapacityFailsClosedWithoutTheLastSourceBound() public {
        _configure(false, true);
        vm.expectRevert(IRecipeExecutor.CapacityUnavailable.selector);
        executor.capacity();
        _assertUnchanged();
    }

    function test_CapacityReturnsZeroWhenNoFundingExists() public {
        _configure(false, false);
        deal(address(token), account, 0);
        deal(address(token), address(pool), 0);
        (, uint256 amount) = executor.capacity();
        assertEq(amount, 0);
        assertEq(pool.withdrawn(), 0);
    }

    function test_CapacityRechecksTheCurrentMerkleRoot() public {
        _configure(false, false);
        bytes32 root = keccak256("replacement root");
        roots.setRoot(account, root);
        MerkleAccount(payable(account)).acceptRoot(root);
        vm.expectRevert(IRecipeExecutor.CapacityUnavailable.selector);
        executor.capacity();
        _assertUnchanged();
    }

    function test_CapacityRejectsReplacedRecipes() public {
        _configure(false, false);
        executor.setRecipe(new bytes[](0), new bytes[](0));
        vm.expectRevert(IRecipeExecutor.CapacityUnavailable.selector);
        executor.capacity();
        _assertUnchanged();
    }

    function test_CapacityRequiresConfiguration() public {
        vm.expectRevert(IRecipeExecutor.CapacityUnavailable.selector);
        executor.capacity();
    }

    function test_SetCapacityChecksOwnerCommitmentAssetAndPrefixBoundary() public {
        ExecutingRecipe.Recipe memory recipe = _configure(false, false);
        uint256[] memory inputs = _inputs(type(uint256).max);
        vm.prank(address(123));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(123)));
        executor.setCapacity(address(token), recipe.queries, recipe.steps, _prefixEnd, inputs, _runtime);
        vm.expectRevert(IRecipeExecutor.InvalidCapacity.selector);
        executor.setCapacity(address(0), recipe.queries, recipe.steps, _prefixEnd, inputs, _runtime);
        vm.expectRevert(IRecipeExecutor.InvalidCapacity.selector);
        executor.setCapacity(address(token), recipe.queries, recipe.steps, recipe.steps.length + 1, inputs, _runtime);
        recipe.steps[0] = hex"deadbeef";
        vm.expectRevert(IRecipeExecutor.InvalidRecipe.selector);
        executor.setCapacity(address(token), recipe.queries, recipe.steps, _prefixEnd, inputs, _runtime);
    }

    function test_SetCapacityRejectsCapsulesAboveTheCodeSizeLimit() public {
        bytes[] memory queries = new bytes[](1);
        queries[0] = new bytes(25_000);
        bytes[] memory steps = new bytes[](0);
        executor.setRecipe(queries, steps);
        vm.expectRevert(IRecipeExecutor.CapacityTooLarge.selector);
        executor.setCapacity(address(token), queries, steps, 0, new uint256[](0), new bytes[](0));
    }

    function test_CapacityRejectsMalformedRuntimeAndRollsBackEarlierWithdrawals() public {
        ExecutingRecipe.Recipe memory recipe = _configure(false, false);
        _runtime[1] = hex"deadbeef";
        executor.setCapacity(
            address(token), recipe.queries, recipe.steps, _prefixEnd, _inputs(type(uint256).max), _runtime
        );
        vm.expectRevert(IRecipeExecutor.CapacityUnavailable.selector);
        executor.capacity();
        _assertUnchanged();
    }

    function test_PreviewHelpersRejectExternalCallsAndSelfCallsOutsidePreview() public {
        _configure(false, false);
        bytes memory capsule = SSTORE2.read(executor.capacityPointer());
        vm.expectRevert(IRecipeExecutor.InvalidCaller.selector);
        executor.simulateCapacity(capsule);
        (bool success, bytes memory result) = address(executor).call(capsule);
        assertFalse(success);
        assertEq(result, abi.encodeWithSelector(IRecipeExecutor.InvalidCaller.selector));
        vm.prank(address(executor));
        (success, result) = address(executor).call(capsule);
        assertFalse(success);
        assertEq(result, abi.encodeWithSelector(IRecipeExecutor.InvalidCaller.selector));
        _assertUnchanged();
    }

    function test_CommittedSelfCallCannotPersistPreviewEffects() public {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(1);
        bytes[] memory empty = new bytes[](0);
        builder.call(
            address(executor),
            abi.encodeCall(executor.executeCapacity, (empty, empty, new uint256[](0), empty)),
            new uint256[](0)
        );
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        executor.setRecipe(recipe.queries, recipe.steps);
        executor.setCapacity(address(token), recipe.queries, recipe.steps, 0, new uint256[](0), empty);
        vm.expectRevert(IRecipeExecutor.InvalidCaller.selector);
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), empty);
        (, uint256 amount) = executor.capacity();
        assertEq(amount, 10);
        _assertUnchanged();
    }

    function test_CommittedSimulationSelfCallAlwaysRevertsItsEntireSubtree() public {
        bytes[] memory empty = new bytes[](0);
        bytes memory capsule = abi.encodeCall(executor.executeCapacity, (empty, empty, new uint256[](0), empty));
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(2);
        builder.call(address(effect), abi.encodeCall(effect.touch, ()), new uint256[](0));
        builder.call(address(executor), abi.encodeCall(executor.simulateCapacity, (capsule)), new uint256[](0));
        ExecutingRecipe.Recipe memory recipe = builder.finish();
        executor.setRecipe(recipe.queries, recipe.steps);
        executor.setCapacity(address(token), recipe.queries, recipe.steps, 0, new uint256[](0), empty);
        vm.expectRevert(abi.encode(uint256(10)));
        executor.execute(recipe.queries, recipe.steps, new uint256[](0), empty);
        (, uint256 amount) = executor.capacity();
        assertEq(amount, 10);
        _assertUnchanged();
    }

    function test_PreviewRejectsAChangedCapsuleEvenInsideItsRollbackContext() public {
        _configure(false, false);
        bytes[] memory empty = new bytes[](0);
        bytes memory capsule = abi.encodeCall(executor.executeCapacity, (empty, empty, new uint256[](0), empty));
        vm.prank(address(executor));
        vm.expectRevert(IRecipeExecutor.CapacityUnavailable.selector);
        executor.simulateCapacity(capsule);
        _assertUnchanged();
    }

    function test_CapacityRejectsSourceReentryAndRollsBackItsFunding() public {
        _configure(false, false);
        pool.setCallback(address(executor), abi.encodeCall(executor.capacity, ()));
        vm.expectRevert(IRecipeExecutor.CapacityUnavailable.selector);
        executor.capacity();
        _assertUnchanged();
    }

    function test_CapacityMatchesTheActualOrderedFundingBoundary() public {
        ExecutingRecipe.Recipe memory recipe = _configure(false, false);
        (, uint256 amount) = executor.capacity();
        assertEq(amount, 110);
        vm.expectRevert(IRecipes.CheckFailed.selector);
        executor.execute(recipe.queries, recipe.steps, _inputs(111), _runtime);
        _assertUnchanged();
        executor.execute(recipe.queries, recipe.steps, _inputs(110), _runtime);
        assertEq(token.balanceOf(account), 110);
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(pool.withdrawn(), 100);
        assertEq(effect.calls(), 1);
    }

    function _inputs(uint256 amount) internal pure returns (uint256[] memory inputs) {
        inputs = new uint256[](2);
        inputs[0] = 1;
        inputs[1] = amount;
    }

    function _configure(bool prepare, bool unbounded) internal returns (ExecutingRecipe.Recipe memory recipe) {
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](2);
        bytes32[] memory leaves = new bytes32[](2);
        for (uint256 i; i < 2; ++i) {
            actions[i] = IMerkleAccount.Action({
                target: address(pool),
                value: 0,
                data: abi.encodeCall(pool.withdraw, (i, account, 0)),
                dataMask: new bytes(100),
                proof: new bytes32[](1)
            });
            for (uint256 j = 68; j < 100; ++j) {
                actions[i].dataMask[j] = 0xff;
            }
            leaves[i] = ActionMasker.mask(actions[i].target, 0, actions[i].data, actions[i].dataMask);
            MerkleAccount(payable(account)).grantRole(leaves[i], address(executor));
        }
        bytes32 root = leaves[0] < leaves[1]
            ? keccak256(abi.encodePacked(leaves[0], leaves[1]))
            : keccak256(abi.encodePacked(leaves[1], leaves[0]));
        roots.setRoot(account, root);
        MerkleAccount(payable(account)).acceptRoot(root);
        actions[0].proof[0] = leaves[1];
        actions[1].proof[0] = leaves[0];

        ExecutingRecipe.Funding memory funding;
        funding.account = account;
        funding.asset = address(token);
        funding.sources = new ExecutingRecipe.Source[](2);
        bytes[] memory runtime = new bytes[](2);
        for (uint256 i; i < 2; ++i) {
            funding.sources[i].capacity =
                ExecutingRecipe.Read({target: address(pool), data: abi.encodeCall(pool.capacity, (i)), offset: 0});
            funding.sources[i].leaves = new bytes32[](1);
            funding.sources[i].leaves[0] = leaves[i];
            funding.sources[i].amountOffsets = new uint256[][](1);
            funding.sources[i].amountOffsets[0] = new uint256[](1);
            funding.sources[i].amountOffsets[0][0] = 68;
            IMerkleAccount.Action[] memory group = new IMerkleAccount.Action[](1);
            group[0] = actions[i];
            runtime[i] = abi.encode(group);
        }
        if (prepare) {
            funding.sources[0].prepare =
                ExecutingRecipe.Call({target: address(pool), data: abi.encodeCall(pool.prepare, ())});
        }
        if (unbounded) funding.sources[1].capacity = ExecutingRecipe.Read({target: address(0), data: "", offset: 0});
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(32);
        builder.fund(funding, builder.input(1));
        uint256 prefixEnd = builder.length;
        builder.check(OP_LESS_OR_EQUAL, builder.input(1), builder.balance(address(token), account));
        builder.call(address(effect), abi.encodeCall(effect.touch, ()), new uint256[](0));
        recipe = builder.finish();
        executor.setRecipe(recipe.queries, recipe.steps);
        _runtime = runtime;
        _prefixEnd = prefixEnd;
        executor.setCapacity(
            address(token), recipe.queries, recipe.steps, prefixEnd, _inputs(type(uint256).max), runtime
        );
    }

    function _assertUnchanged() internal view {
        assertEq(token.balanceOf(account), 10);
        assertEq(token.balanceOf(address(pool)), 100);
        assertEq(pool.withdrawn(), 0);
        assertEq(pool.prepared(), 0);
        assertEq(pool.limits(0), 80);
        assertEq(pool.limits(1), 80);
        assertEq(effect.calls(), 0);
    }
}

contract CapacityToken is ERC20 {
    constructor() ERC20("Capacity token", "CAP") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract CapacityLiquidityPool {
    address public immutable token;
    address public immutable account;
    uint256[2] public limits = [uint256(80), uint256(80)];
    uint256 public withdrawn;
    uint256 public prepared;
    bool public failure;
    address public callbackTarget;
    bytes public callbackData;

    constructor(address newToken, address newAccount) {
        token = newToken;
        account = newAccount;
    }

    function setLimits(uint256 first, uint256 second) public {
        limits[0] = first;
        limits[1] = second;
    }

    function setFailure(bool newFailure) public {
        failure = newFailure;
    }

    function setCallback(address newTarget, bytes calldata newData) public {
        callbackTarget = newTarget;
        callbackData = newData;
    }

    function prepare() public {
        limits[0] = 80;
        ++prepared;
    }

    function capacity(uint256 id) public view returns (uint256) {
        if (failure) {
            assembly ("memory-safe") {
                mstore(0, 1000000)
                revert(0, 32)
            }
        }
        return Math.min(limits[id], IERC20(token).balanceOf(address(this)));
    }

    function withdraw(uint256 id, address receiver, uint256 amount) public {
        require(msg.sender == account && receiver == account && amount <= capacity(id));
        limits[id] -= amount;
        withdrawn += amount;
        IERC20(token).transfer(receiver, amount);
        if (callbackTarget != address(0)) {
            (bool success, bytes memory result) = callbackTarget.call(callbackData);
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(result, 32), mload(result))
                }
            }
        }
    }
}

contract CapacityEffect {
    uint256 public calls;

    function touch() public {
        ++calls;
    }
}
