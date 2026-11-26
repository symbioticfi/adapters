// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./base/SetThreeFMaxAssetsOnBaseBase.s.sol";

contract SetThreeFMaxAssetsOnBaseScript is SetThreeFMaxAssetsOnBaseBaseScript {
    string constant MANIFEST = "deployments/base-safe.json";
    string constant PROOFS = "deployments/base-safe-proofs.json";
    address constant UNDERLYING_ASSET = 0x0000000000000000000000000000000000000000;
    uint256 constant MAX_ASSETS = 0;
    uint48 constant DURATION = 0;

    /// @notice Sets the Base Safe policy's USDC budget per DURATION for UNDERLYING_ASSET. Run on Ethereum.
    function run() public {
        runBase(MANIFEST, PROOFS, UNDERLYING_ASSET, MAX_ASSETS, DURATION);
    }
}
