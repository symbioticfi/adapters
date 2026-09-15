// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {MerkleAdapterVerifier} from "../merkle_adapter/libraries/MerkleAdapterVerifier.sol";

import {ANY_VALUE, ANY_VALUE_FLAG, IMerkleAdapter} from "../../interfaces/IMerkleAdapter.sol";
import {IExecutor} from "../../interfaces/periphery/IExecutor.sol";
import {ILiquidLaneCapability} from "../../interfaces/merkle_adapter/ILiquidLaneCapability.sol";
import {IMerkleAdapterOracle} from "../../interfaces/merkle_adapter/IMerkleAdapterOracle.sol";
import {IThreeFCapability} from "../../interfaces/merkle_adapter/IThreeFCapability.sol";
import {IThreeFPushRequest} from "../../interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFRequest} from "../../interfaces/3f-adapter/IThreeFRequest.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title Executor
/// @notice Funds Merkle-managed Liquid Lane swaps and 3F push mints with exact, permissioned liquidity steps.
contract Executor is ReentrancyGuardTransient, IExecutor {
    using Address for address;
    using Math for uint256;

    /// @inheritdoc IExecutor
    function getRequiredLiquidity(address adapter, IMerkleAdapter.Action calldata operation)
        public
        view
        returns (address asset, uint256 amount)
    {
        if (operation.data.length != 132 || operation.flagsAndValue & ANY_VALUE != 0) {
            revert InvalidOperation();
        }
        bytes4 selector = bytes4(operation.data[:4]);
        if (selector == ILiquidLaneCapability.swap.selector) {
            ILiquidLaneCapability capability = ILiquidLaneCapability(operation.target);
            if (capability.adapter() != adapter) revert InvalidAdapter();
            ILiquidLaneCapability.Swap memory swap_ = abi.decode(operation.data[4:], (ILiquidLaneCapability.Swap));
            asset = capability.inputAsset();
            amount = swap_.amountOut;
        } else if (selector == IThreeFCapability.mintRequest.selector) {
            if (IThreeFCapability(operation.target).adapter() != adapter) revert InvalidAdapter();
            (address request, uint128 maxPrincipal, uint128 minYield, uint256 deadline) =
                abi.decode(operation.data[4:], (address, uint128, uint128, uint256));
            (uint128 principal, uint128 yieldAmount) = IThreeFPushRequest(request).mintAuthorization(operation.target);
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
    function availableBalance(address adapter, address asset) public view returns (uint256 amount) {
        return IERC20(asset).balanceOf(adapter).saturatingSub(_reservedBalance(IMerkleAdapter(adapter), asset));
    }

    /// @inheritdoc IExecutor
    function execute(address adapter, LiquidityStep[] calldata liquidity, IMerkleAdapter.Action[] calldata actions)
        external
        nonReentrant
        returns (bytes[] memory results)
    {
        if (actions.length == 0) revert InvalidOperation();
        IMerkleAdapter managed = IMerkleAdapter(adapter);
        {
            bytes32 root = managed.merkleRoot();
            for (uint256 i; i < liquidity.length; ++i) {
                _authorize(managed, root, liquidity[i].action);
                _validateAmountOffset(liquidity[i]);
            }
            for (uint256 i; i < actions.length; ++i) {
                _authorize(managed, root, actions[i]);
            }
        }

        IMerkleAdapter.Action calldata operation = actions[actions.length - 1];
        (address asset, uint256 amount) = getRequiredLiquidity(adapter, operation);
        _prepareLiquidity(managed, asset, amount, liquidity);
        {
            (address currentAsset, uint256 currentAmount) = getRequiredLiquidity(adapter, operation);
            if (currentAsset != asset || currentAmount != amount) revert OperationChanged();
        }

        uint256 beforeBalance = IERC20(asset).balanceOf(adapter);
        results = managed.manage(actions);
        uint256 afterBalance = IERC20(asset).balanceOf(adapter);
        if (afterBalance > beforeBalance || beforeBalance - afterBalance != amount) {
            revert OperationBalanceMismatch(amount, beforeBalance, afterBalance);
        }
        emit Execute(adapter, operation.target, asset, amount);
    }

    /// @dev Mirrors the adapter's pending/deallocation reserve at the oracle's current nonce, before synchronization.
    function _reservedBalance(IMerkleAdapter adapter, address asset) internal view returns (uint256 reserved) {
        if (asset != IERC4626(adapter.vault()).asset()) return 0;
        uint256 nonce = IMerkleAdapterOracle(adapter.oracle()).nonce();
        uint256 previous = adapter.lastSyncedNonce();
        reserved = adapter.deallocatable();
        if (nonce > previous) reserved += adapter.toDeallocate(previous);
        if (nonce > previous + 1) reserved += adapter.toDeallocate(previous + 1);
        reserved += adapter.pendingAllocation(nonce) + adapter.pendingAllocation(nonce + 1);
    }

    /// @dev Checks original caller and Executor permissions before any managed call, including skipped candidates.
    function _authorize(IMerkleAdapter adapter, bytes32 root, IMerkleAdapter.Action calldata action) internal view {
        uint96 value = action.flagsAndValue & ANY_VALUE_FLAG == 0 ? action.flagsAndValue & ANY_VALUE : ANY_VALUE;
        bytes32 leaf = MerkleAdapterVerifier.leaf(action.target, value, action.data, action.dataMask);
        if (!MerkleAdapterVerifier.verify(action.proof, root, leaf)) revert InvalidActionProof();
        if (!adapter.hasRole(leaf, msg.sender)) {
            revert IAccessControl.AccessControlUnauthorizedAccount(msg.sender, leaf);
        }
        if (!adapter.hasRole(leaf, address(this))) {
            revert IAccessControl.AccessControlUnauthorizedAccount(address(this), leaf);
        }
    }

    /// @dev Only a complete wildcard amount word can be substituted without changing the authorized leaf.
    function _validateAmountOffset(LiquidityStep calldata step) internal pure {
        uint256 offset = step.amountOffset;
        if (offset < 4 || offset > step.action.data.length || step.action.data.length - offset < 32) {
            revert InvalidAmountOffset();
        }
        for (uint256 i; i < 32; ++i) {
            if (step.action.dataMask[offset + i] != 0) revert InvalidAmountOffset();
        }
    }

    /// @dev Queries live capacity in order and stops once spendable assets cover the final operation.
    function _prepareLiquidity(IMerkleAdapter adapter, address asset, uint256 amount, LiquidityStep[] calldata steps)
        internal
    {
        for (uint256 i; i < steps.length; ++i) {
            uint256 shortfall =
                (amount + _reservedBalance(adapter, asset)).saturatingSub(IERC20(asset).balanceOf(address(adapter)));
            if (shortfall == 0) return;
            bytes memory result = steps[i].liquidityTarget.functionStaticCall(steps[i].liquidityData);
            if (result.length != 32) revert InvalidLiquidityResult();
            uint256 requested = Math.min(shortfall, abi.decode(result, (uint256)));
            if (requested != 0) _withdraw(adapter, asset, requested, steps[i], i);
        }
        if (availableBalance(address(adapter), asset) < amount) revert InsufficientLiquidity();
    }

    /// @dev Executes a normal leaf with its wildcard amount filled and validates the actual token increase.
    function _withdraw(
        IMerkleAdapter adapter,
        address asset,
        uint256 amount,
        LiquidityStep calldata step,
        uint256 index
    ) internal {
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](1);
        actions[0] = step.action;
        bytes memory data = actions[0].data;
        uint256 offset = step.amountOffset;
        assembly ("memory-safe") {
            mstore(add(add(data, 32), offset), amount)
        }
        uint256 beforeBalance = IERC20(asset).balanceOf(address(adapter));
        adapter.manage(actions);
        uint256 afterBalance = IERC20(asset).balanceOf(address(adapter));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) {
            revert LiquidityMismatch(index, amount, beforeBalance, afterBalance);
        }
        emit PrepareLiquidity(address(adapter), asset, index, amount);
    }
}
