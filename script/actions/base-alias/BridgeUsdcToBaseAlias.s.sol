// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./base/BridgeUsdcToBaseAliasBase.s.sol";

contract BridgeUsdcToBaseAliasScript is BridgeUsdcToBaseAliasBaseScript {
    string constant MANIFEST = "deployments/base-alias.json";
    string constant PROOFS = "deployments/base-alias-proofs.json";
    uint256 constant AMOUNT = 0;

    /// @notice Bridges AMOUNT USDC from the Ethereum MerkleAccount to the Base manager. Run on Ethereum.
    function run() public {
        runBase(MANIFEST, PROOFS, AMOUNT);
    }
}
