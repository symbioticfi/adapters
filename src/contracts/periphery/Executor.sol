// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {MerkleAdapterVerifier} from "../merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IExecutor} from "../../interfaces/periphery/IExecutor.sol";
import {IMerkleAdapter} from "../../interfaces/IMerkleAdapter.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title Executor
/// @notice Base contract for ordered adapter liquidity preparation and Merkle-authorized approvals.
abstract contract Executor is Ownable, ReentrancyGuardTransient, IExecutor {
    using Address for address;
    using Math for uint256;
    using MerkleAdapterVerifier for address;

    /* IMMUTABLES */

    /// @inheritdoc IExecutor
    address public immutable adapter;

    /* STATE VARIABLES */

    /// @inheritdoc IExecutor
    address public caller;

    /// @inheritdoc IExecutor
    Action[] public actions;

    /// @inheritdoc IExecutor
    bytes32 public approvalLeaf;

    /// @inheritdoc IExecutor
    bytes32 public operationLeaf;

    /* MODIFIERS */

    modifier onlyCaller() {
        if (caller != msg.sender) revert InvalidCaller();

        _;
    }

    /* CONSTRUCTOR */

    constructor(address newOwner, address newAdapter) Ownable(newOwner) {
        adapter = newAdapter;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IExecutor
    function setCaller(address newCaller) public nonReentrant onlyOwner {
        caller = newCaller;
        emit SetCaller(newCaller);
    }

    /// @inheritdoc IExecutor
    function setActions(Action[] calldata newActions, bytes32 newApprovalLeaf, bytes32 newOperationLeaf)
        public
        nonReentrant
        onlyOwner
    {
        delete actions;
        for (uint256 i; i < newActions.length; ++i) {
            actions.push(newActions[i]);
        }
        approvalLeaf = newApprovalLeaf;
        operationLeaf = newOperationLeaf;
        emit SetActions(newActions, newApprovalLeaf, newOperationLeaf);
    }

    /// @inheritdoc IExecutor
    function actionsLength() public view returns (uint256) {
        return actions.length;
    }

    /// @inheritdoc IExecutor
    function availableBalance(address asset) public view returns (uint256) {
        return IERC20(asset).balanceOf(adapter).saturatingSub(_reservedBalance(asset));
    }

    /* INTERNAL FUNCTIONS */

    function _prepareLiquidity(address asset, uint256 amount, address target, Execution calldata execution) internal {
        uint256 length = actions.length;
        if (execution.actions.length != length) revert InvalidActionsLength();

        for (uint256 i; i < length; ++i) {
            _checkAction(execution.actions[i], actions[i].leaf);
        }
        for (uint256 i; i < length; ++i) {
            uint256 requested = (amount + _reservedBalance(asset)).saturatingSub(IERC20(asset).balanceOf(adapter));
            if (requested == 0) break;

            bytes memory result = actions[i].liquidityTarget.functionStaticCall(actions[i].liquidityCalldata);
            if (result.length != 32) revert InvalidLiquidityResult();

            requested = Math.min(requested, abi.decode(result, (uint256)));
            if (requested > 0) {
                IMerkleAdapter.Action[] memory withdrawal = new IMerkleAdapter.Action[](1);
                withdrawal[0] = execution.actions[i];
                uint256 balance = IERC20(asset).balanceOf(adapter);
                IMerkleAdapter(adapter).manage(withdrawal);
                if (IERC20(asset).balanceOf(adapter) != balance + requested) revert LiquidityMismatch();

                emit PrepareLiquidity(adapter, asset, i, requested);
            }
        }
        if (availableBalance(asset) < amount) revert InsufficientLiquidity();

        // Both approvals execute from the adapter, including the reset required by tokens such as USDT.
        if (IERC20(asset).allowance(adapter, target) > 0) _approve(asset, target, 0, execution.approval);
        _approve(asset, target, amount, execution.approval);
    }

    function _approve(address asset, address target, uint256 amount, Permission calldata permission) internal {
        bytes memory result = _call(asset, abi.encodeCall(IERC20.approve, (target, amount)), permission, approvalLeaf);
        if (result.length > 0 && !abi.decode(result, (bool))) revert ApprovalFailed();
    }

    function _call(address target, bytes memory data, Permission calldata permission, bytes32 expectedLeaf)
        internal
        returns (bytes memory)
    {
        IMerkleAdapter.Action[] memory calls = new IMerkleAdapter.Action[](1);
        calls[0] = IMerkleAdapter.Action(target, 0, data, permission.dataMask, permission.proof);
        _checkAction(calls[0], expectedLeaf);
        return IMerkleAdapter(adapter).manage(calls)[0];
    }

    function _checkAction(IMerkleAdapter.Action memory action, bytes32 expectedLeaf) internal pure {
        if (action.target.leaf(action.value, action.data, action.dataMask) != expectedLeaf) revert InvalidAction();
    }

    function _reservedBalance(address asset) internal view returns (uint256) {
        if (asset != IERC4626(IMerkleAdapter(adapter).vault()).asset()) return 0;
        return IMerkleAdapter(adapter).reservedAssets();
    }
}
