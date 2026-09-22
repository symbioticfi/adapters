// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

function createMerkleAccountFactory(
    address owner,
    address merkleAdapterFactory,
    address rootRegistry,
    address capabilitiesRegistry
) returns (address factory) {
    factory = address(new MigratablesFactory(owner));
    MigratablesFactory(factory)
        .whitelist(address(new MerkleAccount(factory, merkleAdapterFactory, rootRegistry, capabilitiesRegistry)));
}
