// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./base/RedeemThreeFFromAliasBase.s.sol";

contract RedeemThreeFFromAliasScript is RedeemThreeFFromAliasBaseScript {
    string constant MANIFEST = "deployments/base-alias.json";
    string constant PROOFS = "deployments/base-alias-proofs.json";
    address constant REQUEST = 0x0000000000000000000000000000000000000000;

    /// @notice Redeems the Base manager's position in REQUEST after the auction is REPAID. Run on Ethereum.
    function run() public {
        runBase(MANIFEST, PROOFS, REQUEST);
    }
}
