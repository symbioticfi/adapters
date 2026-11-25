// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IWETH} from "src/interfaces/ll-adapter/etherfi/IWETH.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TestnetWETH
 * @notice ETH-backed wrapped native token for the standalone testnet.
 * @dev Supply is created only by native deposits. No privileged mint exists.
 */
contract TestnetWETH is ERC20, ReentrancyGuard, IWETH {
    using Address for address payable;

    /* CONSTRUCTOR */

    constructor() ERC20("Wrapped Testnet Ether", "WETH") {}

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IWETH
    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    /// @notice Burns WETH and releases its deposited ETH to the caller.
    function withdraw(uint256 amount) public nonReentrant {
        _burn(msg.sender, amount);
        payable(msg.sender).sendValue(amount);
    }

    /* RECEIVE FUNCTION */

    receive() external payable {
        deposit();
    }
}
