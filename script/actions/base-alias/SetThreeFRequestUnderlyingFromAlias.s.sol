// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAliasActionBase} from "./base/BaseAliasActionBase.s.sol";
import {BaseAliasPayloads} from "../../base-chain/BaseAliasPayloads.sol";

/// @title SetThreeFRequestUnderlyingFromAlias
/// @notice Registers or revokes a verified Base 3F request on the Ethereum policy.
contract SetThreeFRequestUnderlyingFromAliasScript is BaseAliasActionBase {
    string constant MANIFEST = "deployments/base-alias.json";
    string constant PROOFS = "deployments/base-alias-proofs.json";

    /// @notice Sets the request's Base collateral underlying. Pass zero as the underlying to revoke the request.
    function run(address request, address underlyingAsset) public {
        runBase(MANIFEST, PROOFS, request, underlyingAsset);
    }

    /// @notice Sends the curator's request registration action to the Ethereum MerkleAccount.
    function runBase(string memory manifest, string memory proofs, address request, address underlyingAsset)
        public
        returns (bytes memory data)
    {
        BaseAliasPayloads.Deployment memory deployment = _deployment(manifest);
        return _manage(
            deployment, proofs, _single(BaseAliasPayloads.setRequestUnderlying(deployment, request, underlyingAsset))
        );
    }
}
