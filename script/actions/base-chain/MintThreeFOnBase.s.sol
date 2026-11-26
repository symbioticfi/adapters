// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./base/MintThreeFOnBaseBase.s.sol";

contract MintThreeFOnBaseScript is MintThreeFOnBaseBaseScript {
    string constant MANIFEST = "deployments/base-safe.json";
    string constant PROOFS = "deployments/base-safe-proofs.json";
    address constant REQUEST = 0x0000000000000000000000000000000000000000;
    uint256 constant MAX_ASSETS = 0;

    /// @notice Tells the Base Safe to mint into REQUEST with its live 3F authorization, up to MAX_ASSETS. Run on
    /// Ethereum.
    function run() public {
        runBase(MANIFEST, PROOFS, REQUEST, MAX_ASSETS);
    }
}
