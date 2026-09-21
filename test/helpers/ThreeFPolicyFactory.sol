// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ThreeFPolicy} from "src/contracts/merkle-adapter/automations/policies/ThreeFPolicy.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

function createThreeFPolicyFactory(address owner) returns (address factory) {
    factory = address(new MigratablesFactory(owner));
    MigratablesFactory(factory).whitelist(address(new ThreeFPolicy(factory)));
}

function createThreeFPolicy(address owner, address consumer) returns (ThreeFPolicy) {
    MigratablesFactory factory = MigratablesFactory(createThreeFPolicyFactory(owner));
    return ThreeFPolicy(factory.create(factory.lastVersion(), owner, abi.encode(consumer)));
}
