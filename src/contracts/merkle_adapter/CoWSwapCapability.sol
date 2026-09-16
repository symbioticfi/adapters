// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity 0.8.36;

import {Capability} from "./Capability.sol";

import {
    COW_SWAP_BALANCE_ERC20,
    COW_SWAP_KIND_SELL,
    COW_SWAP_ORDER_TYPEHASH,
    ICoWSwapConverter,
    ICoWSwapSettlement,
    MAX_VALID_TO_DURATION
} from "../../interfaces/common/ICoWSwapConverter.sol";
import {ICoWSwapCapability, ICoWSwapCapabilityConstants} from "../../interfaces/merkle_adapter/ICoWSwapCapability.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title CoWSwapCapability
/// @notice Contract for adapter-owned CoW Protocol sell orders authorized through Merkle self-calls.
contract CoWSwapCapability is Capability, ICoWSwapCapabilityConstants, ICoWSwapCapability {
    /* IMMUTABLES */

    /// @inheritdoc ICoWSwapCapability
    address public immutable COW_SWAP_SETTLEMENT;

    /// @inheritdoc ICoWSwapCapability
    address public immutable COW_SWAP_VAULT_RELAYER;

    /* STATE VARIABLES */

    /// @custom:storage-location erc7201:symbiotic.storage.CoWSwapCapability
    struct CoWSwapStorage {
        mapping(address tokenIn => bytes orderUid) activeOrderUid;
        mapping(address tokenIn => address settlement) settlements;
    }

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
        if (tokenIn == tokenOut || tokenIn.code.length == 0 || tokenOut.code.length == 0) {
            revert InvalidToken();
        }

        if (amountIn == 0) revert InvalidSellAmount();

        if (params.buyAmount == 0) revert InvalidBuyAmount();

        if (params.validTo <= block.timestamp) revert ExpiredOrder();

        if (params.validTo > block.timestamp + MAX_VALID_TO_DURATION) revert TooFarValidTo();

        if (amountIn > IERC20(tokenIn).balanceOf(address(this))) revert InvalidSellAmount();

        _invalidateConvert(tokenIn);
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
                                receiver: address(this),
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
        CoWSwapStorage storage $ = _getCoWSwapStorage();
        $.activeOrderUid[tokenIn] = orderUid;
        $.settlements[tokenIn] = COW_SWAP_SETTLEMENT;
        ICoWSwapSettlement(COW_SWAP_SETTLEMENT).setPreSignature(orderUid, true);

        emit Convert(orderUid, tokenIn, amountIn, tokenOut, params);
    }

    /// @inheritdoc ICoWSwapCapability
    function invalidateConvert(address tokenIn) public onlyMyself {
        _invalidateConvert(tokenIn);
    }

    /// @inheritdoc ICoWSwapCapability
    function activeOrderUid(address tokenIn) public view returns (bytes memory) {
        return _getCoWSwapStorage().activeOrderUid[tokenIn];
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Uses the original settlement so replacing capability code cannot orphan an existing pre-signature.
    function _invalidateConvert(address tokenIn) internal {
        CoWSwapStorage storage $ = _getCoWSwapStorage();
        bytes memory orderUid = $.activeOrderUid[tokenIn];
        if (orderUid.length != 0) {
            address settlement = $.settlements[tokenIn];
            delete $.activeOrderUid[tokenIn];
            delete $.settlements[tokenIn];
            ICoWSwapSettlement(settlement).setPreSignature(orderUid, false);
            emit InvalidateConvert(tokenIn, orderUid);
        }
    }

    /// @dev Resolves tracked CoW orders in the calling adapter.
    function _getCoWSwapStorage() internal pure returns (CoWSwapStorage storage $) {
        assembly ("memory-safe") {
            $.slot := COW_SWAP_STORAGE_LOCATION
        }
    }
}
