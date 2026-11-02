// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice Models the deterministic deployer's salt-prefixed calldata interface.
contract TestnetCreate2Factory {
    fallback() external payable {
        assembly ("memory-safe") {
            let length := sub(calldatasize(), 32)
            calldatacopy(0, 32, length)
            let deployed := create2(callvalue(), 0, length, calldataload(0))
            if iszero(deployed) { revert(0, 0) }
            mstore(0, shl(96, deployed))
            return(0, 20)
        }
    }
}
