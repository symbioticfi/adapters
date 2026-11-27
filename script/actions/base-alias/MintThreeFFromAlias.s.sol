// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./base/MintThreeFFromAliasBase.s.sol";

contract MintThreeFFromAliasScript is MintThreeFFromAliasBaseScript {
    string constant MANIFEST = "deployments/base-alias.json";
    string constant PROOFS = "deployments/base-alias-proofs.json";
    address constant EXECUTOR = 0x0000000000000000000000000000000000000000;
    uint256 constant MAX_PRINCIPAL = 0;
    address constant REQUEST = 0x0000000000000000000000000000000000000000;
    uint128 constant PRINCIPAL = 0;
    uint128 constant YIELD = 0;

    /// @notice Queues an atomic mint in the Base AccessManager through the committed Ethereum recipe. Run on Ethereum.
    function run() public {
        runBase(MANIFEST, PROOFS, EXECUTOR, MAX_PRINCIPAL, REQUEST, PRINCIPAL, YIELD);
    }
}
