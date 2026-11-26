// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./base/RedeemThreeFOnBaseBase.s.sol";

contract RedeemThreeFOnBaseScript is RedeemThreeFOnBaseBaseScript {
    string constant MANIFEST = "deployments/base-safe.json";
    string constant PROOFS = "deployments/base-safe-proofs.json";
    address constant REQUEST = 0x0000000000000000000000000000000000000000;

    /// @notice Tells the Base Safe to redeem its position in a repaid 3F REQUEST. Run on Ethereum.
    function run() public {
        runBase(MANIFEST, PROOFS, REQUEST);
    }
}
