// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

/// @dev A flat structure still needs one step, covering the whole buffer, to produce the struct hash.
function flatPlan(bytes memory buffer) pure returns (IMerkleAccount.Hash[] memory plan) {
    plan = new IMerkleAccount.Hash[](1);
    plan[0] = IMerkleAccount.Hash({offset: 0, length: buffer.length, destination: 0});
}

/// @dev Appends the closing whole-buffer step after the nested steps that collapse inner fields.
function nestedPlan(IMerkleAccount.Hash[] memory steps, bytes memory buffer)
    pure
    returns (IMerkleAccount.Hash[] memory plan)
{
    plan = new IMerkleAccount.Hash[](steps.length + 1);
    for (uint256 i; i < steps.length; ++i) {
        plan[i] = steps[i];
    }
    plan[steps.length] = IMerkleAccount.Hash({offset: 0, length: buffer.length, destination: 0});
}
