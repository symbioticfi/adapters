// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

/**
 * @title SpikoRedemption
 * @notice Library for constructing repeatable Spiko redemption actions with a variable salt.
 */
library SpikoRedemption {
    /**
     * @notice Builds an action that pins the redemption route and amount, allowing only the salt to vary.
     * @dev Generate a fresh salt for each request. Reused amount/salt pairs produce the same request ID.
     */
    function action(address token, address redemption, address outputAsset, uint256 amount, bytes32 salt)
        internal
        pure
        returns (IMerkleAccount.Action memory result)
    {
        result = IMerkleAccount.Action({
            target: token,
            value: 0,
            data: abi.encodeWithSignature(
                "transferAndCall(address,uint256,bytes)", redemption, amount, abi.encode(outputAsset, salt)
            ),
            dataMask: new bytes(196),
            proof: new bytes32[](0)
        });
        // Selector, three argument words, bytes length and output asset precede the salt word.
        for (uint256 i = 164; i < 196; ++i) {
            result.dataMask[i] = 0xff;
        }
    }
}
