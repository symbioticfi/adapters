// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {AccountRegistry} from "src/contracts/ll-adapter/AccountRegistry.sol";
import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {AppAdapter} from "src/contracts/AppAdapter.sol";
import {ClaimReadiness} from "src/contracts/merkle-adapter/automations/ClaimReadiness.sol";
import {DeployRealisticTestnetScript} from "./DeployRealisticTestnet.s.sol";
import {LiquidLaneAdapter} from "src/contracts/LiquidLaneAdapter.sol";
import {LiquidLaneConnector} from "src/contracts/merkle-adapter/connectors/LiquidLaneConnector.sol";
import {OracleRegistry} from "src/contracts/merkle-adapter/connectors/OracleRegistry.sol";
import {RestakingAppAdapter} from "src/contracts/RestakingAppAdapter.sol";
import {SepoliaInfrastructure} from "./SepoliaInfrastructure.sol";
import {TestnetMerkleScript} from "./base/TestnetMerkle.s.sol";
import {ThreeFAdapter} from "src/contracts/ThreeFAdapter.sol";
import {ThreeFPolicy} from "src/contracts/merkle-adapter/capabilities/policies/ThreeFPolicy.sol";

import {IDeployMerkleAdapter} from "../adapters/interfaces/IDeployMerkleAdapter.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Script, console2} from "forge-std/Script.sol";

import {Reactor} from "test/mocks/liquid-lane-redeem/Reactor.sol";

/// @notice Reuses the full stand's infrastructure and empty venue builders without configuring accounts.
contract SepoliaBasisBuilder is DeployRealisticTestnetScript {
    bool internal immutable _BROADCAST;

    constructor(bool newBroadcast) {
        _BROADCAST = newBroadcast;
    }

    function build(address owner)
        public
        returns (Deployment memory deployed, address[4] memory factories, uint256 threeFFirstRequest)
    {
        if (block.chainid != SepoliaInfrastructure.CHAIN_ID) revert InvalidConfiguration();
        threeFFirstRequest = _threeFFirstRequest();
        Config memory config = Config({owner: owner, seedAssets: 0});
        deployed = _infrastructure(config);
        deployed.markets = new Market[](7);
        for (uint256 i; i < deployed.markets.length; ++i) {
            deployed.markets[i] = _venue(config, deployed, i);
            _start(owner);
            deployed.markets[i].rwas = _rwas(config, deployed, deployed.markets[i], i, false);
            _stop();
        }
        _start(owner);
        for (uint256 i; i < factories.length; ++i) {
            factories[i] = _adapter(deployed, deployed.markets[0], owner, i, false);
        }
        _stop();
    }

    function _broadcast() internal view override returns (bool) {
        return _BROADCAST;
    }
}

/// @notice Deploys a fresh Sepolia basis with no Symbiotic vaults, portfolio accounts, oracle instances or positions.
contract DeploySepoliaBasisScript is Script {
    struct Deployment {
        DeployRealisticTestnetScript.Deployment basis;
        IDeployMerkleAdapter.Deployment merkle;
        address connectorFactory;
        address connectorImplementation;
        address oracleRegistry;
        address policyFactory;
        address policyImplementation;
        address claimReadiness;
        address[8] adapterFactories;
        address accountRegistry;
        address reactor;
        uint256 threeFFirstRequest;
    }

    error ManifestAlreadyExists();

    function run() public returns (Deployment memory deployed) {
        string memory path = vm.envString("TESTNET_MANIFEST");
        if (vm.exists(path)) revert ManifestAlreadyExists();
        (,, address origin) = vm.readCallers();
        deployed = runBase(vm.envOr("TESTNET_OWNER", origin));
        writeManifest(deployed, path);
    }

    function runBase(address owner) public returns (Deployment memory deployed) {
        address[4] memory lendingFactories;
        (deployed.basis, lendingFactories, deployed.threeFFirstRequest) =
            SepoliaBasisBuilder(address(new SepoliaBasisBuilder(_broadcast()))).build(owner);
        for (uint256 i; i < lendingFactories.length; ++i) {
            deployed.adapterFactories[i] = lendingFactories[i];
        }
        IDeployMerkleAdapter.Config memory config;
        config.provider = owner;
        config.vaultFactory = deployed.basis.vaultFactory;
        config.chainlinkWorkflowRegistry = deployed.basis.chainlinkRegistry;
        config.forwarder = deployed.basis.forwarder;
        deployed.merkle = TestnetMerkleScript(address(new TestnetMerkleScript(owner, _broadcast()))).deployCore(config);
        if (_broadcast()) vm.startBroadcast(owner);
        else vm.startPrank(owner, owner);
        deployed.claimReadiness = address(new ClaimReadiness());
        deployed.oracleRegistry = address(new OracleRegistry(owner));
        deployed.accountRegistry = address(new AccountRegistry(owner));
        for (uint256 i; i < deployed.basis.markets.length; ++i) {
            for (uint256 j; j < deployed.basis.markets[i].rwas.length; ++j) {
                DeployRealisticTestnetScript.RWA memory rwa = deployed.basis.markets[i].rwas[j];
                AccountRegistry(deployed.accountRegistry)
                    .setAccountFactory(deployed.basis.markets[i].asset, rwa.token, rwa.accountFactory);
            }
        }
        for (uint256 i = 4; i < deployed.adapterFactories.length; ++i) {
            address factory = address(new AdapterFactory(owner));
            deployed.adapterFactories[i] = factory;
            address implementation = i == 4
                ? address(new LiquidLaneAdapter(deployed.basis.vaultFactory, factory, deployed.accountRegistry))
                : i == 5
                    ? address(new ThreeFAdapter(deployed.basis.vaultFactory, factory, SepoliaInfrastructure.WHITELIST))
                    : i == 6
                        ? address(
                            new AppAdapter(
                                deployed.basis.vaultFactory,
                                factory,
                                deployed.basis.cowSettlement,
                                deployed.basis.networkMiddlewareService
                            )
                        )
                        : address(
                            new RestakingAppAdapter(
                                deployed.basis.vaultFactory,
                                factory,
                                deployed.basis.cowSettlement,
                                deployed.basis.networkMiddlewareService
                            )
                        );
            AdapterFactory(factory).whitelist(implementation);
        }
        deployed.connectorFactory = deployed.adapterFactories[4];
        deployed.reactor = address(new Reactor(deployed.connectorFactory));
        deployed.connectorImplementation = address(
            new LiquidLaneConnector(deployed.connectorFactory, deployed.merkle.accountFactory, deployed.oracleRegistry)
        );
        MigratablesFactory(deployed.connectorFactory).whitelist(deployed.connectorImplementation);
        deployed.policyFactory = address(new MigratablesFactory(owner));
        deployed.policyImplementation = address(
            new ThreeFPolicy(
                deployed.policyFactory, SepoliaInfrastructure.REQUESTS_FACTORY, SepoliaInfrastructure.FACILITY
            )
        );
        MigratablesFactory(deployed.policyFactory).whitelist(deployed.policyImplementation);
        if (_broadcast()) vm.stopBroadcast();
        else vm.stopPrank();
    }

    function writeManifest(Deployment memory deployed, string memory path) public {
        string memory key = "sepolia-basis";
        DeployRealisticTestnetScript.Deployment memory basis = deployed.basis;
        vm.serializeUint(key, "schemaVersion", 1);
        vm.serializeString(key, "infrastructure", "sepolia-basis");
        vm.serializeUint(key, "chainId", basis.chainId);
        vm.serializeUint(key, "startBlock", basis.startBlock);
        vm.serializeUint(key, "creRegistrationChainId", 1);
        vm.serializeUint(key, "threeFFirstRequest", deployed.threeFFirstRequest);
        vm.serializeUint(key, "threeFBaselineBlock", basis.startBlock);
        vm.serializeBytes32(key, "upstreamPins", sha256(bytes(vm.readFile("script/deploy/testnet/upstream/pins.json"))));
        vm.serializeAddress(key, "owner", basis.owner);
        vm.serializeAddress(key, "vaultFactory", basis.vaultFactory);
        vm.serializeAddress(key, "adapterRegistry", basis.adapterRegistry);
        vm.serializeAddress(key, "universalDelegatorFactory", basis.universalDelegatorFactory);
        vm.serializeAddress(key, "withdrawalQueueFactory", basis.withdrawalQueueFactory);
        vm.serializeAddress(key, "protocolFeeRegistry", basis.protocolFeeRegistry);
        vm.serializeAddress(key, "networkRegistry", basis.networkRegistry);
        vm.serializeAddress(key, "operatorRegistry", basis.operatorRegistry);
        vm.serializeAddress(key, "networkMiddlewareService", basis.networkMiddlewareService);
        vm.serializeAddress(key, "delegatorFactory", basis.coreServices[0]);
        vm.serializeAddress(key, "slasherFactory", basis.coreServices[1]);
        vm.serializeAddress(key, "vaultConfigurator", basis.coreServices[2]);
        vm.serializeAddress(key, "operatorMetadataService", basis.coreServices[3]);
        vm.serializeAddress(key, "networkMetadataService", basis.coreServices[4]);
        vm.serializeAddress(key, "operatorVaultOptInService", basis.coreServices[5]);
        vm.serializeAddress(key, "operatorNetworkOptInService", basis.coreServices[6]);
        vm.serializeAddress(key, "rootRegistry", deployed.merkle.rootRegistry);
        vm.serializeAddress(key, "workflowRegistry", deployed.merkle.workflowRegistry);
        vm.serializeAddress(key, "capabilitiesRegistry", deployed.merkle.capabilitiesRegistry);
        vm.serializeAddress(key, "merkleAdapterFactory", deployed.merkle.adapterFactory);
        vm.serializeAddress(key, "accountFactory", deployed.merkle.accountFactory);
        vm.serializeAddress(key, "oracleFactory", deployed.merkle.oracleFactory);
        vm.serializeAddress(key, "chainlinkRegistry", basis.chainlinkRegistry);
        vm.serializeString(key, "chainlinkRegistryLabel", "Sepolia replica of the upstream Workflow Registry");
        vm.serializeAddress(key, "forwarder", basis.forwarder);
        vm.serializeAddress(key, "collateral", basis.collateral);
        vm.serializeAddress(key, "collateralFeed", basis.collateralFeed);
        vm.serializeAddress(key, "merklDistributor", basis.merkl);
        vm.serializeAddress(key, "cowSettlement", basis.cowSettlement);
        vm.serializeAddress(key, "recipeCapabilityFactory", basis.immutableFactory);
        vm.serializeAddress(key, "recipeCapability", basis.recipeCapability);
        vm.serializeAddress(key, "recipeExecutorFactory", basis.recipeExecutorFactory);
        vm.serializeAddress(key, "connectorFactory", deployed.connectorFactory);
        vm.serializeAddress(key, "connectorImplementation", deployed.connectorImplementation);
        vm.serializeAddress(key, "oracleRegistry", deployed.oracleRegistry);
        vm.serializeAddress(key, "policyFactory", deployed.policyFactory);
        vm.serializeAddress(key, "policyImplementation", deployed.policyImplementation);
        vm.serializeAddress(key, "threeFRequestsFactory", SepoliaInfrastructure.REQUESTS_FACTORY);
        vm.serializeAddress(key, "threeFFacility", SepoliaInfrastructure.FACILITY);
        vm.serializeAddress(key, "threeFWhitelist", SepoliaInfrastructure.WHITELIST);
        vm.serializeAddress(key, "threeFUSDC", SepoliaInfrastructure.USDC);
        vm.serializeAddress(key, "claimReadiness", deployed.claimReadiness);
        vm.serializeAddress(key, "aaveHealthFactorReader", basis.readers[0]);
        vm.serializeAddress(key, "eulerHealthFactorReader", basis.readers[1]);
        vm.serializeAddress(key, "morphoBlueHealthFactorReader", basis.readers[2]);
        vm.serializeAddress(key, "morphoMidnightHealthFactorReader", basis.readers[3]);
        vm.serializeAddress(key, "aaveV3LiquidityReader", basis.readers[4]);
        vm.serializeAddress(key, "aaveV4LiquidityReader", basis.readers[5]);
        vm.serializeAddress(key, "morphoLiquidityReader", basis.readers[6]);
        vm.serializeAddress(key, "aaveAdapterFactory", deployed.adapterFactories[0]);
        vm.serializeAddress(key, "eulerAdapterFactory", deployed.adapterFactories[1]);
        vm.serializeAddress(key, "morphoAdapterFactory", deployed.adapterFactories[2]);
        vm.serializeAddress(key, "erc4626AdapterFactory", deployed.adapterFactories[3]);
        vm.serializeAddress(key, "liquidLaneAdapterFactory", deployed.adapterFactories[4]);
        vm.serializeAddress(key, "threeFAdapterFactory", deployed.adapterFactories[5]);
        vm.serializeAddress(key, "appAdapterFactory", deployed.adapterFactories[6]);
        vm.serializeAddress(key, "restakingAdapterFactory", deployed.adapterFactories[7]);
        vm.serializeAddress(key, "accountRegistry", deployed.accountRegistry);
        vm.serializeAddress(key, "reactor", deployed.reactor);
        vm.serializeAddress(key, "protocol", basis.owner);
        vm.serializeAddress(key, "aaveProvider", basis.aave.provider);
        vm.serializeAddress(key, "aavePool", basis.aave.pool);
        vm.serializeAddress(key, "aaveDataProvider", basis.aave.dataProvider);
        vm.serializeAddress(key, "aaveOracle", basis.aave.oracle);
        vm.serializeAddress(key, "aaveV4Hub", basis.aave.hub);
        vm.serializeAddress(key, "aaveV4Spoke", basis.aave.spoke);
        vm.serializeAddress(key, "eulerEVC", basis.euler.evc);
        vm.serializeAddress(key, "eulerFactory", basis.euler.factory);
        vm.serializeAddress(key, "eulerOracle", basis.euler.oracle);
        vm.serializeAddress(key, "eulerCollateralVault", basis.euler.collateralVault);
        vm.serializeAddress(key, "morphoBlue", basis.morpho.blue);
        vm.serializeAddress(key, "morphoFactory", basis.morpho.vaultFactory);
        vm.serializeAddress(key, "morphoRegistry", basis.morpho.registry);
        vm.serializeAddress(key, "morphoAllocationFactory", basis.morpho.allocationFactory);
        vm.serializeAddress(key, "morphoInterestRateModel", basis.morpho.irm);
        string memory json = vm.serializeAddress(key, "vaults", new address[](0));
        vm.writeJson(json, path);
        string memory venues = "[";
        for (uint256 i; i < basis.markets.length; ++i) {
            DeployRealisticTestnetScript.Market memory venue = basis.markets[i];
            string memory row = string.concat("basis-venue-", vm.toString(i));
            vm.serializeAddress(row, "asset", venue.asset);
            vm.serializeString(row, "symbol", IERC20Metadata(venue.asset).symbol());
            vm.serializeUint(row, "decimals", IERC20Metadata(venue.asset).decimals());
            vm.serializeAddress(row, "assetFeed", venue.assetFeed);
            vm.serializeUint(row, "aaveV4ReserveId", venue.aaveV4ReserveId);
            vm.serializeAddress(row, "eulerVault", venue.euler);
            vm.serializeAddress(row, "morphoVault", venue.morpho);
            vm.serializeAddress(row, "morphoAllocation", venue.morphoAllocation);
            vm.serializeAddress(row, "erc4626Vault", venue.erc4626);
            vm.serializeAddress(row, "collateralOracle", venue.nativeLending.oracle);
            vm.serializeBytes32(row, "morphoBlueMarketId", venue.nativeLending.blueId);
            string memory encoded = vm.serializeBytes(row, "morphoBlueParams", venue.nativeLending.blueParams);
            venues = string.concat(venues, i == 0 ? "" : ",", encoded);
        }
        vm.writeJson(string.concat(venues, "]"), path, ".venues");
        string memory rwas = "[";
        uint256 count;
        for (uint256 i; i < basis.markets.length; ++i) {
            for (uint256 j; j < basis.markets[i].rwas.length; ++j) {
                DeployRealisticTestnetScript.RWA memory rwa = basis.markets[i].rwas[j];
                string memory row = string.concat("basis-rwa-", vm.toString(rwa.profile));
                vm.serializeUint(row, "profile", rwa.profile);
                vm.serializeString(row, "symbol", rwa.symbol);
                vm.serializeAddress(row, "asset", basis.markets[i].asset);
                vm.serializeAddress(row, "token", rwa.token);
                vm.serializeUint(row, "decimals", IERC20Metadata(rwa.token).decimals());
                vm.serializeUint(row, "mechanism", rwa.mechanism);
                vm.serializeAddress(row, "oracle", rwa.oracle);
                vm.serializeAddress(row, "feed", rwa.feed);
                vm.serializeAddress(row, "redemption", rwa.redemption);
                string memory encoded = vm.serializeAddress(row, "accountFactory", rwa.accountFactory);
                rwas = string.concat(rwas, count++ == 0 ? "" : ",", encoded);
            }
        }
        vm.writeJson(string.concat(rwas, "]"), path, ".rwas");
        console2.log("Sepolia infrastructure-only manifest", path);
        console2.log("Workflow registry / mainnet registration owner", deployed.merkle.workflowRegistry);
    }

    function _broadcast() internal view virtual returns (bool) {
        return true;
    }
}
