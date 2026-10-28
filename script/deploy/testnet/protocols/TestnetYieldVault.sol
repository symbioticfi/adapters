// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TestnetYieldVault
/// @notice Standard ERC4626 fixture; gains require actual underlying funding.
contract TestnetYieldVault is ERC4626 {
    constructor(address newAsset) ERC20("Test yield vault", "sTEST") ERC4626(IERC20(newAsset)) {}
}
