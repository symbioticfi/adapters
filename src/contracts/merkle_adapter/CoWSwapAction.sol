// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {
    COW_SWAP_BALANCE_ERC20,
    COW_SWAP_KIND_SELL,
    COW_SWAP_ORDER_TYPEHASH,
    ICoWSwapConverter,
    ICoWSwapSettlement,
    MAX_VALID_TO_DURATION
} from "../../interfaces/common/ICoWSwapConverter.sol";
import {ICoWSwapAction} from "../../interfaces/merkle_adapter/ICoWSwapAction.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";

/// @title CoWSwapAction
/// @notice Contract for adapter-funded CoW Protocol sell orders with bounded relayer approval and recoverable balances.
contract CoWSwapAction is MigratableEntity, ICoWSwapAction {
    using SafeERC20 for IERC20;

    /* IMMUTABLES */

    /// @inheritdoc ICoWSwapAction
    address public immutable COW_SWAP_SETTLEMENT;

    /// @inheritdoc ICoWSwapAction
    address public immutable COW_SWAP_VAULT_RELAYER;

    /* STATE VARIABLES */

    /// @inheritdoc ICoWSwapAction
    address public adapter;

    /// @dev Pins the original deployment so migration cannot orphan existing pre-signatures or allowances.
    address private _initializedSettlement;

    address private _initializedRelayer;

    /// @inheritdoc ICoWSwapAction
    mapping(address tokenIn => bytes orderUid) public activeOrderUid;

    /* MODIFIERS */

    /// @dev Restricts order authorization, cancellation and fund recovery to the bound adapter.
    modifier onlyAdapter() {
        if (adapter != msg.sender) revert InvalidCaller();

        _;
    }

    /* CONSTRUCTOR */

    /// @dev Binds the factory and CoW Protocol deployment shared by action proxies.
    constructor(address newFactory, address newCowSwapSettlement) MigratableEntity(newFactory) {
        COW_SWAP_SETTLEMENT = newCowSwapSettlement;
        COW_SWAP_VAULT_RELAYER = ICoWSwapSettlement(newCowSwapSettlement).vaultRelayer();
    }

    /* EXTERNAL FUNCTIONS */

    /// @inheritdoc ICoWSwapAction
    function convert(address tokenIn, uint256 amountIn, address tokenOut, OrderParams calldata params)
        external
        nonReentrant
        onlyAdapter
        returns (bytes memory orderUid)
    {
        // forgefmt: disable-next-item
        if (
            tokenIn == tokenOut || tokenIn.code.length == 0 || tokenOut.code.length == 0
        ) revert InvalidToken();

        if (amountIn == 0) revert InvalidSellAmount();

        if (params.buyAmount == 0) revert InvalidBuyAmount();

        if (params.validTo <= block.timestamp) revert ExpiredOrder();

        if (params.validTo > block.timestamp + MAX_VALID_TO_DURATION) revert TooFarValidTo();

        // Revoke the previous order before reusing its unspent balance for new funding.
        _recover(tokenIn);
        address sellToken = tokenIn;
        if (amountIn > IERC20(sellToken).balanceOf(msg.sender)) revert InvalidSellAmount();

        IERC20(sellToken).safeTransferFrom(msg.sender, address(this), amountIn);
        if (IERC20(sellToken).balanceOf(address(this)) != amountIn) revert InvalidSellAmount();

        orderUid = abi.encodePacked(
            keccak256(
                abi.encodePacked(
                    hex"1901",
                    ICoWSwapSettlement(COW_SWAP_SETTLEMENT).domainSeparator(),
                    keccak256(
                        abi.encode(
                            COW_SWAP_ORDER_TYPEHASH,
                            ICoWSwapConverter.Data({
                                sellToken: tokenIn,
                                buyToken: tokenOut,
                                receiver: adapter,
                                sellAmount: amountIn,
                                buyAmount: params.buyAmount,
                                validTo: params.validTo,
                                appData: params.appData,
                                feeAmount: 0,
                                kind: COW_SWAP_KIND_SELL,
                                partiallyFillable: true,
                                sellTokenBalance: COW_SWAP_BALANCE_ERC20,
                                buyTokenBalance: COW_SWAP_BALANCE_ERC20
                            })
                        )
                    )
                )
            ),
            address(this),
            params.validTo
        );
        activeOrderUid[tokenIn] = orderUid;
        IERC20(sellToken).forceApprove(COW_SWAP_VAULT_RELAYER, amountIn);
        ICoWSwapSettlement(COW_SWAP_SETTLEMENT).setPreSignature(orderUid, true);

        emit Convert(orderUid, tokenIn, amountIn, tokenOut, params);
    }

    /// @inheritdoc ICoWSwapAction
    function invalidateConvert(address tokenIn) external nonReentrant onlyAdapter {
        _invalidateConvert(tokenIn);
    }

    /// @inheritdoc ICoWSwapAction
    function recover(address token) external nonReentrant onlyAdapter returns (uint256 amount) {
        return _recover(token);
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Revokes the tracked pre-signature without calling the token, including when token operations are paused.
    function _invalidateConvert(address tokenIn) internal {
        bytes memory orderUid = activeOrderUid[tokenIn];
        if (orderUid.length != 0) {
            delete activeOrderUid[tokenIn];
            ICoWSwapSettlement(COW_SWAP_SETTLEMENT).setPreSignature(orderUid, false);
            emit InvalidateConvert(tokenIn, orderUid);
        }
    }

    /// @dev Cancels the order and clears its allowance before returning unused tokens; token failures revert recovery.
    function _recover(address token) internal returns (uint256 amount) {
        if (token.code.length == 0) revert InvalidToken();

        _invalidateConvert(token);
        IERC20(token).forceApprove(COW_SWAP_VAULT_RELAYER, 0);
        amount = IERC20(token).balanceOf(address(this));
        if (amount != 0) {
            IERC20(token).safeTransfer(adapter, amount);
            emit Recover(token, amount);
        }
    }

    /// @dev Binds the action to the adapter encoded in its factory initialization data.
    function _initialize(uint64, address, bytes memory data) internal override {
        adapter = abi.decode(data, (address));
        if (adapter == address(0) || adapter == address(this)) revert InvalidAdapter();

        _initializedSettlement = COW_SWAP_SETTLEMENT;
        _initializedRelayer = COW_SWAP_VAULT_RELAYER;
    }

    /// @dev Keeps the adapter and tracked orders unchanged during a version migration.
    function _migrate(uint64, uint64, bytes calldata data) internal view override {
        if (data.length != 0) revert InvalidMigrationData();

        // forgefmt: disable-next-item
        if (
            COW_SWAP_SETTLEMENT != _initializedSettlement || COW_SWAP_VAULT_RELAYER != _initializedRelayer
        ) revert IncompatibleSettlement();
    }
}
