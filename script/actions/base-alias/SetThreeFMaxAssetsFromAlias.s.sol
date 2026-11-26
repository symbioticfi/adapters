// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./base/SetThreeFMaxAssetsFromAliasBase.s.sol";

contract SetThreeFMaxAssetsFromAliasScript is SetThreeFMaxAssetsFromAliasBaseScript {
    string constant MANIFEST = "deployments/base-alias.json";
    string constant PROOFS = "deployments/base-alias-proofs.json";
    address constant UNDERLYING_ASSET = 0x0000000000000000000000000000000000000000;
    uint256 constant MAX_ASSETS = 0;
    uint48 constant DURATION = 0;

    /// @notice Sets the alias policy's USDC budget for UNDERLYING_ASSET to MAX_ASSETS per DURATION. Run on Ethereum.
    function run() public {
        runBase(MANIFEST, PROOFS, UNDERLYING_ASSET, MAX_ASSETS, DURATION);
    }
}
