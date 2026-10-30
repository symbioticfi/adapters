// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {DeployAdapterBase} from "./DeployAdapterBase.sol";
import {IDeployMerkleAdapter} from "../interfaces/IDeployMerkleAdapter.sol";
import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {CREWorkflowRegistry} from "src/contracts/merkle-adapter/oracle/CREWorkflowRegistry.sol";
import {CREOracle} from "src/contracts/merkle-adapter/oracle/CREOracle.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

abstract contract DeployMerkleBase is DeployAdapterBase, IDeployMerkleAdapter {
    /// @dev Shared infrastructure only; individual accounts and oracles are created with an adapter.
    function _deployCore(Config memory config) internal returns (Deployment memory deployed) {
        deployed.rootRegistry = address(new RootRegistry(config.provider));
        deployed.workflowRegistry = address(new CREWorkflowRegistry(config.provider, config.chainlinkWorkflowRegistry));
        deployed.capabilitiesRegistry = address(new CapabilitiesRegistry(config.provider));
        deployed.adapterFactory = _deployAdapterFactory();
        deployed.accountFactory = address(new MigratablesFactory(_scriptOwner()));
        deployed.oracleFactory = address(new MigratablesFactory(_scriptOwner()));
        MigratablesFactory(deployed.accountFactory)
            .whitelist(
                address(
                    new MerkleAccount(
                        deployed.accountFactory,
                        deployed.adapterFactory,
                        deployed.rootRegistry,
                        deployed.capabilitiesRegistry
                    )
                )
            );
        MigratablesFactory(deployed.oracleFactory)
            .whitelist(address(new CREOracle(deployed.oracleFactory, deployed.workflowRegistry, config.forwarder)));
        AdapterFactory(deployed.adapterFactory)
            .whitelist(
                address(
                    new MerkleAdapter(
                        config.vaultFactory, deployed.adapterFactory, deployed.oracleFactory, deployed.accountFactory
                    )
                )
            );
        Ownable(deployed.adapterFactory).transferOwnership(config.provider);
        Ownable(deployed.accountFactory).transferOwnership(config.provider);
        Ownable(deployed.oracleFactory).transferOwnership(config.provider);
    }
}
