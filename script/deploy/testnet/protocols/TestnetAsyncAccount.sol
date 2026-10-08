// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CentrifugeAccount} from "src/contracts/ll-adapter/CentrifugeAccount.sol";

/// @title TestnetAsyncAccount
/// @notice Configurable concrete Centrifuge account using the production ERC-7540 account logic.
contract TestnetAsyncAccount is CentrifugeAccount {
    constructor(
        address newOracle,
        address newFactory,
        uint48 newCooldown,
        address newToken,
        address newRedemptionToken,
        address newCowSettlement
    ) CentrifugeAccount(newOracle, newFactory, newCooldown, newToken, newRedemptionToken, newToken, newCowSettlement) {}
}
