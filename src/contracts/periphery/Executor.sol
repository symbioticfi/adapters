// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {ANY_VALUE, IMerkleAdapter} from "../../interfaces/IMerkleAdapter.sol";
import {IExecutor} from "../../interfaces/periphery/IExecutor.sol";
import {ILiquidLaneConnector} from "../../interfaces/merkle_adapter/ILiquidLaneConnector.sol";
import {IMerkleAdapterOracle} from "../../interfaces/merkle_adapter/IMerkleAdapterOracle.sol";
import {IThreeFCapability} from "../../interfaces/merkle_adapter/IThreeFCapability.sol";
import {IThreeFPushRequest} from "../../interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFRequest} from "../../interfaces/3f-adapter/IThreeFRequest.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title Executor
/// @notice Contract for caller-triggered execution of owner-configured Merkle liquidity and operation plans.
contract Executor is Ownable, ReentrancyGuardTransient, IExecutor {
    using Address for address;
    using Math for uint256;

    /* STATE VARIABLES */

    /// @inheritdoc IExecutor
    address public caller;

    /// @dev Each adapter has an ABI-encoded pair of liquidity steps and final actions.
    mapping(address adapter => bytes actions) internal _actions;

    /* MODIFIERS */

    /// @dev An owner must explicitly select the caller; the zero address disables execution.
    modifier onlyCaller() {
        if (caller != msg.sender) revert InvalidCaller();

        _;
    }

    /* CONSTRUCTOR */

    /// @dev Sets the owner responsible for selecting the caller and configuring execution plans.
    constructor(address newOwner) Ownable(newOwner) {}

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IExecutor
    function setCaller(address newCaller) public nonReentrant onlyOwner {
        caller = newCaller;
        emit SetCaller(newCaller);
    }

    /// @inheritdoc IExecutor
    function setActions(address adapter, LiquidityStep[] calldata liquidity, IMerkleAdapter.Action[] calldata actions)
        public
        nonReentrant
        onlyOwner
    {
        _actions[adapter] = abi.encode(liquidity, actions);
        emit SetActions(adapter, liquidity, actions);
    }

    /// @inheritdoc IExecutor
    function getActions(address adapter)
        public
        view
        returns (LiquidityStep[] memory liquidity, IMerkleAdapter.Action[] memory actions)
    {
        if (_actions[adapter].length == 0) return (new LiquidityStep[](0), new IMerkleAdapter.Action[](0));

        return abi.decode(_actions[adapter], (LiquidityStep[], IMerkleAdapter.Action[]));
    }

    /// @inheritdoc IExecutor
    function execute(address adapter) public nonReentrant onlyCaller returns (bytes[] memory results) {
        (LiquidityStep[] memory liquidity, IMerkleAdapter.Action[] memory actions) = getActions(adapter);
        if (actions.length == 0) revert InvalidOperation();
        for (uint256 i; i < liquidity.length; ++i) {
            if (liquidity[i].action.data.length != liquidity[i].action.dataMask.length) {
                revert IMerkleAdapter.InvalidDataMaskLength();
            }
            uint256 offset = liquidity[i].amountOffset;
            if (offset < 4 || offset > liquidity[i].action.data.length || liquidity[i].action.data.length - offset < 32)
            {
                revert InvalidAmountOffset();
            }

            for (uint256 j; j < 32; ++j) {
                if (liquidity[i].action.dataMask[offset + j] != 0) revert InvalidAmountOffset();
            }
        }

        (address asset, uint256 amount) = getRequiredLiquidity(adapter, actions[actions.length - 1]);
        {
            uint256 i;
            for (; i < liquidity.length; ++i) {
                uint256 requested;
                {
                    uint256 shortfall =
                        (amount + _reservedBalance(adapter, asset)).saturatingSub(IERC20(asset).balanceOf(adapter));
                    if (shortfall == 0) break;
                    bytes memory result = liquidity[i].liquidityTarget.functionStaticCall(liquidity[i].liquidityData);
                    if (result.length != 32) revert InvalidLiquidityResult();

                    requested = Math.min(shortfall, abi.decode(result, (uint256)));
                }
                if (requested != 0) {
                    IMerkleAdapter.Action[] memory withdrawal = new IMerkleAdapter.Action[](1);
                    withdrawal[0] = liquidity[i].action;
                    {
                        bytes memory data = withdrawal[0].data;
                        uint256 offset = liquidity[i].amountOffset;
                        assembly ("memory-safe") {
                            mstore(add(add(data, 32), offset), requested)
                        }
                    }
                    uint256 beforeBalance = IERC20(asset).balanceOf(adapter);
                    IMerkleAdapter(adapter).manage(withdrawal);
                    uint256 afterBalance = IERC20(asset).balanceOf(adapter);
                    if (afterBalance < beforeBalance || afterBalance - beforeBalance != requested) {
                        revert LiquidityMismatch();
                    }

                    emit PrepareLiquidity(adapter, asset, i, requested);
                }
            }
            if (i == liquidity.length && availableBalance(adapter, asset) < amount) revert InsufficientLiquidity();
        }
        IMerkleAdapter.Action memory operation = actions[actions.length - 1];
        {
            (address currentAsset, uint256 currentAmount) = getRequiredLiquidity(adapter, operation);
            if (currentAsset != asset || currentAmount != amount) revert OperationChanged();
        }

        uint256 beforeBalance = IERC20(asset).balanceOf(adapter);
        results = IMerkleAdapter(adapter).manage(actions);
        uint256 afterBalance = IERC20(asset).balanceOf(adapter);
        if (afterBalance > beforeBalance || beforeBalance - afterBalance != amount) revert OperationBalanceMismatch();

        emit Execute(adapter, operation.target, asset, amount);
    }

    /// @inheritdoc IExecutor
    function getRequiredLiquidity(address adapter, IMerkleAdapter.Action memory operation)
        public
        view
        returns (address asset, uint256 amount)
    {
        if (operation.data.length != 132 || operation.flagsAndValue & ANY_VALUE != 0) revert InvalidOperation();

        bytes4 selector = bytes4(operation.data);
        if (selector == ILiquidLaneConnector.swap.selector) {
            address connector = operation.target;
            if (ILiquidLaneConnector(connector).adapter() != adapter) revert InvalidAdapter();
            amount = abi.decode(Bytes.slice(operation.data, 4), (ILiquidLaneConnector.Swap)).amountOut;
            asset = ILiquidLaneConnector(connector).inputAsset();
        } else if (selector == IThreeFCapability.mintRequest.selector) {
            if (operation.target != adapter) revert InvalidAdapter();

            if (IMerkleAdapter(adapter).capabilityForSelector(selector) == address(0)) revert InvalidOperation();
            (address request, uint128 maxPrincipal, uint128 minYield, uint256 deadline) =
                abi.decode(Bytes.slice(operation.data, 4), (address, uint128, uint128, uint256));
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
    function availableBalance(address adapter, address asset) public view returns (uint256 amount) {
        return IERC20(asset).balanceOf(adapter).saturatingSub(_reservedBalance(adapter, asset));
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Mirrors the adapter's pending/deallocation reserve at the oracle's current nonce, before synchronization.
    function _reservedBalance(address adapter, address asset) internal view returns (uint256 reserved) {
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
