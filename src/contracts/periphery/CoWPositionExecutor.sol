// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {GPv2Order} from "src/libraries/GPv2Order.sol";

import {ICoWPositionExecutor} from "src/interfaces/periphery/ICoWPositionExecutor.sol";
import {ICoWSwapSettlement} from "src/interfaces/common/ICoWSwapConverter.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {
    IPositionFlashLender,
    IPositionFlashLoanRouter,
    IPositionSettlement
} from "src/interfaces/periphery/ICoWPositionDependencies.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CoWPositionExecutor
/// @notice Contract for atomic, Merkle-authorized position changes around one exact CoW sell order.
/// @dev The fixed owner selects position calls, which always run through manage.
/// No critical operation depends on a settlement hook; failed finalization reverts the enclosing flash loan.
/// @custom:security-contact https://github.com/symbioticfi/adapters/security
contract CoWPositionExecutor is ICoWPositionExecutor {
    using SafeERC20 for IERC20;

    /* IMMUTABLES */

    /// @inheritdoc ICoWPositionExecutor
    address public immutable owner;

    /// @inheritdoc ICoWPositionExecutor
    address public immutable adapter;

    /// @inheritdoc ICoWPositionExecutor
    address public immutable router;

    /// @inheritdoc ICoWPositionExecutor
    address public immutable lender;

    /// @inheritdoc ICoWPositionExecutor
    address public immutable settlement;

    /// @inheritdoc ICoWPositionExecutor
    address public immutable vaultRelayer;

    /* STATE VARIABLES */

    /// @inheritdoc ICoWPositionExecutor
    bytes32 public orderHash;

    /// @inheritdoc ICoWPositionExecutor
    bytes32 public lastCompletedOrderHash;

    Intent internal _intent;

    bool internal transient _busy;
    uint256 internal transient _premium;

    /* MODIFIERS */

    modifier onlyIdleOwner() {
        if (owner != msg.sender) revert Unauthorized();
        if (_busy) revert InvalidCallback();
        _busy = true;
        _;
        _busy = false;
    }

    /* CONSTRUCTOR */

    /// @dev Sets the permanent owner, adapter and trusted settlement dependencies.
    constructor(address newOwner, address newAdapter, address newRouter, address newLender) {
        owner = newOwner;
        adapter = newAdapter;
        router = newRouter;
        lender = newLender;
        settlement = IPositionFlashLoanRouter(newRouter).settlementContract();
        vaultRelayer = ICoWSwapSettlement(settlement).vaultRelayer();
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ICoWPositionExecutor
    function arm(Intent calldata newIntent) public onlyIdleOwner returns (bytes memory uid) {
        if (active()) revert ActiveIntent();
        if (newIntent.order.sellAmount == 0 || newIntent.order.buyAmount == 0) revert InvalidIntent();
        for (uint256 i; i < newIntent.actions.length; ++i) {
            if (newIntent.actions[i].value > 0) revert InvalidIntent();
        }
        if (_intent.order.sellToken != address(0)) IERC20(_intent.order.sellToken).forceApprove(vaultRelayer, 0);
        _intent = newIntent;
        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(newIntent.order.sellToken),
            buyToken: IERC20(newIntent.order.buyToken),
            receiver: address(this),
            sellAmount: newIntent.order.sellAmount,
            buyAmount: newIntent.order.buyAmount,
            validTo: newIntent.order.validTo,
            appData: newIntent.order.appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
        orderHash = GPv2Order.hash(order, ICoWSwapSettlement(settlement).domainSeparator());
        uid = orderUid();
        IERC20(newIntent.order.sellToken).forceApprove(vaultRelayer, active() ? newIntent.order.sellAmount : 0);
        emit Arm(orderHash, uid, newIntent);
    }

    /// @inheritdoc ICoWPositionExecutor
    function flashLoanAndCallBack(address, address, uint256, bytes calldata data) public {
        if (router != msg.sender) revert Unauthorized();
        if (_busy) revert InvalidCallback();
        _busy = true;
        address[] memory assets = new address[](1);
        assets[0] = _loanToken();
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _intent.loanAmount;
        IPositionFlashLender(lender).flashLoan(address(this), assets, amounts, new uint256[](1), address(this), data, 0);
        lastCompletedOrderHash = orderHash;
        _busy = false;
        emit FlashLoanAndCallBack(orderHash, _intent.loanAmount, _premium);
    }

    /// @inheritdoc ICoWPositionExecutor
    function executeOperation(
        address[] calldata,
        uint256[] calldata,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata data
    ) public returns (bool) {
        if (lender != msg.sender || initiator != address(this)) revert InvalidCallback();
        if (premiums[0] > _intent.maxPremium) revert InvalidLoan();
        _premium = premiums[0];
        Order storage order = _intent.order;
        uint256 adapterSell = IERC20(order.sellToken).balanceOf(adapter);
        uint256 adapterBuy = IERC20(order.buyToken).balanceOf(adapter);
        IERC20(order.buyToken).safeTransfer(adapter, _intent.leverage ? _settle(data) : _intent.loanAmount);
        IMerkleAdapter(adapter).manage(_intent.actions);
        if (!_intent.leverage) _settle(data);
        IERC20(order.sellToken).forceApprove(vaultRelayer, 0);
        uint256 repayment = _intent.loanAmount + premiums[0];
        _returnToken(order.sellToken, _intent.leverage ? repayment : 0);
        _returnToken(order.buyToken, _intent.leverage ? 0 : repayment);
        if (
            IERC20(order.sellToken).balanceOf(adapter) < adapterSell
                || IERC20(order.buyToken).balanceOf(adapter) < adapterBuy
        ) revert AdapterBalanceReduced();
        IERC20(_loanToken()).forceApprove(lender, repayment);
        return true;
    }

    /// @inheritdoc ICoWPositionExecutor
    function orderUid() public view returns (bytes memory) {
        return orderHash == bytes32(0) ? bytes("") : abi.encodePacked(orderHash, address(this), _intent.order.validTo);
    }

    /// @inheritdoc ICoWPositionExecutor
    function active() public view returns (bool) {
        return orderHash != lastCompletedOrderHash && block.timestamp <= _intent.order.validTo;
    }

    /// @inheritdoc ICoWPositionExecutor
    function getIntent() public view returns (Intent memory) {
        return _intent;
    }

    /// @inheritdoc ICoWPositionExecutor
    function isValidSignature(bytes32 hash, bytes calldata) public view returns (bytes4) {
        return active() && hash == orderHash ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    /* INTERNAL FUNCTIONS */

    function _settle(bytes calldata data) internal returns (uint256 bought) {
        Order storage order = _intent.order;
        uint256 sellBefore = IERC20(order.sellToken).balanceOf(address(this));
        uint256 buyBefore = IERC20(order.buyToken).balanceOf(address(this));
        IPositionFlashLoanRouter(router).borrowerCallBack(data);
        uint256 sold = sellBefore - IERC20(order.sellToken).balanceOf(address(this));
        bought = IERC20(order.buyToken).balanceOf(address(this)) - buyBefore;
        if (
            IPositionSettlement(settlement).filledAmount(orderUid()) != order.sellAmount || sold != order.sellAmount
                || bought < order.buyAmount
        ) revert OrderNotFilled();
    }

    function _returnToken(address token, uint256 reserved) internal {
        uint256 surplus = IERC20(token).balanceOf(address(this)) - reserved;
        if (surplus > 0) IERC20(token).safeTransfer(adapter, surplus);
    }

    function _loanToken() internal view returns (address) {
        return _intent.leverage ? _intent.order.sellToken : _intent.order.buyToken;
    }
}
