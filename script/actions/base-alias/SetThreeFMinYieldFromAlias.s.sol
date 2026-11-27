// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./base/SetThreeFMinYieldFromAliasBase.s.sol";

contract SetThreeFMinYieldFromAliasScript is SetThreeFMinYieldFromAliasBaseScript {
    string constant MANIFEST = "deployments/base-alias.json";
    string constant PROOFS = "deployments/base-alias-proofs.json";
    address constant UNDERLYING_ASSET = 0x0000000000000000000000000000000000000000;
    uint256 constant MINIMUM = 0;

    /// @notice Sets the alias policy's minimum yield (yield ÷ principal × 1e8) for UNDERLYING_ASSET. Run on Ethereum.
    function run() public {
        runBase(MANIFEST, PROOFS, UNDERLYING_ASSET, MINIMUM);
    }
}
