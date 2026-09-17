// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {MerkleAdapterVerifier} from "../merkle_adapter/libraries/MerkleAdapterVerifier.sol";

import {ANY_VALUE, ANY_VALUE_FLAG, IMerkleAdapter} from "../../interfaces/IMerkleAdapter.sol";
import {IExecutor} from "../../interfaces/periphery/IExecutor.sol";
import {ILiquidLaneConnector} from "../../interfaces/merkle_adapter/ILiquidLaneConnector.sol";
import {IMerkleAdapterOracle} from "../../interfaces/merkle_adapter/IMerkleAdapterOracle.sol";
import {IThreeFCapability} from "../../interfaces/merkle_adapter/IThreeFCapability.sol";
import {IThreeFPushRequest} from "../../interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFRequest} from "../../interfaces/3f-adapter/IThreeFRequest.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title Executor
/// @notice Contract for funding one Merkle adapter through owner-configured liquidity queries and leaves.
contract Executor is Ownable, ReentrancyGuardTransient, IExecutor {
    using Address for address;
    using Math for uint256;

    /* IMMUTABLES */

    /// @inheritdoc IExecutor
    address public immutable adapter;

    /* STATE VARIABLES */

    /// @inheritdoc IExecutor
    address public caller;

    /// @dev Ordered Merkle leaves with liquidity queries for the funding entries.
    Action[] internal _actions;

    /* MODIFIERS */

    /// @dev An owner must explicitly select the caller; the zero address disables execution.
    modifier onlyCaller() {
        if (caller != msg.sender) revert InvalidCaller();

        _;
    }

    /* CONSTRUCTOR */

    /// @dev Sets the permanent adapter and the owner responsible for configuring its liquidity actions and caller.
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
    function setActions(Action[] calldata actions) public nonReentrant onlyOwner {
        delete _actions;
        for (uint256 i; i < actions.length; ++i) {
            _actions.push(actions[i]);
        }
        emit SetActions(actions);
    }

    /// @inheritdoc IExecutor
    function getActions() public view returns (Action[] memory actions) {
        return _actions;
    }

    /// @inheritdoc IExecutor
    function execute(IMerkleAdapter.Action[] calldata actions)
        public
        nonReentrant
        onlyCaller
        returns (bytes[] memory results)
    {
        if (actions.length == 0) revert InvalidOperation();
        if (actions.length != _actions.length) revert InvalidActionsLength();
        uint256 liquidityLength;
        for (uint256 i; i < actions.length; ++i) {
            IMerkleAdapter.Action calldata action = actions[i];
            if (
                MerkleAdapterVerifier.leaf(
                        action.target,
                        action.flagsAndValue & ANY_VALUE_FLAG == 0 ? action.flagsAndValue & ANY_VALUE : ANY_VALUE,
                        action.data,
                        action.dataMask
                    ) != _actions[i].leaf
            ) revert InvalidAction();
            if (_actions[i].liquidityTarget != address(0)) {
                if (liquidityLength != i) revert InvalidActionOrder();
                ++liquidityLength;
            }
        }
        if (liquidityLength == actions.length) revert InvalidOperation();

        (address asset, uint256 amount) = getRequiredLiquidity(actions[actions.length - 1]);
        {
            uint256 i;
            for (; i < liquidityLength; ++i) {
                uint256 requested;
                {
                    uint256 shortfall =
                        (amount + _reservedBalance(asset)).saturatingSub(IERC20(asset).balanceOf(adapter));
                    if (shortfall == 0) break;
                    bytes memory result = _actions[i].liquidityTarget.functionStaticCall(_actions[i].liquidityCalldata);
                    if (result.length != 32) revert InvalidLiquidityResult();

                    requested = Math.min(shortfall, abi.decode(result, (uint256)));
                }
                if (requested != 0) {
                    IMerkleAdapter.Action[] memory withdrawal = new IMerkleAdapter.Action[](1);
                    withdrawal[0] = actions[i];
                    uint256 beforeBalance = IERC20(asset).balanceOf(adapter);
                    IMerkleAdapter(adapter).manage(withdrawal);
                    uint256 afterBalance = IERC20(asset).balanceOf(adapter);
                    if (afterBalance < beforeBalance || afterBalance - beforeBalance != requested) {
                        revert LiquidityMismatch();
                    }

                    emit PrepareLiquidity(adapter, asset, i, requested);
                }
            }
            if (i == liquidityLength && availableBalance(asset) < amount) revert InsufficientLiquidity();
        }
        IMerkleAdapter.Action calldata operation = actions[actions.length - 1];
        {
            (address currentAsset, uint256 currentAmount) = getRequiredLiquidity(operation);
            if (currentAsset != asset || currentAmount != amount) revert OperationChanged();
        }

        IMerkleAdapter.Action[] memory finalActions = new IMerkleAdapter.Action[](actions.length - liquidityLength);
        for (uint256 i; i < finalActions.length; ++i) {
            finalActions[i] = actions[liquidityLength + i];
        }
        uint256 beforeBalance = IERC20(asset).balanceOf(adapter);
        results = IMerkleAdapter(adapter).manage(finalActions);
        uint256 afterBalance = IERC20(asset).balanceOf(adapter);
        if (afterBalance > beforeBalance || beforeBalance - afterBalance != amount) revert OperationBalanceMismatch();

        emit Execute(adapter, operation.target, asset, amount);
    }

    /// @inheritdoc IExecutor
    function getRequiredLiquidity(IMerkleAdapter.Action calldata operation)
        public
        view
        returns (address asset, uint256 amount)
    {
        if (operation.data.length != 132 || operation.flagsAndValue & ANY_VALUE != 0) revert InvalidOperation();

        bytes4 selector = bytes4(operation.data[:4]);
        if (selector == ILiquidLaneConnector.swap.selector) {
            address connector = operation.target;
            if (ILiquidLaneConnector(connector).adapter() != adapter) revert InvalidAdapter();
            amount = abi.decode(operation.data[4:], (ILiquidLaneConnector.Swap)).amountOut;
            asset = ILiquidLaneConnector(connector).inputAsset();
        } else if (selector == IThreeFCapability.mintRequest.selector) {
            if (operation.target != adapter) revert InvalidAdapter();

            if (IMerkleAdapter(adapter).capabilityForSelector(selector) == address(0)) revert InvalidOperation();
            (address request, uint128 maxPrincipal, uint128 minYield, uint256 deadline) =
                abi.decode(operation.data[4:], (address, uint128, uint128, uint256));
            (uint128 principal, uint128 yieldAmount) = IThreeFPushRequest(request).mintAuthorization(adapter);
            if (yieldAmount == 0 || principal > maxPrincipal || yieldAmount < minYield || block.timestamp > deadline) {
                revert InvalidOperation();
            }

            asset = IERC4626(IMerkleAdapter(adapter).vault()).asset();
            if (IThreeFRequest(request).asset() != asset) revert InvalidOperation();
            amount = principal;
        } else {
            revert InvalidOperation();
        }
        if (asset == address(0) || amount == 0) revert InvalidOperation();
    }

    /// @inheritdoc IExecutor
    function availableBalance(address asset) public view returns (uint256 amount) {
        return IERC20(asset).balanceOf(adapter).saturatingSub(_reservedBalance(asset));
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Mirrors the adapter's pending/deallocation reserve at the oracle's current nonce, before synchronization.
    function _reservedBalance(address asset) internal view returns (uint256 reserved) {
        if (asset != IERC4626(IMerkleAdapter(adapter).vault()).asset()) return 0;
        uint256 nonce = IMerkleAdapterOracle(IMerkleAdapter(adapter).oracle()).nonce();
        uint256 previous = IMerkleAdapter(adapter).lastSyncedNonce();
        reserved = IMerkleAdapter(adapter).deallocatable();
        if (nonce > previous) reserved += IMerkleAdapter(adapter).toDeallocate(previous);
        if (nonce > previous + 1) reserved += IMerkleAdapter(adapter).toDeallocate(previous + 1);
        reserved += IMerkleAdapter(adapter).pendingAllocation(nonce)
        + IMerkleAdapter(adapter).pendingAllocation(nonce + 1);
    }
}
