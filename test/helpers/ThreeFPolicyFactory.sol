// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ThreeFPolicy} from "src/contracts/merkle-adapter/automations/policies/ThreeFPolicy.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

function createThreeFPolicyFactory(address owner, address requestsFactory, address facility) returns (address factory) {
    factory = address(new MigratablesFactory(owner));
    MigratablesFactory(factory).whitelist(address(new ThreeFPolicy(factory, requestsFactory, facility)));
}

function createThreeFPolicy(address owner, address consumer, address requestsFactory, address facility)
    returns (address)
{
    address factory = createThreeFPolicyFactory(owner, requestsFactory, facility);
    return MigratablesFactory(factory).create(MigratablesFactory(factory).lastVersion(), owner, abi.encode(consumer));
}
