// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IReactor} from "./IReactor.sol";

/// @dev Exact callback ABI used by the source-pinned Reactor reference.
interface IExecutor {
    function execute(
        IReactor.Order calldata order,
        IReactor.SwapInput[] calldata swapInputs,
        IReactor.DiscountSwapInput[] calldata discountSwapInputs,
        bytes calldata executorData
    ) external;
}
