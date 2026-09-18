// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.37;

import {
    COW_SWAP_BALANCE_ERC20,
    COW_SWAP_KIND_SELL,
    COW_SWAP_ORDER_TYPEHASH,
    COW_SWAP_ORDER_UID_LENGTH,
    EXECUTION_DELAY,
    ICoWSwapConverter,
    ICoWSwapConverterConstants,
    ICoWSwapSettlement,
    MAX_VALID_TO_DURATION
} from "../../interfaces/common/ICoWSwapConverter.sol";
import {IConverter} from "../../interfaces/common/IConverter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CoWSwapConverter
/// @notice Converter contract for asynchronous CoW Protocol sell orders via pre-signing.
abstract contract CoWSwapConverter is
    OwnableUpgradeable,
    NoncesUpgradeable,
    ICoWSwapConverterConstants,
    ICoWSwapConverter
{
    using SafeERC20 for IERC20;

    /* IMMUTABLES */

    /// @inheritdoc ICoWSwapConverter
    address public immutable COW_SWAP_SETTLEMENT;

    /// @inheritdoc ICoWSwapConverter
    address public immutable COW_SWAP_VAULT_RELAYER;

    /* STATE VARIABLES */

    /// @custom:storage-location erc7201:symbiotic.storage.CoWSwapConverter
    struct CoWSwapConverterStorage {
        address[] converters;
        mapping(uint256 nonce => mapping(bytes32 requestHash => uint48 timestamp)) executableAt;
    }

    /* CONSTRUCTOR */

    constructor(address newCowSwapSettlement) {
        COW_SWAP_SETTLEMENT = newCowSwapSettlement;
        COW_SWAP_VAULT_RELAYER = ICoWSwapSettlement(newCowSwapSettlement).vaultRelayer();
    }

    /* EXTERNAL FUNCTIONS */

    /// @inheritdoc ICoWSwapConverter
    function invalidateConvert(bytes calldata orderUid) external {
        if (!_isConverter(msg.sender)) revert InvalidCaller();

        ICoWSwapSettlement(COW_SWAP_SETTLEMENT).setPreSignature(orderUid, false);

        emit InvalidateConvert(orderUid);
    }

    /// @inheritdoc ICoWSwapConverter
    function invalidateConverts(address tokenIn) external {
        if (!_isConverter(msg.sender)) revert InvalidCaller();

        _useNonce(tokenIn);

        emit InvalidateConverts(tokenIn);
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ICoWSwapConverter
    function executableAt(uint256 nonce, bytes32 requestHash) public view returns (uint48) {
        return _getCoWSwapConverterStorage().executableAt[nonce][requestHash];
    }

    /// @inheritdoc ICoWSwapConverter
    function converters(uint256 index) public view returns (address) {
        return _getCoWSwapConverterStorage().converters[index];
    }

    /// @inheritdoc IConverter
    function convert(address tokenIn, uint256 amountIn, address tokenOut, bytes calldata data) public virtual override {
        _validateConvert(tokenIn, amountIn, tokenOut, data);

        OrderParams memory params = abi.decode(data, (OrderParams));
        if (params.validTo <= block.timestamp) revert ExpiredOrder();

        if (params.validTo > block.timestamp + MAX_VALID_TO_DURATION) revert TooFarValidTo();

        if (!_isConverter(msg.sender)) {
            uint48 timestamp = _getCoWSwapConverterStorage()
            .executableAt[nonces(tokenIn)][keccak256(abi.encode(tokenIn, amountIn, tokenOut, data))];
            if (timestamp == 0 || block.timestamp < timestamp) revert ExecutionDelayNotElapsed();
        }
        _useNonce(tokenIn);

        if (IERC20(tokenIn).allowance(address(this), COW_SWAP_VAULT_RELAYER) < amountIn) {
            IERC20(tokenIn).forceApprove(COW_SWAP_VAULT_RELAYER, type(uint256).max);
        }

        bytes memory orderUid = new bytes(COW_SWAP_ORDER_UID_LENGTH);
        Data memory order = Data({
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
        });
        bytes32 domainSeparator = ICoWSwapSettlement(COW_SWAP_SETTLEMENT).domainSeparator();
        // Hash the static GPv2 fields and pack the digest, owner, and validity timestamp into the UID.
        assembly {
            let dataStart := sub(order, 32)
            let temp := mload(dataStart)
            mstore(dataStart, COW_SWAP_ORDER_TYPEHASH)
            let structHash := keccak256(dataStart, 416)
            mstore(dataStart, temp)

            let freeMemoryPointer := mload(0x40)
            mstore(freeMemoryPointer, "\x19\x01")
            mstore(add(freeMemoryPointer, 2), domainSeparator)
            mstore(add(freeMemoryPointer, 34), structHash)
            let orderDigest := keccak256(freeMemoryPointer, 66)

            mstore(add(orderUid, 56), mload(add(params, 32)))
            mstore(add(orderUid, 52), address())
            mstore(add(orderUid, 32), orderDigest)
        }
        ICoWSwapSettlement(COW_SWAP_SETTLEMENT).setPreSignature(orderUid, true);

        emit Convert(orderUid, tokenIn, amountIn, tokenOut, params);
    }

    /// @inheritdoc ICoWSwapConverter
    function prepareConvert(address tokenIn, uint256 amountIn, address tokenOut, bytes calldata data)
        public
        virtual
        returns (bytes32 requestHash)
    {
        _validateConvert(tokenIn, amountIn, tokenOut, data);

        if (abi.decode(data, (OrderParams)).validTo <= block.timestamp + EXECUTION_DELAY) revert ExpiredOrder();

        requestHash = keccak256(abi.encode(tokenIn, amountIn, tokenOut, data));

        CoWSwapConverterStorage storage $ = _getCoWSwapConverterStorage();
        if ($.executableAt[nonces(tokenIn)][requestHash] > 0) revert AlreadyReservedOrder();

        $.executableAt[nonces(tokenIn)][requestHash] = uint48(block.timestamp) + EXECUTION_DELAY;

        emit PrepareConvert(tokenIn, amountIn, tokenOut, data);
    }

    /// @inheritdoc ICoWSwapConverter
    function setConverters(address[] calldata newConverters) public onlyOwner {
        _getCoWSwapConverterStorage().converters = newConverters;

        emit SetConverters(newConverters);
    }

    /* INTERNAL FUNCTIONS */

    // keccak256(abi.encode(uint256(keccak256("symbiotic.storage.CoWSwapConverter")) - 1)) & ~bytes32(uint256(0xff))

    /// @dev Returns CoW converter storage at the ERC-7201 namespace.
    function _getCoWSwapConverterStorage() internal pure returns (CoWSwapConverterStorage storage $) {
        assembly {
            $.slot := COW_SWAP_CONVERTER_STORAGE_LOCATION
        }
    }

    function _validateConvert(address tokenIn, uint256 amountIn, address tokenOut, bytes calldata data) internal view {
        if (tokenIn == tokenOut) revert InvalidTokenIn();

        if (amountIn == 0 || amountIn > IERC20(tokenIn).balanceOf(address(this))) revert InvalidSellAmount();

        if (abi.decode(data, (OrderParams)).buyAmount == 0) revert InvalidBuyAmount();
    }

    /// @dev Returns true if the specified address is a converter.
    function _isConverter(address converter) internal view returns (bool) {
        uint256 length = _getCoWSwapConverterStorage().converters.length;
        for (uint256 i; i < length; ++i) {
            if (_getCoWSwapConverterStorage().converters[i] == converter) {
                return true;
            }
        }
        return false;
    }

    /// @dev Registers the initial converters allowed to create orders without the prepared-request delay.
    function __CoWSwapConverter_init(address[] memory initConverters) internal virtual {
        _getCoWSwapConverterStorage().converters = initConverters;
        emit SetConverters(initConverters);
    }
}
