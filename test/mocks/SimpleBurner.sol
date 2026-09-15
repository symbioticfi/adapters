// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SimpleBurner {
    using SafeERC20 for IERC20;

    address public immutable COLLATERAL;

    constructor(address collateral) {
        COLLATERAL = collateral;
    }

    function distribute() external {
        IERC20(COLLATERAL).safeTransfer(msg.sender, IERC20(COLLATERAL).balanceOf(address(this)));
    }
}
