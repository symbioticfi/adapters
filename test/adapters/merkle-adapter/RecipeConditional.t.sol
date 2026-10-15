// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {ActionMasker} from "src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {
    IRecipes,
    OP_ADD,
    OP_APPROVE,
    OP_EQUAL,
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

    function test_ZeroAllowanceCleanupChecksRuntimeAndRole() public {
        (bytes32 leaf, bytes memory payload) = _publishApproval();
        bytes[] memory steps = new bytes[](1);
        steps[0] = _clearApproval(leaf);
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = payload;
        assertEq(_run(new bytes[](0), steps, new uint256[](0), runtime)[0], 0);
        runtime[0] = hex"ff";
        vm.expectRevert();
        RecipeExecutor(_executor).execute(new bytes[](0), steps, new uint256[](0), runtime);
        runtime[0] = payload;
        MerkleAccount(payable(account)).revokeRole(leaf, _executor);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _executor, leaf)
        );
        RecipeExecutor(_executor).execute(new bytes[](0), steps, new uint256[](0), runtime);
        assertEq(RecipeConditionalToken(_token).calls(), _initialCalls + 1);
    }

    function test_ApprovalCleanupAlwaysConsumesExactlyOneRuntimeEntry() public {
        (bytes32 leaf, bytes memory payload) = _publishApproval();
        bytes[] memory steps = new bytes[](1);
        steps[0] = _clearApproval(leaf);
        RecipeExecutor(_executor).setRecipe(new bytes[](0), steps);
        vm.expectRevert(stdError.indexOOBError);
        RecipeExecutor(_executor).execute(new bytes[](0), steps, new uint256[](0), new bytes[](0));
        bytes[] memory runtime = new bytes[](2);
        runtime[0] = payload;
        vm.expectRevert(IRecipes.InvalidRuntime.selector);
        RecipeExecutor(_executor).execute(new bytes[](0), steps, new uint256[](0), runtime);
    }

    function test_OrdinaryCleanupKeepsFollowingApprovalRuntimeAligned() public {
        (bytes32 leaf, bytes memory payload) = _publishApproval();
        bytes[] memory steps = new bytes[](3);
        steps[0] = _clearApproval(leaf);
        steps[1] = abi.encodePacked(OP_APPROVE, abi.encode(uint256(7), _token, _spender, leaf));
        steps[2] = _clearApproval(leaf);
        bytes[] memory runtime = new bytes[](3);
        runtime[0] = payload;
        runtime[1] = payload;
        runtime[2] = payload;
        _run(new bytes[](0), steps, new uint256[](0), runtime);
        assertEq(IERC20(_token).allowance(account, _spender), 0);
        assertEq(RecipeConditionalToken(_token).calls(), _initialCalls + 3);
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

    function test_ApprovalCleanupHandlesOptionalBoolAndRollsBackFailures() public {
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

    function test_ApprovalCleanupResultCannotBeReferenced() public {
        (bytes32 leaf, bytes memory payload) = _publishApproval();
        bytes[] memory steps = new bytes[](2);
        steps[0] = _clearApproval(leaf);
        steps[1] = abi.encodePacked(OP_ADD, abi.encode(_result(0), uint256(0)));
        RecipeExecutor(_executor).setRecipe(new bytes[](0), steps);
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = payload;
        vm.expectRevert(IRecipes.InvalidReference.selector);
        RecipeExecutor(_executor).execute(new bytes[](0), steps, new uint256[](0), runtime);
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
    function test_GasZeroApprovalCleanup() public {
        (bytes32 leaf, bytes memory payload) = _publishApproval();
        bytes[] memory steps = new bytes[](1);
        steps[0] = _clearApproval(leaf);
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = payload;
        _run(new bytes[](0), steps, new uint256[](0), runtime);
        vm.snapshotGasLastCall("RecipeConditional", "zeroApprovalCleanup");
        assertEq(RecipeConditionalToken(_token).calls(), _initialCalls + 1);
    }

    /// forge-config: default.isolate = true
    function test_GasApprovalCleanupActive() public {
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
        leaf = ActionMasker.mask(_token, 0, data, mask);
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
        return abi.encodePacked(OP_APPROVE, abi.encode(uint256(0), _token, _spender, leaf));
    }

    function _readIf(uint256 gate, uint256 queryIndex, uint256 fallbackValue) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(12), abi.encode(gate, queryIndex, fallbackValue));
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
