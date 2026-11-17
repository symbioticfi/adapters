// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {ERC4626Oracle} from "../ERC4626Oracle.sol";

/// @title fxLOOP_Oracle
/// @notice Mainnet fxLOOP oracle with fixed source and price bounds.
/// @dev Reference block 26433989: 1_018_647_000_000_000_000; bounds 25% / 350%.
contract fxLOOP_Oracle is ERC4626Oracle {
    uint256 private constant MIN_PRICE_BOUND = 254_661_750_000_000_000;
    uint256 private constant MAX_PRICE_BOUND = 3_565_264_500_000_000_000;
    address private constant TOKEN_ADDRESS = 0x4Ef75e307f7EDbf0462C679192C1FF7E911c389a;

    constructor() ERC4626Oracle(MIN_PRICE_BOUND, MAX_PRICE_BOUND, TOKEN_ADDRESS) {}
}
