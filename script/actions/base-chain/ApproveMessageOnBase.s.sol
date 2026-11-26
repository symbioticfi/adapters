// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./base/ApproveMessageOnBaseBase.s.sol";

contract ApproveMessageOnBaseScript is ApproveMessageOnBaseBaseScript {
    string constant MANIFEST = "deployments/base-safe.json";
    string constant PROOFS = "deployments/base-safe-proofs.json";
    bytes32 constant DIGEST = bytes32(0);

    /// @notice Makes the Base Safe accept DIGEST under ERC-1271. Run on Ethereum.
    function run() public {
        runBase(MANIFEST, PROOFS, DIGEST);
    }
}
