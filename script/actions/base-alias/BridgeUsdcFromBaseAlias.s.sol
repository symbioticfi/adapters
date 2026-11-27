// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./base/BridgeUsdcFromBaseAliasBase.s.sol";

contract BridgeUsdcFromBaseAliasScript is BridgeUsdcFromBaseAliasBaseScript {
    string constant MANIFEST = "deployments/base-alias.json";
    string constant PROOFS = "deployments/base-alias-proofs.json";
    uint256 constant AMOUNT = 0;

    /// @notice Bridges AMOUNT USDC from the Base manager back to the Ethereum MerkleAccount. Run on Ethereum.
    function run() public {
        runBase(MANIFEST, PROOFS, AMOUNT);
    }
}
