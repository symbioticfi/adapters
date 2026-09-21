// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MerkleAdapterVerifier} from "../libraries/MerkleAdapterVerifier.sol";

import {IMerkleAccount} from "../../../interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeExecutor} from "../../../interfaces/merkle-adapter/automations/IRecipeExecutor.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title RecipeExecutor
/// @notice Contract for curator-committed approved actions with dependent amounts and conditions.
contract RecipeExecutor is Ownable, ReentrancyGuardTransient, IRecipeExecutor {
    using Address for address;
    using Bytes for bytes;
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc IRecipeExecutor
    address public immutable account;

    /* STATE VARIABLES */

    /// @inheritdoc IRecipeExecutor
    address public caller;

    /// @inheritdoc IRecipeExecutor
    bytes32 public recipeHash;

    /// @inheritdoc IRecipeExecutor
    uint256 public recipeBlock;

    /* CONSTRUCTOR */

    constructor(address newOwner, address newAccount) Ownable(newOwner) {
        account = newAccount;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IRecipeExecutor
    function setCaller(address newCaller) public nonReentrant onlyOwner {
        caller = newCaller;
        emit SetCaller(newCaller);
    }

    /// @inheritdoc IRecipeExecutor
    function setRecipe(bytes[] calldata queries, Step[] calldata steps) public nonReentrant onlyOwner {
        recipeHash = keccak256(abi.encode(queries, steps));
        recipeBlock = block.number;
        emit SetRecipe(recipeHash, queries, steps);
    }

    /// @inheritdoc IRecipeExecutor
    function execute(
        bytes[] calldata queries,
        Step[] calldata steps,
        uint256[] calldata inputs,
        bytes[] calldata runtime
    ) public nonReentrant returns (uint256[] memory) {
        if (caller != msg.sender) revert InvalidCaller();
        if (recipeHash != keccak256(abi.encode(queries, steps))) revert InvalidRecipe();
        uint256 length = steps.length;
        Execution memory state = Execution({inputs: inputs, values: new uint256[](length), index: 0, runtimeIndex: 0});
        for (; state.index < length; ++state.index) {
            Step calldata step = steps[state.index];
            bytes calldata payload = step.data;
            if (step.operation == Operation.Read) {
                payload = queries[abi.decode(payload, (uint256))];
            } else if (step.operation == Operation.Manage || step.operation == Operation.Approve) {
                payload = runtime[state.runtimeIndex++];
            }
            state.values[state.index] = _run(steps, payload, state);
        }
        if (state.runtimeIndex != runtime.length) revert InvalidRuntime();
        emit Execute();
        return state.values;
    }

    /* INTERNAL FUNCTIONS */

    // A separate instruction frame keeps the nested ABI decoders within the non-IR stack limit.
    function _run(Step[] calldata steps, bytes calldata payload, Execution memory state) internal returns (uint256) {
        Step calldata step = steps[state.index];
        if (step.operation == Operation.Read) {
            (address target, bytes memory data, Binding[] memory bindings, uint256 offset) =
                abi.decode(payload, (address, bytes, Binding[], uint256));
            _bind(data, bindings, steps, state);
            return abi.decode(target.functionStaticCall(data).splice(offset, offset + 32), (uint256));
        } else if (step.operation == Operation.Manage || step.operation == Operation.Approve) {
            IMerkleAccount.Action[] memory actions;
            if (step.operation == Operation.Manage) {
                (Value memory gate, bytes32[] memory leaves, Binding[][] memory bindings) =
                    abi.decode(step.data, (Value, bytes32[], Binding[][]));
                if (_value(gate, steps, state) == 0) return 0;
                actions = abi.decode(payload, (IMerkleAccount.Action[]));
                uint256 length = actions.length;
                if (length != leaves.length || length != bindings.length) revert InvalidRuntime();
                for (uint256 i; i < length; ++i) {
                    _bind(actions[i].data, bindings[i], steps, state);
                    _checkAction(actions[i], leaves[i]);
                }
            } else {
                (Value memory amount, address token, address spender, bytes32 leaf) =
                    abi.decode(step.data, (Value, address, address, bytes32));
                uint256 value = _value(amount, steps, state);
                (bytes memory dataMask, bytes32[] memory proof) = abi.decode(payload, (bytes, bytes32[]));
                bool noReset = value == 0 || IERC20(token).allowance(account, spender) == 0;
                uint256 length = noReset ? 1 : 2;
                actions = new IMerkleAccount.Action[](length);
                for (uint256 i; i < length; ++i) {
                    actions[i] = IMerkleAccount.Action({
                        target: token,
                        value: 0,
                        data: abi.encodeCall(IERC20.approve, (spender, noReset || i > 0 ? value : 0)),
                        dataMask: dataMask,
                        proof: proof
                    });
                    _checkAction(actions[i], leaf);
                }
            }
            bytes[] memory responses = IMerkleAccount(account).manage(actions);
            if (step.operation == Operation.Approve) {
                uint256 length = responses.length;
                for (uint256 i; i < length; ++i) {
                    if (responses[i].length > 0 && !abi.decode(responses[i], (bool))) revert ApprovalFailed();
                }
            }
        } else if (step.operation == Operation.Call) {
            (address target, bytes memory data, Binding[] memory bindings) =
                abi.decode(step.data, (address, bytes, Binding[]));
            _bind(data, bindings, steps, state);
            target.functionCall(data);
        } else {
            (Value memory first, Value memory second) = abi.decode(step.data, (Value, Value));
            uint256 a = _value(first, steps, state);
            uint256 b = _value(second, steps, state);
            if (step.operation == Operation.Add) return a + b;
            if (step.operation == Operation.Sub) return a - b;
            if (step.operation == Operation.SaturatingSub) return a.saturatingSub(b);
            if (step.operation == Operation.Min) return Math.min(a, b);
            if (step.operation == Operation.Max) return Math.max(a, b);
            if (step.operation == Operation.MulDiv) {
                (,, Value memory denominator) = abi.decode(step.data, (Value, Value, Value));
                return a.mulDiv(b, _value(denominator, steps, state));
            }
            if (step.operation == Operation.Equal ? a != b : a > b) revert CheckFailed();
        }
        return 0;
    }

    function _value(Value memory value, Step[] calldata steps, Execution memory state) internal pure returns (uint256) {
        if (value.source == Source.Literal) return value.value;
        if (value.source == Source.Input) return state.inputs[value.value];
        if (value.value >= state.index) revert InvalidReference();
        if (steps[value.value].operation > Operation.MulDiv) revert InvalidReference();
        return state.values[value.value];
    }

    function _bind(bytes memory data, Binding[] memory bindings, Step[] calldata steps, Execution memory state)
        internal
        pure
    {
        uint256 end = 4;
        uint256 length = bindings.length;
        uint256 dataLength = data.length;
        for (uint256 i; i < length; ++i) {
            uint256 offset = bindings[i].offset;
            if (offset < end) revert InvalidCall();
            end = offset + 32;
            if (end > dataLength) revert InvalidCall();
            data.replace(offset, abi.encode(_value(bindings[i].value, steps, state)));
        }
    }

    function _checkAction(IMerkleAccount.Action memory action, bytes32 leaf) internal pure {
        if (
            action.value > 0
                || MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask) != leaf
        ) revert InvalidAction();
    }
}
