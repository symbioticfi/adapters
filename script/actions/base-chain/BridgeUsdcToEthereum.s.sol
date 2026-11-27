// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./base/BridgeUsdcToEthereumBase.s.sol";

contract BridgeUsdcToEthereumScript is BridgeUsdcToEthereumBaseScript {
    string constant MANIFEST = "deployments/base-safe.json";
    string constant PROOFS = "deployments/base-safe-proofs.json";
    uint256 constant AMOUNT = 0;

    /// @notice Tells the Base Safe to bridge AMOUNT USDC back to the Ethereum MerkleAccount. Run on Ethereum.
    function run() public {
        runBase(MANIFEST, PROOFS, AMOUNT);
    }
}
