// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {DeployAdapterBase} from "./base/DeployAdapterBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {CREWorkflowRegistry} from "src/contracts/merkle-adapter/oracle/CREWorkflowRegistry.sol";
import {CREOracle} from "src/contracts/merkle-adapter/oracle/CREOracle.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";

import {IDeployMerkleAdapter} from "./interfaces/IDeployMerkleAdapter.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {
    ICREOracle,
    ORACLE_GUARD_ROLE,
    ORACLE_LIMITS_ROLE,
    ORACLE_LIMIT_PRECISION
} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IRegistry} from "@symbioticfi/core/src/interfaces/common/IRegistry.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {console2} from "forge-std/console2.sol";

/// @notice Deploys the core Merkle stack with separate provider, curator and role-admin authorities.
contract DeployMerkleAdapterScript is DeployAdapterBase, IDeployMerkleAdapter {
    function run() public returns (Deployment memory) {
        return runBase(
            Config({
                vaultFactory: vm.envAddress("MERKLE_VAULT_FACTORY"),
                vault: vm.envAddress("MERKLE_VAULT"),
                provider: vm.envAddress("MERKLE_PROVIDER"),
                curator: vm.envAddress("MERKLE_CURATOR"),
                admin: vm.envAddress("MERKLE_ADMIN"),
                chainlinkWorkflowRegistry: vm.envAddress("MERKLE_CHAINLINK_WORKFLOW_REGISTRY"),
                maxReportAge: SafeCast.toUint48(vm.envUint("MERKLE_MAX_REPORT_AGE")),
                oracleParams: ICREOracle.InitParams({
                    forwarder: vm.envAddress("MERKLE_FORWARDER"),
                    defaultAdminRoleHolder: vm.envAddress("MERKLE_ORACLE_ADMIN"),
                    oracleGuardRoleHolder: vm.envAddress("MERKLE_ORACLE_GUARD"),
                    oracleLimitsRoleHolder: vm.envAddress("MERKLE_ORACLE_LIMITS"),
                    maxOracleGrowth: SafeCast.toUint32(vm.envUint("MERKLE_MAX_ORACLE_GROWTH")),
                    maxOracleLoss: SafeCast.toUint32(vm.envUint("MERKLE_MAX_ORACLE_LOSS")),
                    oracleTolerance: SafeCast.toUint128(vm.envUint("MERKLE_ORACLE_TOLERANCE"))
                })
            })
        );
    }

    function runBase(Config memory config) public returns (Deployment memory deployed) {
        require(
            config.provider != address(0) && config.curator != address(0) && config.admin != address(0),
            "zero authority"
        );
        require(
            config.oracleParams.forwarder.code.length > 0 && config.maxReportAge > 0, "invalid oracle configuration"
        );
        require(config.chainlinkWorkflowRegistry.code.length > 0, "invalid workflow registry");
        require(
            config.oracleParams.maxOracleGrowth <= ORACLE_LIMIT_PRECISION
                && config.oracleParams.maxOracleLoss <= ORACLE_LIMIT_PRECISION,
            "invalid oracle limits"
        );
        require(IRegistry(config.vaultFactory).isEntity(config.vault), "unregistered vault");
        require(IERC4626(config.vault).asset().code.length > 0, "invalid vault asset");

        _startBroadcast();
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
            .whitelist(address(new CREOracle(deployed.oracleFactory, deployed.workflowRegistry, config.maxReportAge)));
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
        deployed.adapter = AdapterFactory(deployed.adapterFactory)
            .create(
                1,
                config.curator,
                abi.encode(
                    config.vault,
                    abi.encode(
                        IMerkleAdapter.InitParams({
                            oracleData: abi.encode(config.oracleParams),
                            merkleAccountData: abi.encode(
                                IMerkleAccount.InitParams({defaultAdminRoleHolder: config.admin})
                            )
                        })
                    )
                )
            );
        _stopBroadcast();

        address account = IMerkleAdapter(deployed.adapter).account();
        address oracle = IMerkleAdapter(deployed.adapter).oracle();
        assert(Ownable(deployed.rootRegistry).owner() == config.provider);
        assert(Ownable(deployed.workflowRegistry).owner() == config.provider);
        assert(CREOracle(oracle).WORKFLOW_REGISTRY() == deployed.workflowRegistry);
        assert(Ownable(deployed.capabilitiesRegistry).owner() == config.provider);
        assert(Ownable(deployed.adapterFactory).owner() == config.provider);
        assert(Ownable(deployed.accountFactory).owner() == config.provider);
        assert(Ownable(deployed.oracleFactory).owner() == config.provider);
        assert(Ownable(deployed.adapter).owner() == config.curator);
        assert(Ownable(account).owner() == config.curator && Ownable(oracle).owner() == config.curator);
        assert(
            CREOracle(oracle).hasRole(bytes32(0), config.oracleParams.defaultAdminRoleHolder)
                == (config.oracleParams.defaultAdminRoleHolder != address(0))
        );
        assert(
            CREOracle(oracle).hasRole(ORACLE_GUARD_ROLE, config.oracleParams.oracleGuardRoleHolder)
                == (config.oracleParams.oracleGuardRoleHolder != address(0))
        );
        assert(
            CREOracle(oracle).hasRole(ORACLE_LIMITS_ROLE, config.oracleParams.oracleLimitsRoleHolder)
                == (config.oracleParams.oracleLimitsRoleHolder != address(0))
        );
        assert(CREOracle(oracle).maxOracleGrowth() == config.oracleParams.maxOracleGrowth);
        assert(CREOracle(oracle).maxOracleLoss() == config.oracleParams.maxOracleLoss);
        assert(CREOracle(oracle).oracleTolerance() == config.oracleParams.oracleTolerance);
        assert(CREOracle(oracle).forwarder() == config.oracleParams.forwarder);
        assert(CREOracle(oracle).MAX_REPORT_AGE() == config.maxReportAge);
        assert(CREOracle(oracle).snapshotBlock() == 0);
        assert(IMerkleAccount(account).hasRole(bytes32(0), config.admin));
        assert(IMerkleAccount(account).MERKLE_ADAPTER_FACTORY() == deployed.adapterFactory);
        assert(IERC20(IERC4626(config.vault).asset()).allowance(account, deployed.adapter) == type(uint256).max);

        console2.log("Root registry", deployed.rootRegistry);
        console2.log("CRE workflow registry", deployed.workflowRegistry);
        console2.log("Capabilities registry", deployed.capabilitiesRegistry);
        console2.log("Adapter factory", deployed.adapterFactory);
        console2.log("Account factory", deployed.accountFactory);
        console2.log("CREOracle factory", deployed.oracleFactory);
        console2.log("Adapter", deployed.adapter);
        console2.log("Account", account);
        console2.log("CREOracle", oracle);
    }
}
