// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {DeployMerkleBase} from "./base/DeployMerkleBase.sol";
import {CREOracle} from "src/contracts/merkle-adapter/oracle/CREOracle.sol";

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

import {console2} from "forge-std/console2.sol";

/// @notice Deploys the core Merkle stack with separate provider, curator and role-admin authorities.
contract DeployMerkleAdapterScript is DeployMerkleBase {
    function run() public virtual returns (Deployment memory) {
        return runBase(_readConfig());
    }

    function _readConfig() internal view virtual returns (Config memory) {
        return Config({
            vaultFactory: vm.envAddress("MERKLE_VAULT_FACTORY"),
            vault: vm.envAddress("MERKLE_VAULT"),
            provider: vm.envAddress("MERKLE_PROVIDER"),
            curator: vm.envAddress("MERKLE_CURATOR"),
            admin: vm.envAddress("MERKLE_ADMIN"),
            chainlinkWorkflowRegistry: vm.envOr("MERKLE_CHAINLINK_WORKFLOW_REGISTRY", address(0)),
            forwarder: vm.envOr("MERKLE_FORWARDER", address(0)),
            oracleParams: ICREOracle.InitParams({
                defaultAdminRoleHolder: vm.envAddress("MERKLE_ORACLE_ADMIN"),
                oracleGuardRoleHolder: vm.envAddress("MERKLE_ORACLE_GUARD"),
                oracleLimitsRoleHolder: vm.envAddress("MERKLE_ORACLE_LIMITS"),
                maxOracleGrowth: SafeCast.toUint32(vm.envUint("MERKLE_MAX_ORACLE_GROWTH")),
                maxOracleLoss: SafeCast.toUint32(vm.envUint("MERKLE_MAX_ORACLE_LOSS")),
                oracleTolerance: SafeCast.toUint128(vm.envUint("MERKLE_ORACLE_TOLERANCE"))
            })
        });
    }

    function runBase(Config memory config) public returns (Deployment memory deployed) {
        require(
            config.provider != address(0) && config.curator != address(0) && config.admin != address(0),
            "zero authority"
        );
        require(config.forwarder.code.length > 0, "invalid oracle configuration");
        require(config.chainlinkWorkflowRegistry.code.length > 0, "invalid workflow registry");
        require(
            config.oracleParams.maxOracleGrowth <= ORACLE_LIMIT_PRECISION
                && config.oracleParams.maxOracleLoss <= ORACLE_LIMIT_PRECISION,
            "invalid oracle limits"
        );
        require(IRegistry(config.vaultFactory).isEntity(config.vault), "unregistered vault");
        require(IERC4626(config.vault).asset().code.length > 0, "invalid vault asset");

        _startBroadcast();
        deployed = _deployCore(config);
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
        _assertDeployment(config, deployed, account, oracle);

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

    function _assertDeployment(Config memory config, Deployment memory deployed, address account, address oracle)
        internal
        view
    {
        assert(Ownable(deployed.rootRegistry).owner() == config.provider);
        assert(Ownable(deployed.workflowRegistry).owner() == config.provider);
        assert(CREOracle(oracle).WORKFLOW_REGISTRY() == deployed.workflowRegistry);
        assert(Ownable(deployed.capabilitiesRegistry).owner() == config.provider);
        assert(Ownable(deployed.adapterFactory).owner() == config.provider);
        assert(Ownable(deployed.accountFactory).owner() == config.provider);
        assert(Ownable(deployed.oracleFactory).owner() == config.provider);
        assert(Ownable(deployed.adapter).owner() == config.curator);
        assert(Ownable(account).owner() == config.curator && Ownable(oracle).owner() == config.curator);
        _assertOracle(config, deployed, account, oracle);
    }

    function _assertOracle(Config memory config, Deployment memory deployed, address account, address oracle)
        internal
        view
    {
        ICREOracle.InitParams memory params = config.oracleParams;
        assert(
            CREOracle(oracle).hasRole(bytes32(0), params.defaultAdminRoleHolder)
                == (params.defaultAdminRoleHolder != address(0))
        );
        assert(
            CREOracle(oracle).hasRole(ORACLE_GUARD_ROLE, params.oracleGuardRoleHolder)
                == (params.oracleGuardRoleHolder != address(0))
        );
        assert(
            CREOracle(oracle).hasRole(ORACLE_LIMITS_ROLE, params.oracleLimitsRoleHolder)
                == (params.oracleLimitsRoleHolder != address(0))
        );
        _assertOracleState(config, deployed, account, oracle);
    }

    function _assertOracleState(Config memory config, Deployment memory deployed, address account, address oracle)
        internal
        view
    {
        assert(CREOracle(oracle).maxOracleGrowth() == config.oracleParams.maxOracleGrowth);
        assert(CREOracle(oracle).maxOracleLoss() == config.oracleParams.maxOracleLoss);
        assert(CREOracle(oracle).oracleTolerance() == config.oracleParams.oracleTolerance);
        assert(CREOracle(oracle).FORWARDER() == config.forwarder);
        assert(CREOracle(oracle).snapshotBlock() == 0);
        assert(IMerkleAccount(account).hasRole(bytes32(0), config.admin));
        assert(IMerkleAccount(account).MERKLE_ADAPTER_FACTORY() == deployed.adapterFactory);
        assert(IERC20(IERC4626(config.vault).asset()).allowance(account, deployed.adapter) == type(uint256).max);
    }
}
