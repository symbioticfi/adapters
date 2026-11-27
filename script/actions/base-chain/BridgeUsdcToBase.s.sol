// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./base/BridgeUsdcToBaseBase.s.sol";

contract BridgeUsdcToBaseScript is BridgeUsdcToBaseBaseScript {
    string constant MANIFEST = "deployments/base-safe.json";
    string constant PROOFS = "deployments/base-safe-proofs.json";
    uint256 constant AMOUNT = 0;

    /// @notice Bridges AMOUNT USDC from the Ethereum MerkleAccount to the Base Safe. Run on Ethereum.
    function run() public {
        runBase(MANIFEST, PROOFS, AMOUNT);
    }
}
