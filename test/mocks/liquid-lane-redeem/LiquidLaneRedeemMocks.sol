// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import {Reactor} from "./Reactor.sol";
import {IReactor} from "./IReactor.sol";
import {IExecutor} from "./IReactorExecutor.sol";

import {ILiquidLaneAdapter} from "../../../src/interfaces/ILiquidLaneAdapter.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Exposes upstream hashing so tests compare capability digests with the consumer's implementation.
contract LiquidLaneReactorReference is Reactor {
    constructor(address adapterFactory) Reactor(adapterFactory) {}

    function requestDigest(IReactor.Request memory request) external view returns (bytes32) {
        return _hashTypedDataV4(_hashRequest(request));
    }

    function orderDigest(IReactor.Order memory order) external view returns (bytes32) {
        return _hashTypedDataV4(_hashOrder(order));
    }
}

/// @dev Executes actual LiquidLaneAdapter swaps after the real Reactor authorizes and transfers the input.
contract LiquidLaneRedeemFiller is IExecutor {
    using SafeERC20 for IERC20;

    error NotReactor();

    address public immutable REACTOR;

    constructor(address reactor) {
        REACTOR = reactor;
    }

    function fill(IReactor.Order memory order, bytes memory signature, IReactor.SwapInput memory swapInput) external {
        IReactor(REACTOR).fill(order, signature, swapInput, bytes(""));
    }

    function execute(
        IReactor.Order calldata order,
        IReactor.SwapInput[] calldata swapInputs,
        IReactor.DiscountSwapInput[] calldata discountSwapInputs,
        bytes calldata
    ) external {
        if (msg.sender != REACTOR) {
            revert NotReactor();
        }
        for (uint256 i; i < swapInputs.length; ++i) {
            ILiquidLaneAdapter(swapInputs[i].adapter).swap(swapInputs[i].swap);
        }
        for (uint256 i; i < discountSwapInputs.length; ++i) {
            IReactor.DiscountSwapInput calldata swapInput = discountSwapInputs[i];
            ILiquidLaneAdapter(swapInput.adapter)
                .swap(swapInput.discountSwap, swapInput.protocolSignature, swapInput.recipient, swapInput.amountIn);
        }
        for (uint256 i; i < order.outputs.length; ++i) {
            IERC20 token = IERC20(order.outputs[i].token);
            token.forceApprove(REACTOR, token.allowance(address(this), REACTOR) + order.outputs[i].amount);
        }
    }
}

/// @dev Token failures model why cancellation must not depend on successful funding recovery.
contract LiquidLaneRedeemTokenMock is ERC20 {
    error TokenPaused();

    bool public paused;
    uint256 public transferFee;

    constructor() ERC20("Redeem Token", "RWA") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function setTransferFee(uint256 fee) external {
        transferFee = fee;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        if (paused) {
            revert TokenPaused();
        }
        return super.approve(spender, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0)) {
            if (paused) {
                revert TokenPaused();
            }
            uint256 fee = transferFee;
            if (to != address(0) && fee > 0) {
                super._update(from, address(0), fee);
                amount -= fee;
            }
        }
        super._update(from, to, amount);
    }
}
