// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./base/ResetThreeFApprovalFromAliasBase.s.sol";

contract ResetThreeFApprovalFromAliasScript is ResetThreeFApprovalFromAliasBaseScript {
    string constant MANIFEST = "deployments/base-alias.json";
    string constant PROOFS = "deployments/base-alias-proofs.json";
    address constant SPENDER = 0x0000000000000000000000000000000000000000;

    /// @notice Sets the Base alias USDC approval to SPENDER to zero. Run on Ethereum.
    function run() public {
        runBase(MANIFEST, PROOFS, SPENDER);
    }
}
