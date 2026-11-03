// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DeployMerkleBase} from "../adapters/base/DeployMerkleBase.sol";
import {OfficialCRE} from "./OfficialCRE.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {AaveHealthFactor} from "src/contracts/merkle-adapter/automations/health-factors/AaveHealthFactor.sol";
import {EulerHealthFactor} from "src/contracts/merkle-adapter/automations/health-factors/EulerHealthFactor.sol";
import {
    MorphoBlueHealthFactor
} from "src/contracts/merkle-adapter/automations/health-factors/MorphoBlueHealthFactor.sol";
import {AaveV3Liquidity} from "src/contracts/merkle-adapter/automations/liquidity/AaveV3Liquidity.sol";
import {AaveV4Liquidity} from "src/contracts/merkle-adapter/automations/liquidity/AaveV4Liquidity.sol";
import {MorphoLiquidity} from "src/contracts/merkle-adapter/automations/liquidity/MorphoLiquidity.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";
import {ThreeFPolicy} from "src/contracts/merkle-adapter/capabilities/policies/ThreeFPolicy.sol";
import {LiquidLaneConnector} from "src/contracts/merkle-adapter/connectors/LiquidLaneConnector.sol";
import {OracleRegistry} from "src/contracts/merkle-adapter/connectors/OracleRegistry.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @notice Deploys shared Merkle infrastructure without creating a vault, adapter, account or oracle instance.
contract DeployMerkleMainnetScript is DeployMerkleBase {
    address public constant VAULT_FACTORY = 0xAEb6bdd95c502390db8f52c8909F703E9Af6a346;
    // https://docs.3f.xyz/protocol/deployments/?chain=mainnet
    address public constant THREE_F_REQUESTS_FACTORY = 0xDE293185e96a42F4c7d1C6479407920b19012Ca5;
    address public constant THREE_F_FACILITY = 0x4e013ca8fF612a58F53C822904cDD0eC538a4A4F;
    address public constant THREE_F_WHITELIST = 0x3FcD87948cBF46605D6ded0ed56d3daCcd9daf9e;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    struct Infrastructure {
        address recipeCapability;
        address recipeExecutorFactory;
        address policyFactory;
        address oracleRegistry;
        address connectorImplementation;
        address[3] healthFactors;
        address[3] liquidity;
    }

    error InvalidMainnetDependency();
    error ManifestAlreadyExists();

    function run() public returns (Deployment memory deployed) {
        string memory manifest = vm.envString("MERKLE_MANIFEST");
        if (vm.exists(manifest)) revert ManifestAlreadyExists();
        Config memory config = _readConfig();
        address registriesOwner = vm.envAddress("MERKLE_REGISTRIES_OWNER");
        address connectorFactory = vm.envAddress("MERKLE_LL_ADAPTER_FACTORY");
        address reactor = vm.envAddress("MERKLE_LL_REACTOR");
        address protocol = vm.envAddress("MERKLE_LL_PROTOCOL");
        _validate(config, registriesOwner, connectorFactory, reactor, protocol);
        uint256 startBlock = block.number;
        _startBroadcast();
        deployed = _deployCore(config, registriesOwner);
        _stopBroadcast();
        Infrastructure memory infrastructure =
            _deployInfrastructure(config, deployed, connectorFactory, registriesOwner);
        _writeManifest(
            manifest, startBlock, config, registriesOwner, deployed, infrastructure, connectorFactory, reactor, protocol
        );
    }

    /// @notice Deploys helpers without creating protocol positions, roles, workflows or funding approvals.
    function _deployInfrastructure(
        Config memory config,
        Deployment memory deployed,
        address connectorFactory,
        address registriesOwner
    ) internal returns (Infrastructure memory infrastructure) {
        _startBroadcast();
        infrastructure.recipeCapability = address(new RecipeCapability());
        infrastructure.recipeExecutorFactory = address(new ImmutableFactory(type(RecipeExecutor).creationCode));
        infrastructure.healthFactors =
            [address(new AaveHealthFactor()), address(new EulerHealthFactor()), address(new MorphoBlueHealthFactor())];
        infrastructure.liquidity =
            [address(new AaveV3Liquidity()), address(new AaveV4Liquidity()), address(new MorphoLiquidity())];
        infrastructure.policyFactory = address(new MigratablesFactory(_scriptOwner()));
        MigratablesFactory(infrastructure.policyFactory)
            .whitelist(
                address(new ThreeFPolicy(infrastructure.policyFactory, THREE_F_REQUESTS_FACTORY, THREE_F_FACILITY))
            );
        Ownable(infrastructure.policyFactory).transferOwnership(config.provider);
        infrastructure.oracleRegistry = address(new OracleRegistry(registriesOwner));
        infrastructure.connectorImplementation =
            address(new LiquidLaneConnector(connectorFactory, deployed.accountFactory, infrastructure.oracleRegistry));
        _stopBroadcast();
    }

    function _readConfig() internal view returns (Config memory config) {
        config.provider = vm.envAddress("MERKLE_FACTORIES_OWNER");
        config.vaultFactory = VAULT_FACTORY;
        config.forwarder = OfficialCRE.MAINNET_FORWARDER;
        config.chainlinkWorkflowRegistry = OfficialCRE.MAINNET_REGISTRY;
    }

    function _validate(
        Config memory config,
        address registriesOwner,
        address connectorFactory,
        address reactor,
        address protocol
    ) internal view {
        OfficialCRE.validate(1, config.chainlinkWorkflowRegistry, config.forwarder);
        if (
            config.provider == address(0) || registriesOwner == address(0) || VAULT_FACTORY.code.length == 0
                || THREE_F_REQUESTS_FACTORY.code.length == 0 || THREE_F_FACILITY.code.length == 0
                || THREE_F_WHITELIST.code.length == 0 || USDC.code.length == 0 || IERC20Metadata(USDC).decimals() != 6
                || connectorFactory.code.length == 0 || reactor.code.length == 0 || protocol == address(0)
        ) revert InvalidMainnetDependency();
    }

    function _writeManifest(
        string memory path,
        uint256 startBlock,
        Config memory config,
        address registriesOwner,
        Deployment memory deployed,
        Infrastructure memory infrastructure,
        address connectorFactory,
        address reactor,
        address protocol
    ) internal {
        string memory profile = "deployment";
        vm.serializeString(profile, "fromBlock", vm.toString(startBlock));
        vm.serializeAddress(profile, "merkleAdapterFactory", deployed.adapterFactory);
        vm.serializeAddress(profile, "recipeCapability", infrastructure.recipeCapability);
        vm.serializeAddress("health", "aave", infrastructure.healthFactors[0]);
        vm.serializeAddress("health", "euler", infrastructure.healthFactors[1]);
        string memory health = vm.serializeAddress("health", "morphoBlue", infrastructure.healthFactors[2]);
        vm.serializeAddress("liquidity", "aaveV3", infrastructure.liquidity[0]);
        vm.serializeAddress("liquidity", "aaveV4", infrastructure.liquidity[1]);
        string memory liquidity = vm.serializeAddress("liquidity", "morpho", infrastructure.liquidity[2]);
        vm.serializeAddress("threef", "policyFactory", infrastructure.policyFactory);
        string memory threeF = vm.serializeAddress("threef", "requestsFactory", THREE_F_REQUESTS_FACTORY);
        vm.serializeAddress("ll", "connectorFactory", connectorFactory);
        vm.serializeAddress("ll", "reactor", reactor);
        string memory liquidLane = vm.serializeAddress("ll", "protocol", protocol);
        string memory deployment =
            vm.serializeAddress(profile, "recipeExecutorFactory", infrastructure.recipeExecutorFactory);
        vm.serializeString("manifest", "deployment", "");
        vm.serializeUint("manifest", "chainId", 1);
        vm.serializeAddress("manifest", "factoriesOwner", config.provider);
        vm.serializeAddress("manifest", "registriesOwner", registriesOwner);
        vm.serializeAddress("manifest", "vaultFactory", config.vaultFactory);
        vm.serializeAddress("manifest", "rootRegistry", deployed.rootRegistry);
        vm.serializeAddress("manifest", "workflowRegistry", deployed.workflowRegistry);
        vm.serializeAddress("manifest", "accountFactory", deployed.accountFactory);
        vm.serializeAddress("manifest", "oracleFactory", deployed.oracleFactory);
        vm.serializeAddress("manifest", "capabilitiesRegistry", deployed.capabilitiesRegistry);
        vm.serializeAddress("manifest", "chainlinkRegistry", config.chainlinkWorkflowRegistry);
        vm.serializeAddress("manifest", "forwarder", config.forwarder);
        vm.serializeAddress("manifest", "threeFWhitelist", THREE_F_WHITELIST);
        vm.serializeAddress("manifest", "threeFFacility", THREE_F_FACILITY);
        vm.serializeAddress("manifest", "oracleRegistry", infrastructure.oracleRegistry);
        vm.serializeAddress("manifest", "connectorImplementation", infrastructure.connectorImplementation);
        // Existing factory and registry owners submit these calls from their own governance wallets.
        vm.serializeAddress("connectorRegistration", "to", connectorFactory);
        string memory connectorRegistration = vm.serializeBytes(
            "connectorRegistration",
            "data",
            abi.encodeCall(MigratablesFactory.whitelist, (infrastructure.connectorImplementation))
        );
        string memory json = vm.serializeString("manifest", "connectorRegistration", "");
        vm.writeJson(json, path);
        vm.writeJson(deployment, path, ".deployment");
        vm.writeJson(health, path, ".deployment.healthFactors");
        vm.writeJson(liquidity, path, ".deployment.liquidity");
        vm.writeJson(threeF, path, ".deployment.threeF");
        vm.writeJson(liquidLane, path, ".deployment.liquidLane");
        vm.writeJson(connectorRegistration, path, ".connectorRegistration");
    }
}
