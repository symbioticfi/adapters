// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {
    IRecipes,
    OP_ADD,
    OP_APPROVE,
    OP_CLEAR_APPROVAL,
    OP_EQUAL,
    OP_READ_IF,
    SRC_INPUT,
    SRC_RESULT
} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {stdError} from "forge-std/StdError.sol";

contract RecipeConditionalTest is CapabilityTestBase {
    address internal _executor;
    address internal _token;
    address internal _spender = address(0xbeef);
    uint256 internal _initialCalls;

    function setUp() public {
        _token = address(new RecipeConditionalToken());
        _deployAdapter(_token);
        _executor = address(new RecipeExecutor(address(this), account));
        RecipeExecutor(_executor).setCaller(address(this));
        _initialCalls = RecipeConditionalToken(_token).calls();
    }

    function testFuzz_ReadIfPreservesFullWidthSelectedValuesAndResultBindings(
        bool active,
        uint256 value,
        uint256 fallbackValue
    ) public {
        bytes[] memory queries = new bytes[](2);
        queries[0] = _query(_input(1));
        queries[1] = _query(_result(0));
        bytes[] memory steps = new bytes[](3);
        steps[0] = _readIf(_input(0), 0, _input(2));
        steps[1] = _readIf(1, 1, uint256(3) << 216);
        steps[2] = abi.encodePacked(OP_ADD, abi.encode(_result(1), uint256(0)));
        uint256[] memory inputs = new uint256[](3);
        inputs[0] = active ? type(uint256).max : 0;
        inputs[1] = value;
        inputs[2] = fallbackValue;
        uint256[] memory values = _run(queries, steps, inputs, new bytes[](0));
        for (uint256 i; i < values.length; ++i) {
            assertEq(values[i], active ? value : fallbackValue);
        }
    }

    function test_ZeroGateSkipsMissingMalformedAndRevertingQueriesAndBindings() public {
        bytes[] memory steps = new bytes[](1);
        steps[0] = _readIf(0, type(uint256).max, 7);
        assertEq(_run(new bytes[](0), steps, new uint256[](0), new bytes[](0))[0], 7);
        bytes[] memory queries = new bytes[](1);
        steps[0] = _readIf(0, 0, 8);
        queries[0] = hex"ff";
        assertEq(_run(queries, steps, new uint256[](0), new bytes[](0))[0], 8);
        queries[0] = abi.encode(address(this), abi.encodeCall(this.rejectRead, ()), new uint256[](0), uint256(0));
        assertEq(_run(queries, steps, new uint256[](0), new bytes[](0))[0], 8);
        queries[0] = _query(_result(0));
        assertEq(_run(queries, steps, new uint256[](0), new bytes[](0))[0], 8);
    }

    function test_ReadIfResolvesGateBeforeEitherBranch() public {
        bytes[] memory steps = new bytes[](1);
        steps[0] = _readIf(uint256(3) << 216, type(uint256).max, _input(0));
        RecipeExecutor(_executor).setRecipe(new bytes[](0), steps);
        vm.expectRevert(IRecipes.InvalidReference.selector);
        RecipeExecutor(_executor).execute(new bytes[](0), steps, new uint256[](0), new bytes[](0));
        steps[0] = _readIf(_input(0), type(uint256).max, 0);
        RecipeExecutor(_executor).setRecipe(new bytes[](0), steps);
        vm.expectRevert(stdError.indexOOBError);
        RecipeExecutor(_executor).execute(new bytes[](0), steps, new uint256[](0), new bytes[](0));
    }

    function test_ReadIfResolvesFallbackOnlyWhenZero() public {
        bytes[] memory queries = new bytes[](1);
        queries[0] = _query(9);
        bytes[] memory steps = new bytes[](1);
        for (uint256 i; i < 3; ++i) {
            uint256 fallbackValue = i == 0 ? _input(0) : i == 1 ? _result(0) : uint256(3) << 216;
            steps[0] = _readIf(1, 0, fallbackValue);
            assertEq(_run(queries, steps, new uint256[](0), new bytes[](0))[0], 9);
            steps[0] = _readIf(0, 0, fallbackValue);
            RecipeExecutor(_executor).setRecipe(queries, steps);
            vm.expectRevert(
                i == 0 ? stdError.indexOOBError : abi.encodeWithSelector(IRecipes.InvalidReference.selector)
            );
            RecipeExecutor(_executor).execute(queries, steps, new uint256[](0), new bytes[](0));
        }
    }

    function test_ReadIfRejectsSelfFutureAndNonnumericalResults() public {
        bytes[] memory steps = new bytes[](2);
        steps[0] = abi.encodePacked(OP_EQUAL, abi.encode(uint256(0), uint256(0)));
        for (uint256 branch; branch < 2; ++branch) {
            for (uint256 index; index < 3; ++index) {
                steps[1] = branch == 0 ? _readIf(_result(index), 0, 0) : _readIf(0, 0, _result(index));
                RecipeExecutor(_executor).setRecipe(new bytes[](0), steps);
                vm.expectRevert(IRecipes.InvalidReference.selector);
                RecipeExecutor(_executor).execute(new bytes[](0), steps, new uint256[](0), new bytes[](0));
            }
        }
    }

    function test_ActiveReadStillValidatesBindingsAndReturnedWord() public {
        bytes[] memory queries = new bytes[](1);
        queries[0] = _query(_result(0));
        bytes[] memory steps = new bytes[](1);
        steps[0] = _readIf(1, 0, 0);
        RecipeExecutor(_executor).setRecipe(queries, steps);
        vm.expectRevert(IRecipes.InvalidReference.selector);
        RecipeExecutor(_executor).execute(queries, steps, new uint256[](0), new bytes[](0));
        queries[0] = abi.encode(address(this), abi.encodeCall(this.echo, (uint256(1))), new uint256[](0), uint256(1));
        RecipeExecutor(_executor).setRecipe(queries, steps);
        vm.expectRevert(IRecipes.InvalidQuery.selector);
        RecipeExecutor(_executor).execute(queries, steps, new uint256[](0), new bytes[](0));
    }

    function test_CapabilityAcceptsReadIfAndRejectsConditionalApproval() public {
        _installCapability(adapter, address(new RecipeCapability()), _recipeSelectors());
        bytes[] memory steps = new bytes[](2);
        steps[0] = _readIf(0, type(uint256).max, _input(0));
        steps[1] = abi.encodePacked(OP_ADD, abi.encode(_result(0), uint256(0)));
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = type(uint256).max;
        uint256[] memory values = abi.decode(
            _manage(account, abi.encodeCall(IRecipeCapability.execute, (new bytes[](0), steps, inputs))), (uint256[])
        );
        assertEq(values[1], type(uint256).max);
        steps = new bytes[](1);
        steps[0] = abi.encodePacked(OP_CLEAR_APPROVAL, "");
        IMerkleAccount.Action[] memory actions =
            _publishCall(account, abi.encodeCall(IRecipeCapability.execute, (new bytes[](0), steps, new uint256[](0))));
        vm.expectRevert(IRecipes.InvalidOperation.selector);
        MerkleAccount(payable(account)).manage(actions);
    }

    function test_ZeroAllowanceSkipsInvalidRuntimeAndRevokedRole() public {
        (bytes32 leaf, bytes memory payload) = _publishApproval();
        MerkleAccount(payable(account)).revokeRole(leaf, _executor);
        bytes[] memory steps = new bytes[](1);
        steps[0] = _clearApproval(leaf);
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = payload;
        assertEq(_run(new bytes[](0), steps, new uint256[](0), runtime)[0], 0);
        runtime[0] = hex"ff";
        _run(new bytes[](0), steps, new uint256[](0), runtime);
        steps[0] = _clearApproval(bytes32(uint256(1)));
        _run(new bytes[](0), steps, new uint256[](0), runtime);
        assertEq(RecipeConditionalToken(_token).calls(), _initialCalls);
    }

    function test_ClearApprovalAlwaysConsumesExactlyOneRuntimeEntry() public {
        bytes[] memory steps = new bytes[](1);
        steps[0] = _clearApproval(bytes32(0));
        RecipeExecutor(_executor).setRecipe(new bytes[](0), steps);
        vm.expectRevert(stdError.indexOOBError);
        RecipeExecutor(_executor).execute(new bytes[](0), steps, new uint256[](0), new bytes[](0));
        vm.expectRevert(IRecipes.InvalidRuntime.selector);
        RecipeExecutor(_executor).execute(new bytes[](0), steps, new uint256[](0), new bytes[](2));
    }

    function test_SkippedCleanupKeepsFollowingApprovalRuntimeAligned() public {
        (bytes32 leaf, bytes memory payload) = _publishApproval();
        bytes[] memory steps = new bytes[](3);
        steps[0] = _clearApproval(bytes32(0));
        steps[1] = abi.encodePacked(OP_APPROVE, abi.encode(uint256(7), _token, _spender, leaf));
        steps[2] = _clearApproval(leaf);
        bytes[] memory runtime = new bytes[](3);
        runtime[0] = hex"ff";
        runtime[1] = payload;
        runtime[2] = payload;
        _run(new bytes[](0), steps, new uint256[](0), runtime);
        assertEq(IERC20(_token).allowance(account, _spender), 0);
        assertEq(RecipeConditionalToken(_token).calls(), _initialCalls + 2);
    }

    function testFuzz_DirtyAllowanceIsClearedThroughAccount(uint256 allowance) public {
        allowance = bound(allowance, 1, type(uint256).max);
        (bytes32 leaf, bytes memory payload) = _publishApproval();
        RecipeConditionalToken(_token).setAllowance(account, _spender, allowance);
        bytes[] memory steps = new bytes[](1);
        steps[0] = _clearApproval(leaf);
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = payload;
        _run(new bytes[](0), steps, new uint256[](0), runtime);
        assertEq(IERC20(_token).allowance(account, _spender), 0);
        assertEq(RecipeConditionalToken(_token).calls(), _initialCalls + 1);
        assertEq(RecipeConditionalToken(_token).lastApprover(), account);
    }

    function test_DirtyAllowanceRequiresConfiguredLeafAndCurrentProofAndRole() public {
        (bytes32 leaf, bytes memory payload) = _publishApproval();
        RecipeConditionalToken(_token).setAllowance(account, _spender, 7);
        bytes[] memory steps = new bytes[](1);
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = payload;
        steps[0] = _clearApproval(bytes32(uint256(1)));
        RecipeExecutor(_executor).setRecipe(new bytes[](0), steps);
        vm.expectRevert(IRecipeExecutor.InvalidAction.selector);
        RecipeExecutor(_executor).execute(new bytes[](0), steps, new uint256[](0), runtime);
        steps[0] = _clearApproval(leaf);
        RecipeExecutor(_executor).setRecipe(new bytes[](0), steps);
        (bytes memory mask,) = abi.decode(payload, (bytes, bytes32[]));
        runtime[0] = abi.encode(mask, new bytes32[](1));
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        RecipeExecutor(_executor).execute(new bytes[](0), steps, new uint256[](0), runtime);
        runtime[0] = payload;
        MerkleAccount(payable(account)).revokeRole(leaf, _executor);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _executor, leaf)
        );
        RecipeExecutor(_executor).execute(new bytes[](0), steps, new uint256[](0), runtime);
        assertEq(IERC20(_token).allowance(account, _spender), 7);
        assertEq(RecipeConditionalToken(_token).calls(), _initialCalls);
    }

    function test_ClearApprovalHandlesOptionalBoolAndRollsBackFailures() public {
        (bytes32 leaf, bytes memory payload) = _publishApproval();
        bytes[] memory steps = new bytes[](1);
        steps[0] = _clearApproval(leaf);
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = payload;
        RecipeExecutor(_executor).setRecipe(new bytes[](0), steps);
        for (uint8 mode; mode < 5; ++mode) {
            RecipeConditionalToken(_token).setAllowance(account, _spender, 7);
            RecipeConditionalToken(_token).setMode(mode);
            uint256 beforeCalls = RecipeConditionalToken(_token).calls();
            if (mode == 2) vm.expectRevert(IRecipeExecutor.ApprovalFailed.selector);
            if (mode == 3) vm.expectRevert();
            RecipeExecutor(_executor).execute(new bytes[](0), steps, new uint256[](0), runtime);
            bool failed = mode == 2 || mode == 3;
            assertEq(IERC20(_token).allowance(account, _spender), failed ? 7 : 0);
            assertEq(RecipeConditionalToken(_token).calls(), beforeCalls + (failed ? 0 : 1));
        }
    }

    function test_ClearApprovalResultCannotBeReferenced() public {
        bytes[] memory steps = new bytes[](2);
        steps[0] = _clearApproval(bytes32(0));
        steps[1] = abi.encodePacked(OP_ADD, abi.encode(_result(0), uint256(0)));
        RecipeExecutor(_executor).setRecipe(new bytes[](0), steps);
        vm.expectRevert(IRecipes.InvalidReference.selector);
        RecipeExecutor(_executor).execute(new bytes[](0), steps, new uint256[](0), new bytes[](1));
    }

    function test_OrdinaryZeroApprovalStillCallsTokenAndChecksRole() public {
        (bytes32 leaf, bytes memory payload) = _publishApproval();
        bytes[] memory steps = new bytes[](1);
        steps[0] = abi.encodePacked(OP_APPROVE, abi.encode(uint256(0), _token, _spender, leaf));
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = payload;
        _run(new bytes[](0), steps, new uint256[](0), runtime);
        assertEq(RecipeConditionalToken(_token).calls(), _initialCalls + 1);
        MerkleAccount(payable(account)).revokeRole(leaf, _executor);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _executor, leaf)
        );
        RecipeExecutor(_executor).execute(new bytes[](0), steps, new uint256[](0), runtime);
        assertEq(RecipeConditionalToken(_token).calls(), _initialCalls + 1);
    }

    /// forge-config: default.isolate = true
    function test_GasReadIfSkipped() public {
        bytes[] memory steps = new bytes[](1);
        steps[0] = _readIf(0, type(uint256).max, 7);
        uint256[] memory values = _run(new bytes[](0), steps, new uint256[](0), new bytes[](0));
        vm.snapshotGasLastCall("RecipeConditional", "readIfSkipped");
        assertEq(values[0], 7);
    }

    /// forge-config: default.isolate = true
    function test_GasReadIfActive() public {
        bytes[] memory queries = new bytes[](1);
        queries[0] = _query(7);
        bytes[] memory steps = new bytes[](1);
        steps[0] = _readIf(1, 0, 0);
        uint256[] memory values = _run(queries, steps, new uint256[](0), new bytes[](0));
        vm.snapshotGasLastCall("RecipeConditional", "readIfActive");
        assertEq(values[0], 7);
    }

    /// forge-config: default.isolate = true
    function test_GasClearApprovalSkipped() public {
        bytes[] memory steps = new bytes[](1);
        steps[0] = _clearApproval(bytes32(0));
        _run(new bytes[](0), steps, new uint256[](0), new bytes[](1));
        vm.snapshotGasLastCall("RecipeConditional", "clearApprovalSkipped");
        assertEq(RecipeConditionalToken(_token).calls(), _initialCalls);
    }

    /// forge-config: default.isolate = true
    function test_GasClearApprovalActive() public {
        (bytes32 leaf, bytes memory payload) = _publishApproval();
        RecipeConditionalToken(_token).setAllowance(account, _spender, 7);
        bytes[] memory steps = new bytes[](1);
        steps[0] = _clearApproval(leaf);
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = payload;
        _run(new bytes[](0), steps, new uint256[](0), runtime);
        vm.snapshotGasLastCall("RecipeConditional", "clearApprovalActive");
        assertEq(IERC20(_token).allowance(account, _spender), 0);
    }

    function echo(uint256 value) public pure returns (uint256) {
        return value;
    }

    function rejectRead() public pure {
        revert IRecipes.InvalidQuery();
    }

    function _publishApproval() internal returns (bytes32 leaf, bytes memory payload) {
        bytes memory data = abi.encodeCall(IERC20.approve, (_spender, uint256(0)));
        bytes memory mask = new bytes(data.length);
        for (uint256 i = 36; i < 68; ++i) {
            mask[i] = 0xff;
        }
        leaf = MerkleAdapterVerifier.leaf(_token, 0, data, mask);
        roots.setRoot(account, leaf);
        MerkleAccount(payable(account)).acceptRoot(leaf);
        MerkleAccount(payable(account)).grantRole(leaf, _executor);
        payload = abi.encode(mask, new bytes32[](0));
    }

    function _run(bytes[] memory queries, bytes[] memory steps, uint256[] memory inputs, bytes[] memory runtime)
        internal
        returns (uint256[] memory)
    {
        RecipeExecutor(_executor).setRecipe(queries, steps);
        return RecipeExecutor(_executor).execute(queries, steps, inputs, runtime);
    }

    function _query(uint256 operand) internal view returns (bytes memory) {
        uint256[] memory bindings = new uint256[](1);
        bindings[0] = (uint256(4) << 224) | operand;
        return abi.encode(address(this), abi.encodeCall(this.echo, (uint256(0))), bindings, uint256(0));
    }

    function _clearApproval(bytes32 leaf) internal view returns (bytes memory) {
        return abi.encodePacked(OP_CLEAR_APPROVAL, abi.encode(_token, _spender, leaf));
    }

    function _readIf(uint256 gate, uint256 queryIndex, uint256 fallbackValue) internal pure returns (bytes memory) {
        return abi.encodePacked(OP_READ_IF, abi.encode(gate, queryIndex, fallbackValue));
    }

    function _input(uint256 index) internal pure returns (uint256) {
        return (uint256(SRC_INPUT) << 216) | index;
    }

    function _result(uint256 index) internal pure returns (uint256) {
        return (uint256(SRC_RESULT) << 216) | index;
    }
}

contract RecipeConditionalToken is ERC20 {
    uint256 public calls;
    uint8 public mode;
    address public lastApprover;

    constructor() ERC20("Conditional token", "COND") {}

    function setMode(uint8 newMode) public {
        mode = newMode;
    }

    function setAllowance(address owner, address spender, uint256 amount) public {
        _approve(owner, spender, amount);
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        ++calls;
        lastApprover = msg.sender;
        super.approve(spender, amount);
        if (mode == 1) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (mode == 3) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (mode == 4) {
            assembly ("memory-safe") {
                mstore(0, 1)
                mstore(32, 123)
                return(0, 64)
            }
        }
        return mode != 2;
    }
}
