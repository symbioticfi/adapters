// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {Capability} from "src/contracts/merkle_adapter/Capability.sol";

import {GPv2Order} from "src/libraries/GPv2Order.sol";

import {ICoWSwapCapability} from "src/interfaces/merkle_adapter/ICoWSwapCapability.sol";
import {ICoWSwapSettlement, MAX_VALID_TO_DURATION} from "src/interfaces/common/ICoWSwapConverter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title CoWSwapCapability
/// @notice Contract for adapter-owned CoW Protocol sell orders authorized through Merkle self-calls.
contract CoWSwapCapability layout at erc7201("symbiotic.storage.CoWSwapCapability") is Capability, ICoWSwapCapability {
    /* IMMUTABLES */

    /// @inheritdoc ICoWSwapCapability
    address public immutable COW_SWAP_SETTLEMENT;

    /// @inheritdoc ICoWSwapCapability
    address public immutable COW_SWAP_VAULT_RELAYER;

    /* STATE VARIABLES */

    mapping(address tokenIn => bytes orderUid) internal _activeOrderUid;
    mapping(address tokenIn => address settlement) internal _settlements;

    /* CONSTRUCTOR */

    /// @dev Binds the CoW Protocol deployment in the approved implementation.
    constructor(address newCowSwapSettlement) {
        COW_SWAP_SETTLEMENT = newCowSwapSettlement;
        COW_SWAP_VAULT_RELAYER = ICoWSwapSettlement(newCowSwapSettlement).vaultRelayer();
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ICoWSwapCapability
    function convert(address tokenIn, uint256 amountIn, address tokenOut, OrderParams calldata params)
        public
        onlyMyself
        returns (bytes memory orderUid)
    {
        if (tokenIn == tokenOut) revert InvalidToken();

        if (tokenIn.code.length == 0 || tokenOut.code.length == 0) revert InvalidToken();

        if (amountIn == 0) revert InvalidSellAmount();

        if (params.buyAmount == 0) revert InvalidBuyAmount();

        if (params.validTo <= block.timestamp) revert ExpiredOrder();

        if (params.validTo > block.timestamp + MAX_VALID_TO_DURATION) revert TooFarValidTo();

        if (amountIn > IERC20(tokenIn).balanceOf(address(this))) revert InvalidSellAmount();

        _invalidateConvert(tokenIn);
        orderUid = abi.encodePacked(
            GPv2Order.hash(
                GPv2Order.Data({
                    sellToken: IERC20(tokenIn),
                    buyToken: IERC20(tokenOut),
                    receiver: address(this),
                    sellAmount: amountIn,
                    buyAmount: params.buyAmount,
                    validTo: params.validTo,
                    appData: params.appData,
                    feeAmount: 0,
                    kind: GPv2Order.KIND_SELL,
                    partiallyFillable: true,
                    sellTokenBalance: GPv2Order.BALANCE_ERC20,
                    buyTokenBalance: GPv2Order.BALANCE_ERC20
                }),
                ICoWSwapSettlement(COW_SWAP_SETTLEMENT).domainSeparator()
            ),
            address(this),
            params.validTo
        );
        _activeOrderUid[tokenIn] = orderUid;
        _settlements[tokenIn] = COW_SWAP_SETTLEMENT;
        ICoWSwapSettlement(COW_SWAP_SETTLEMENT).setPreSignature(orderUid, true);

        emit Convert(orderUid, tokenIn, amountIn, tokenOut, params);
    }

    /// @inheritdoc ICoWSwapCapability
    function invalidateConvert(address tokenIn) public onlyMyself {
        _invalidateConvert(tokenIn);
    }

    /// @inheritdoc ICoWSwapCapability
    function activeOrderUid(address tokenIn) public view returns (bytes memory) {
        return _activeOrderUid[tokenIn];
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Uses the original settlement so replacing capability code cannot orphan an existing pre-signature.
    function _invalidateConvert(address tokenIn) internal {
        bytes memory orderUid = _activeOrderUid[tokenIn];
        if (orderUid.length > 0) {
            address settlement = _settlements[tokenIn];
            delete _activeOrderUid[tokenIn];
            delete _settlements[tokenIn];
            ICoWSwapSettlement(settlement).setPreSignature(orderUid, false);
            emit InvalidateConvert(tokenIn, orderUid);
        }
    }
}
