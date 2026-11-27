// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./base/SetThreeFMinYieldOnBaseBase.s.sol";

contract SetThreeFMinYieldOnBaseScript is SetThreeFMinYieldOnBaseBaseScript {
    string constant MANIFEST = "deployments/base-safe.json";
    string constant PROOFS = "deployments/base-safe-proofs.json";
    address constant UNDERLYING_ASSET = 0x0000000000000000000000000000000000000000;
    uint256 constant MINIMUM = 0;

    /// @notice Sets the Base Safe policy's minimum yield for UNDERLYING_ASSET. Run on Ethereum.
    function run() public {
        runBase(MANIFEST, PROOFS, UNDERLYING_ASSET, MINIMUM);
    }
}
