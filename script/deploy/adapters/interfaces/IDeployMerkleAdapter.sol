// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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
        address forwarder;
        uint256 maxReportAge;
        uint48 reportInterval;
        uint48 reportBuffer;
    }

    /**
     * @notice Deployed core stack; the adapter exposes its created account and Oracle.
     */
    struct Deployment {
        address rootRegistry;
        address capabilitiesRegistry;
        address adapterFactory;
        address accountFactory;
        address oracleFactory;
        address adapter;
    }
}
