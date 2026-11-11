// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {
    FLASH_LOAN_SLOT,
    IFlashLoanCapability
} from "../../../interfaces/merkle-adapter/capabilities/IFlashLoanCapability.sol";
import {IAaveV3Pool} from "../../../interfaces/aave_v3_adapter/IAaveV3AdapterDependencies.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

import {IMorpho} from "morpho-blue/src/interfaces/IMorpho.sol";

/// @title FlashLoanCapability
/// @notice Contract for account-context Aave V3 and Morpho Blue flash loans authorized by one Merkle leaf.
contract FlashLoanCapability is IFlashLoanCapability {
    using Address for address;
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    /* IMMUTABLES */

    /// @inheritdoc IFlashLoanCapability
    address public immutable AAVE_V3_POOL;

    /// @inheritdoc IFlashLoanCapability
    address public immutable MORPHO_BLUE;

    /* CONSTRUCTOR */

    constructor(address newAaveV3Pool, address newMorphoBlue) {
        AAVE_V3_POOL = newAaveV3Pool;
        MORPHO_BLUE = newMorphoBlue;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IFlashLoanCapability
    function flashLoan(Type providerType, address token, uint256 amount, bytes calldata data) public {
        if (address(this) != msg.sender) revert InvalidCaller();
        address provider = providerType == Type.Aave ? AAVE_V3_POOL : MORPHO_BLUE;
        FLASH_LOAN_SLOT.asBytes32().tstore(keccak256(abi.encode(provider, token, amount, data)));
        if (providerType == Type.Aave) {
            IAaveV3Pool(provider).flashLoanSimple(address(this), token, amount, data, 0);
        } else {
            IMorpho(provider).flashLoan(token, amount, abi.encode(token, data));
        }
        if (FLASH_LOAN_SLOT.asBytes32().tload() != bytes32(0)) revert UnexpectedFlashLoan();
    }

    /// @inheritdoc IFlashLoanCapability
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        public
        returns (bool)
    {
        if (address(this) != initiator) revert UnexpectedFlashLoan();
        _onFlashLoan(asset, amount, premium, params);
        return true;
    }

    /// @inheritdoc IFlashLoanCapability
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) public {
        (address token, bytes memory selfCallData) = abi.decode(data, (address, bytes));
        _onFlashLoan(token, assets, 0, selfCallData);
    }

    /* INTERNAL FUNCTIONS */

    function _onFlashLoan(address token, uint256 amount, uint256 fee, bytes memory data) internal {
        TransientSlot.Bytes32Slot request = FLASH_LOAN_SLOT.asBytes32();
        if (request.tload() != keccak256(abi.encode(msg.sender, token, amount, data))) revert UnexpectedFlashLoan();
        // Consume before external calls so neither actions nor token hooks can replay the callback.
        request.tstore(bytes32(0));
        address(this).functionCall(data);
        IERC20(token).forceApprove(msg.sender, amount + fee);
    }
}
