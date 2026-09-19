// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MerkleAdapterVerifier} from "../libraries/MerkleAdapterVerifier.sol";

import {IMerkleAdapter} from "../../../interfaces/IMerkleAdapter.sol";
import {IRecipeExecutor} from "../../../interfaces/merkle-adapter/automations/IRecipeExecutor.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title RecipeExecutor
/// @notice Contract for curator-configured automation using adapter calls and measured postconditions.
contract RecipeExecutor is Ownable, ReentrancyGuardTransient, IRecipeExecutor {
    using Address for address;
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc IRecipeExecutor
    address public immutable adapter;

    /* STATE VARIABLES */

    /// @inheritdoc IRecipeExecutor
    address public caller;

    /// @inheritdoc IRecipeExecutor
    Step[] public steps;

    /* CONSTRUCTOR */

    constructor(address newOwner, address newAdapter) Ownable(newOwner) {
        adapter = newAdapter;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IRecipeExecutor
    function setCaller(address newCaller) public nonReentrant onlyOwner {
        caller = newCaller;
        emit SetCaller(newCaller);
    }

    /// @inheritdoc IRecipeExecutor
    function setRecipe(Step[] calldata newRecipe) public nonReentrant onlyOwner {
        delete steps;
        for (uint256 i; i < newRecipe.length; ++i) {
            steps.push(newRecipe[i]);
        }
        emit SetRecipe(newRecipe);
    }

    /// @inheritdoc IRecipeExecutor
    function execute(uint256[] calldata inputs, bytes[] calldata runtime)
        public
        nonReentrant
        returns (uint256[] memory values)
    {
        if (caller != msg.sender) revert InvalidCaller();
        uint256 length = steps.length;
        if (runtime.length != length) revert InvalidRuntime();

        values = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            Step storage step = steps[i];
            Operation operation = step.operation;
            if (operation == Operation.Constant) {
                values[i] = step.a;
            } else if (operation == Operation.Input) {
                values[i] = inputs[step.a];
            } else if (operation == Operation.Calldata) {
                values[i] = abi.decode(runtime[step.a][step.b:], (uint256));
            } else if (operation == Operation.Read) {
                (address target, bytes memory query) = abi.decode(step.data, (address, bytes));
                if (step.c > 0) {
                    if (step.b >= i) revert InvalidReference();
                    if (step.c < 4 || step.c + 32 > query.length) revert InvalidCall();
                    Bytes.replace(query, step.c, abi.encode(values[step.b]));
                }
                values[i] = abi.decode(Bytes.splice(target.functionStaticCall(query), step.a, step.a + 32), (uint256));
            } else if (operation == Operation.Invoke) {
                (address target, bytes4 selector) = abi.decode(step.data, (address, bytes4));
                bytes calldata data = runtime[i];
                if (data.length < 4 || bytes4(data) != selector) revert InvalidCall();
                target.functionCall(data);
            } else {
                if (step.a >= i) revert InvalidReference();
                uint256 a = values[step.a];
                if (operation == Operation.Manage) {
                    if (a > 0) {
                        IMerkleAdapter.Action[] memory actions = abi.decode(runtime[i], (IMerkleAdapter.Action[]));
                        if (!Bytes.equal(runtime[i], abi.encode(actions))) revert InvalidRuntime();
                        bytes32[] memory leaves = abi.decode(step.data, (bytes32[]));
                        if (actions.length != leaves.length) revert InvalidRuntime();
                        for (uint256 j; j < actions.length; ++j) {
                            _checkAction(actions[j], leaves[j]);
                        }
                        IMerkleAdapter(adapter).manage(actions);
                    }
                } else if (operation == Operation.Approve) {
                    (address token, address spender, bytes32 leaf) = abi.decode(step.data, (address, address, bytes32));
                    IRecipeExecutor.Permission memory permission = abi.decode(runtime[i], (IRecipeExecutor.Permission));
                    bool reset = a > 0 && IERC20(token).allowance(adapter, spender) > 0;
                    IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](reset ? 2 : 1);
                    for (uint256 j; j < actions.length; ++j) {
                        actions[j] = IMerkleAdapter.Action(
                            token,
                            0,
                            abi.encodeCall(IERC20.approve, (spender, reset && j == 0 ? 0 : a)),
                            permission.dataMask,
                            permission.proof
                        );
                        _checkAction(actions[j], leaf);
                    }
                    bytes[] memory results = IMerkleAdapter(adapter).manage(actions);
                    for (uint256 j; j < results.length; ++j) {
                        if (results[j].length > 0 && !abi.decode(results[j], (bool))) revert ApprovalFailed();
                    }
                } else {
                    if (step.b >= i || (operation == Operation.MulDiv && step.c >= i)) revert InvalidReference();
                    uint256 b = values[step.b];
                    if (operation == Operation.Equal && a != b) revert CheckFailed();
                    if (operation == Operation.LessOrEqual && a > b) revert CheckFailed();
                    if (operation == Operation.Add) values[i] = a + b;
                    else if (operation == Operation.Subtract) values[i] = a - b;
                    else if (operation == Operation.Minimum) values[i] = a.min(b);
                    else if (operation == Operation.MulDiv) values[i] = a.mulDiv(b, values[step.c]);
                }
            }
        }
        emit Execute();
    }

    /* INTERNAL FUNCTIONS */

    function _checkAction(IMerkleAdapter.Action memory action, bytes32 leaf) internal pure {
        if (
            action.value > 0
                || MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask) != leaf
        ) revert InvalidAction();
    }
}
