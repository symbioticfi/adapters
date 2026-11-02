// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Symbiotic
pragma solidity ^0.8.28;

import {IMerklClaimer, IMerklDistributor} from "../../interfaces/common/IMerklClaimer.sol";

/// @title MerklClaimer
/// @notice Contract for forwarding Merkl distributor claims.
contract MerklClaimer is IMerklClaimer {
    /* IMMUTABLES */

    /// @inheritdoc IMerklClaimer
    address public immutable MERKL_DISTRIBUTOR;

    /* CONSTRUCTOR */

    constructor(address newMerklDistributor) {
        MERKL_DISTRIBUTOR = newMerklDistributor;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IMerklClaimer
    function claim(address[] calldata tokens, uint256[] calldata amounts, bytes32[][] calldata proofs) public {
        address[] memory users = new address[](tokens.length);
        for (uint256 i; i < users.length; ++i) {
            users[i] = address(this);
        }
        IMerklDistributor(MERKL_DISTRIBUTOR).claim(users, tokens, amounts, proofs);
    }
}
