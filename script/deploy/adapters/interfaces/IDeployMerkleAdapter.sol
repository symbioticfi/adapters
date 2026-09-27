// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";

/**
 * @title IDeployMerkleAdapter
 * @notice Configuration and deployment results for the Merkle stack deployment script.
 */
interface IDeployMerkleAdapter {
    /**
     * @notice Existing chain dependencies, final authorities and immutable reporting schedule.
     */
    struct Config {
        address vaultFactory;
        address vault;
        address provider;
        address curator;
        address admin;
        address chainlinkWorkflowRegistry;
        uint48 maxReportAge;
        uint48 maxOracleAge;
        uint48 reportInterval;
        ICREOracle.InitParams oracleParams;
    }

    /**
     * @notice Deployed core stack; the adapter exposes its created account and Oracle.
     */
    struct Deployment {
        address rootRegistry;
        address workflowRegistry;
        address capabilitiesRegistry;
        address adapterFactory;
        address accountFactory;
        address oracleFactory;
        address adapter;
    }
}
