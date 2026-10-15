// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {AaveHealthFactor} from "src/contracts/merkle-adapter/automations/health-factors/AaveHealthFactor.sol";
import {AaveV3Adapter} from "src/contracts/AaveV3Adapter.sol";
import {AaveV3Liquidity} from "src/contracts/merkle-adapter/automations/liquidity/AaveV3Liquidity.sol";
import {AaveV4Liquidity} from "src/contracts/merkle-adapter/automations/liquidity/AaveV4Liquidity.sol";
import {AccountRegistry} from "src/contracts/ll-adapter/AccountRegistry.sol";
import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {AppAdapter} from "src/contracts/AppAdapter.sol";
import {AsyncRedeemOracle} from "src/contracts/ll-adapter/oracles/AsyncRedeemOracle.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {ERC4626Account} from "src/contracts/ll-adapter/ERC4626Account.sol";
import {ERC4626Adapter} from "src/contracts/ERC4626Adapter.sol";
import {ERC4626Oracle} from "src/contracts/ll-adapter/oracles/ERC4626Oracle.sol";
import {EulerAdapter} from "src/contracts/EulerAdapter.sol";
import {EulerHealthFactor} from "src/contracts/merkle-adapter/automations/health-factors/EulerHealthFactor.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {LiquidLaneAdapter} from "src/contracts/LiquidLaneAdapter.sol";
import {LiquidLaneConnector} from "src/contracts/merkle-adapter/connectors/LiquidLaneConnector.sol";
import {MidasCompAccount, MidasNonCompAccount, CutoffMidasAccount} from "src/contracts/ll-adapter/MidasAccount.sol";
import {MidasOracle} from "src/contracts/ll-adapter/oracles/MidasOracle.sol";
import {
    MorphoBlueHealthFactor
} from "src/contracts/merkle-adapter/automations/health-factors/MorphoBlueHealthFactor.sol";
import {MorphoLiquidity} from "src/contracts/merkle-adapter/automations/liquidity/MorphoLiquidity.sol";
import {
    MorphoMidnightHealthFactor
} from "src/contracts/merkle-adapter/automations/health-factors/MorphoMidnightHealthFactor.sol";
import {MorphoVaultV2Adapter} from "src/contracts/MorphoVaultV2Adapter.sol";
import {OracleRegistry} from "src/contracts/merkle-adapter/connectors/OracleRegistry.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {RestakingAppAdapter} from "src/contracts/RestakingAppAdapter.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";
import {SepoliaInfrastructure} from "./SepoliaInfrastructure.sol";
import {TestnetAavePool, TestnetCreditVault, TestnetLendingRegistry} from "./protocols/TestnetLending.sol";
import {TestnetAssetoFactory} from "./protocols/TestnetAssetoFactory.sol";
import {TestnetAsyncAccount} from "./protocols/TestnetAsyncAccount.sol";
import {TestnetCatalog} from "./catalog/TestnetCatalog.sol";
import {TestnetCoreScript, TestnetV2Script} from "./base/TestnetCore.s.sol";
import {TestnetEthDeploymentScript, TestnetWETH} from "./protocols/TestnetEthRedemptions.sol";
import {TestnetMerklDistributor, TestnetCowSettlement, TestnetBurner} from "./protocols/TestnetServices.sol";
import {TestnetMerkleScript} from "./base/TestnetMerkle.s.sol";
import {TestnetMidasRedemptionVault, TestnetAsyncVault} from "./protocols/TestnetRedemptions.sol";
import {TestnetNativeLendingScript} from "./protocols/TestnetNativeLending.sol";
import {TestnetPermissions} from "./TestnetPermissions.sol";
import {TestnetProviderDeploymentScript} from "./protocols/TestnetProviderRedemptions.sol";
import {TestnetThreeFFacility, TestnetThreeFRequest} from "./protocols/TestnetThreeF.sol";
import {TestnetToken, TestnetPriceFeed} from "./protocols/TestnetAssets.sol";
import {
    TestnetYieldDeploymentScript,
    TestnetParetoQueue,
    TestnetParetoCDO
} from "./protocols/TestnetYieldRedemptions.sol";
import {ThreeFAdapter} from "src/contracts/ThreeFAdapter.sol";
import {ThreeFPolicy} from "src/contracts/merkle-adapter/capabilities/policies/ThreeFPolicy.sol";

import {IAaveV3Adapter} from "src/interfaces/IAaveV3Adapter.sol";
import {IAppAdapter} from "src/interfaces/IAppAdapter.sol";
import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {IERC4626Adapter} from "src/interfaces/IERC4626Adapter.sol";
import {IEulerAdapter} from "src/interfaces/IEulerAdapter.sol";
import {ILiquidLaneAdapter} from "src/interfaces/ILiquidLaneAdapter.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IMorphoVaultV2Adapter} from "src/interfaces/IMorphoVaultV2Adapter.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {IRecipes, OP_APPROVE, OP_MANAGE, SRC_INPUT} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {IRestakingAppAdapter} from "src/interfaces/IRestakingAppAdapter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {DeployCoreBaseScript} from "@symbioticfi/core/script/deploy/base/DeployCoreBase.s.sol";
import {DeployV2BaseScript} from "@symbioticfi/core/script/deploy/base/DeployV2Base.s.sol";
import {IAdapterRegistry} from "@symbioticfi/core/src/interfaces/IAdapterRegistry.sol";
import {INetworkMiddlewareService} from "@symbioticfi/core/src/interfaces/service/INetworkMiddlewareService.sol";
import {INetworkRegistry} from "@symbioticfi/core/src/interfaces/INetworkRegistry.sol";
import {IOperatorRegistry} from "@symbioticfi/core/src/interfaces/IOperatorRegistry.sol";
import {IOptInService} from "@symbioticfi/core/src/interfaces/service/IOptInService.sol";
import {IUniversalDelegator, MAX_SHARE} from "@symbioticfi/core/src/interfaces/delegator/IUniversalDelegator.sol";
import {IVaultV2, VAULT_V2_VERSION} from "@symbioticfi/core/src/interfaces/vault/IVaultV2.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";
import {SymbioticCoreConstants} from "@symbioticfi/core/test/integration/SymbioticCoreConstants.sol";
import {VaultFactory} from "@symbioticfi/core/src/contracts/VaultFactory.sol";

import {ThreeFGuardedMint} from "script/recipes/ThreeFGuardedMint.sol";

import {Script, console2} from "forge-std/Script.sol";

import {IDeployMerkleAdapter} from "script/deploy/adapters/interfaces/IDeployMerkleAdapter.sol";

import {KeystoneForwarder} from "test/mocks/chainlink-cre/KeystoneForwarder.sol";
import {Reactor} from "test/mocks/liquid-lane-redeem/Reactor.sol";
import {WorkflowRegistry} from "test/mocks/chainlink-cre/WorkflowRegistry.sol";

/// @title DeployRealisticTestnetScript
/// @notice Deploys fresh core, current adapters, complete Merkle infrastructure and funded protocol models.
/// @dev Deployment, workflow activation, reports and funding are separate phases to preserve completed-block NAV.
contract DeployRealisticTestnetScript is Script {
    using Strings for uint256;

    error InvalidConfiguration();

    struct Config {
        address owner;
        uint256 seedAssets;
    }

    struct RWA {
        uint256 profile;
        string symbol;
        address oracle;
        address token;
        address feed;
        address redemption;
        address accountFactory;
        uint8 mechanism;
    }

    struct Market {
        address asset;
        address vault;
        address delegator;
        address aave;
        address euler;
        address morpho;
        address erc4626;
        TestnetNativeLendingScript.Deployment nativeLending;
        address aaveAdapter;
        address eulerAdapter;
        address morphoAdapter;
        address erc4626Adapter;
        address liquidLaneAdapter;
        address threeFAdapter;
        address appAdapter;
        address restakingVault;
        address restakingDelegator;
        address restakingAdapter;
        address accountRegistry;
        address reactor;
        address threeF;
        address request;
        IDeployMerkleAdapter.Deployment merkle;
        address connectorFactory;
        address connector;
        address oracleRegistry;
        address policyFactory;
        address policy;
        address executor;
        RWA[] rwas;
        IMerkleAccount.Action[] actions;
        bytes[] recipe;
    }

    struct Deployment {
        uint256 chainId;
        uint256 startBlock;
        address owner;
        uint256 seedAssets;
        address vaultFactory;
        address adapterRegistry;
        address universalDelegatorFactory;
        address withdrawalQueueFactory;
        address protocolFeeRegistry;
        address networkRegistry;
        address operatorRegistry;
        address networkMiddlewareService;
        address[7] coreServices;
        address collateral;
        address merkl;
        address cowSettlement;
        address chainlinkRegistry;
        address forwarder;
        address immutableFactory;
        address recipeCapability;
        address[7] readers;
        Market[] markets;
    }

    function run() public returns (Deployment memory deployed) {
        (,, address origin) = vm.readCallers();
        Config memory config = Config({
            owner: vm.envOr("TESTNET_OWNER", origin), seedAssets: vm.envOr("TESTNET_SEED_ASSETS", uint256(5_000_000))
        });
        deployed = runBase(config);
        writeManifest(deployed, vm.envOr("TESTNET_MANIFEST", string("script/deploy/testnet/manifests/realistic.json")));
    }

    function runBase(Config memory config) public returns (Deployment memory deployed) {
        if (config.owner == address(0) || config.seedAssets == 0) {
            revert InvalidConfiguration();
        }
        deployed.chainId = block.chainid;
        deployed.startBlock = block.number;
        deployed.owner = config.owner;
        deployed.seedAssets = config.seedAssets;
        // Resolve external infrastructure before deploying any core contracts.
        if (block.chainid == SepoliaInfrastructure.CHAIN_ID) {
            deployed.chainlinkRegistry = vm.envOr("TESTNET_CHAINLINK_REGISTRY", SepoliaInfrastructure.WORKFLOW_REGISTRY);
            SepoliaInfrastructure.validate(deployed.chainlinkRegistry);
            deployed.forwarder = SepoliaInfrastructure.FORWARDER;
        } else if (block.chainid != 31_337 && block.chainid != 1337) {
            revert InvalidConfiguration();
        }
        DeployCoreBaseScript.CoreDeploymentData memory core =
            new TestnetCoreScript(config.owner, _broadcast()).run(config.owner);
        SymbioticCoreConstants.Core memory localCore = abi.decode(
            abi.encode(
                address(core.vaultFactory),
                address(core.delegatorFactory),
                address(core.slasherFactory),
                address(core.networkRegistry),
                address(core.networkMetadataService),
                address(core.networkMiddlewareService),
                address(core.operatorRegistry),
                address(core.operatorMetadataService),
                address(core.operatorVaultOptInService),
                address(core.operatorNetworkOptInService),
                address(core.vaultConfigurator)
            ),
            (SymbioticCoreConstants.Core)
        );
        DeployV2BaseScript.DeploymentData memory v2 =
            new TestnetV2Script(config.owner, _broadcast(), localCore).runBase(config.owner);
        deployed.vaultFactory = address(core.vaultFactory);
        deployed.adapterRegistry = address(v2.adapterRegistry);
        deployed.universalDelegatorFactory = address(v2.universalDelegatorFactory);
        deployed.withdrawalQueueFactory = address(v2.withdrawalQueueFactory);
        deployed.protocolFeeRegistry = address(v2.protocolFeeRegistry);
        deployed.networkRegistry = address(core.networkRegistry);
        deployed.operatorRegistry = address(core.operatorRegistry);
        deployed.networkMiddlewareService = address(core.networkMiddlewareService);
        deployed.coreServices = [
            address(core.delegatorFactory),
            address(core.slasherFactory),
            address(core.vaultConfigurator),
            address(core.operatorMetadataService),
            address(core.networkMetadataService),
            address(core.operatorVaultOptInService),
            address(core.operatorNetworkOptInService)
        ];
        _start(config.owner);
        INetworkRegistry(deployed.networkRegistry).registerNetwork();
        IOperatorRegistry(deployed.operatorRegistry).registerOperator();
        INetworkMiddlewareService(deployed.networkMiddlewareService).setMiddleware(config.owner);
        IOptInService(deployed.coreServices[6]).optIn(config.owner);
        VaultFactory(deployed.vaultFactory).whitelist(address(v2.vaultV2));
        deployed.collateral = address(new TestnetToken("Testnet credit collateral", "tCOLL", 18, config.owner));
        deployed.merkl = address(new TestnetMerklDistributor(config.owner));
        deployed.cowSettlement = address(new TestnetCowSettlement());
        if (block.chainid != SepoliaInfrastructure.CHAIN_ID) {
            deployed.chainlinkRegistry = address(new WorkflowRegistry());
            address[] memory signers = new address[](1);
            signers[0] = config.owner;
            WorkflowRegistry(deployed.chainlinkRegistry).updateAllowedSigners(signers, true);
            WorkflowRegistry(deployed.chainlinkRegistry).setDONLimit("testnet", 100, 100);
            deployed.forwarder = address(new KeystoneForwarder());
            KeystoneForwarder(deployed.forwarder).addForwarder(config.owner);
        }
        deployed.immutableFactory = address(new ImmutableFactory(type(RecipeCapability).creationCode));
        deployed.recipeCapability = ImmutableFactory(deployed.immutableFactory).create("");
        deployed.readers = [
            address(new AaveHealthFactor()),
            address(new EulerHealthFactor()),
            address(new MorphoBlueHealthFactor()),
            address(new MorphoMidnightHealthFactor()),
            address(new AaveV3Liquidity()),
            address(new AaveV4Liquidity()),
            address(new MorphoLiquidity())
        ];
        _stop();
        deployed.markets = new Market[](7);
        for (uint256 i; i < deployed.markets.length; ++i) {
            deployed.markets[i] = _market(config, deployed, i);
            _start(config.owner);
            IOptInService(deployed.coreServices[5]).optIn(deployed.markets[i].vault);
            IOptInService(deployed.coreServices[5]).optIn(deployed.markets[i].restakingVault);
            _stop();
        }
        console2.log("Testnet core factory", deployed.vaultFactory);
        console2.log("Testnet workflow registry", deployed.chainlinkRegistry);
        console2.log("Testnet forwarder", deployed.forwarder);
    }

    function _market(Config memory config, Deployment memory deployed, uint256 index)
        internal
        returns (Market memory market)
    {
        _start(config.owner);
        string[7] memory symbols = ["USDC", "aUSD", "tBTC", "WBTC", "cbBTC", "WETH", "USDT"];
        market.asset = block.chainid == SepoliaInfrastructure.CHAIN_ID && index == 0
            ? SepoliaInfrastructure.USDC
            : index == 5
                ? address(new TestnetWETH())
                : address(
                    new TestnetToken(
                        string.concat("Testnet ", symbols[index]),
                        symbols[index],
                        index == 0 || index == 6 ? 6 : index == 3 || index == 4 ? 8 : 18,
                        config.owner
                    )
                );
        market.vault = VaultFactory(deployed.vaultFactory)
            .create(VAULT_V2_VERSION, config.owner, _vaultParams(config.owner, market.asset, index));
        market.delegator = IVaultV2(market.vault).delegator();
        market.aave = address(new TestnetAavePool(market.asset, config.owner));
        TestnetAavePool(market.aave).setAssetPrice(assetPrice(index) / 1e10);
        address registry = address(new TestnetLendingRegistry(config.owner));
        market.euler = address(
            new TestnetCreditVault(
                market.asset, deployed.collateral, config.owner, registry, "Testnet Euler", "eTEST", 8e16
            )
        );
        market.morpho = address(
            new TestnetCreditVault(
                market.asset, deployed.collateral, config.owner, registry, "Testnet Morpho V2", "mTEST", 6e16
            )
        );
        market.erc4626 = address(
            new TestnetCreditVault(
                market.asset, deployed.collateral, config.owner, registry, "Testnet yield vault", "sTEST", 5e16
            )
        );
        TestnetCreditVault(market.euler).setRisk(3000e36 / assetPrice(index), 7500, 8000);
        TestnetCreditVault(market.morpho).setRisk(3000e36 / assetPrice(index), 7500, 8000);
        TestnetLendingRegistry(registry).register(market.euler);
        TestnetLendingRegistry(registry).register(market.morpho);
        market.aaveAdapter = _adapter(deployed, market, config.owner, 0, registry);
        market.eulerAdapter = _adapter(deployed, market, config.owner, 1, registry);
        market.morphoAdapter = _adapter(deployed, market, config.owner, 2, registry);
        market.erc4626Adapter = _adapter(deployed, market, config.owner, 3, registry);
        market.accountRegistry = address(new AccountRegistry(config.owner));
        address factory = address(new AdapterFactory(config.owner));
        AdapterFactory(factory)
            .whitelist(address(new LiquidLaneAdapter(deployed.vaultFactory, factory, market.accountRegistry)));
        market.liquidLaneAdapter = AdapterFactory(factory)
            .create(
                1,
                config.owner,
                abi.encode(
                    market.vault,
                    abi.encode(ILiquidLaneAdapter.InitParams({pauser: config.owner, unpauser: config.owner}))
                )
            );
        market.reactor = address(new Reactor(factory));
        market.threeF = block.chainid == SepoliaInfrastructure.CHAIN_ID ? SepoliaInfrastructure.FACILITY : address(0);
        if (block.chainid != SepoliaInfrastructure.CHAIN_ID) {
            market.threeF = address(new TestnetThreeFFacility(config.owner, market.asset, deployed.collateral));
            market.request = TestnetThreeFFacility(market.threeF).createRequest(uint48(block.timestamp + 7 days));
        }
        factory = address(new AdapterFactory(config.owner));
        AdapterFactory(factory)
            .whitelist(
                address(
                    new ThreeFAdapter(
                        deployed.vaultFactory,
                        factory,
                        block.chainid == SepoliaInfrastructure.CHAIN_ID
                            ? SepoliaInfrastructure.WHITELIST
                            : market.threeF
                    )
                )
            );
        market.threeFAdapter = AdapterFactory(factory).create(1, config.owner, abi.encode(market.vault, ""));
        ThreeFAdapter(market.threeFAdapter).setOfferSigner(config.owner);
        ThreeFAdapter(market.threeFAdapter)
            .setLimitsPerRequest(1000, 1, seedAmount(config.seedAssets, market.asset, index));
        factory = address(new AdapterFactory(config.owner));
        AdapterFactory(factory)
            .whitelist(
                address(
                    new AppAdapter(
                        deployed.vaultFactory, factory, deployed.cowSettlement, deployed.networkMiddlewareService
                    )
                )
            );
        market.appAdapter = AdapterFactory(factory)
            .create(
                1,
                config.owner,
                abi.encode(
                    market.vault,
                    abi.encode(
                        IAppAdapter.InitParams({
                            burner: address(new TestnetBurner(market.asset)),
                            duration: 7 days,
                            operator: config.owner,
                            subnetwork: bytes32(uint256(uint160(config.owner)) << 96 | 1),
                            converters: new address[](0)
                        })
                    )
                )
            );
        market.restakingVault = VaultFactory(deployed.vaultFactory)
            .create(VAULT_V2_VERSION, config.owner, _vaultParams(config.owner, market.vault, index + 7));
        market.restakingDelegator = IVaultV2(market.restakingVault).delegator();
        factory = address(new AdapterFactory(config.owner));
        AdapterFactory(factory)
            .whitelist(
                address(
                    new RestakingAppAdapter(
                        deployed.vaultFactory, factory, deployed.cowSettlement, deployed.networkMiddlewareService
                    )
                )
            );
        market.restakingAdapter = AdapterFactory(factory)
            .create(
                1,
                config.owner,
                abi.encode(
                    market.restakingVault,
                    abi.encode(
                        IRestakingAppAdapter.RestakingInitParams({
                            asset: market.asset,
                            initParams: IAppAdapter.InitParams({
                                burner: address(new TestnetBurner(market.asset)),
                                duration: 7 days,
                                operator: config.owner,
                                subnetwork: bytes32(uint256(uint160(config.owner)) << 96 | 2),
                                converters: new address[](0)
                            })
                        })
                    )
                )
            );
        IAdapterRegistry(deployed.adapterRegistry)
            .setWhitelistedStatus(market.restakingVault, market.restakingAdapter, true);
        IUniversalDelegator(market.restakingDelegator).addAdapter(market.restakingAdapter);
        IUniversalDelegator(market.restakingDelegator).setLimits(market.restakingAdapter, type(uint128).max, MAX_SHARE);
        _stop();
        market.nativeLending = new TestnetNativeLendingScript(config.owner, _broadcast())
            .deploy(
                market.asset,
                deployed.collateral,
                3000e36 * 10 ** TestnetToken(market.asset).decimals() / assetPrice(index)
            );
        market.merkle = new TestnetMerkleScript(config.owner, _broadcast())
            .runBase(
                IDeployMerkleAdapter.Config({
                    vaultFactory: deployed.vaultFactory,
                    vault: market.vault,
                    provider: config.owner,
                    curator: config.owner,
                    admin: config.owner,
                    chainlinkWorkflowRegistry: deployed.chainlinkRegistry,
                    forwarder: deployed.forwarder,
                    oracleParams: ICREOracle.InitParams({
                        defaultAdminRoleHolder: config.owner,
                        oracleGuardRoleHolder: config.owner,
                        oracleLimitsRoleHolder: config.owner,
                        maxOracleGrowth: 10_000_000,
                        maxOracleLoss: 10_000_000,
                        oracleTolerance: uint128(10 * 10 ** TestnetToken(market.asset).decimals())
                    })
                })
            );
        _start(config.owner);
        address account = IMerkleAdapter(market.merkle.adapter).account();
        market.executor = address(new RecipeExecutor(config.owner, account));
        RecipeExecutor(market.executor).setCaller(config.owner);
        market.oracleRegistry = address(new OracleRegistry(config.owner));
        market.connectorFactory = address(new MigratablesFactory(config.owner));
        MigratablesFactory(market.connectorFactory)
            .whitelist(
                address(
                    new LiquidLaneConnector(
                        market.connectorFactory, market.merkle.accountFactory, market.oracleRegistry
                    )
                )
            );
        market.connector =
            MigratablesFactory(market.connectorFactory).create(1, config.owner, abi.encode(account, market.asset));
        market.policyFactory = address(new MigratablesFactory(config.owner));
        MigratablesFactory(market.policyFactory)
            .whitelist(
                address(
                    new ThreeFPolicy(
                        market.policyFactory,
                        block.chainid == SepoliaInfrastructure.CHAIN_ID
                            ? SepoliaInfrastructure.REQUESTS_FACTORY
                            : market.threeF,
                        market.threeF
                    )
                )
            );
        market.policy = MigratablesFactory(market.policyFactory).create(1, config.owner, abi.encode(account));
        market.rwas = _rwas(config, deployed, market, index);
        _permissions(config, deployed, market, index);
        address[8] memory adapters = [
            market.aaveAdapter,
            market.eulerAdapter,
            market.morphoAdapter,
            market.erc4626Adapter,
            market.liquidLaneAdapter,
            market.threeFAdapter,
            market.appAdapter,
            market.merkle.adapter
        ];
        for (uint256 i; i < adapters.length; ++i) {
            IAdapterRegistry(deployed.adapterRegistry).setWhitelistedStatus(market.vault, adapters[i], true);
            IUniversalDelegator(market.delegator).addAdapter(adapters[i]);
            IUniversalDelegator(market.delegator)
                .setLimits(adapters[i], seedAmount(config.seedAssets, market.asset, index), MAX_SHARE);
        }
        LiquidLaneAdapter(market.liquidLaneAdapter).setMarketMaker(config.owner, true);
        _stop();
    }

    function _adapter(Deployment memory deployed, Market memory market, address owner, uint256 kind, address registry)
        internal
        returns (address)
    {
        address factory = address(new AdapterFactory(owner));
        address implementation;
        bytes memory init;
        if (kind == 0) {
            implementation = address(
                new AaveV3Adapter(market.aave, deployed.vaultFactory, factory, deployed.merkl, deployed.cowSettlement)
            );
            init = abi.encode(IAaveV3Adapter.InitParams({converters: new address[](0)}));
        }
        if (kind == 1) {
            implementation = address(
                new EulerAdapter(deployed.vaultFactory, factory, deployed.merkl, deployed.cowSettlement, registry)
            );
            init = abi.encode(IEulerAdapter.InitParams({lendVault: market.euler, converters: new address[](0)}));
        }
        if (kind == 2) {
            implementation = address(
                new MorphoVaultV2Adapter(
                    deployed.vaultFactory, factory, deployed.merkl, deployed.cowSettlement, registry, registry
                )
            );
            init = abi.encode(
                IMorphoVaultV2Adapter.InitParams({morphoVault: market.morpho, converters: new address[](0)})
            );
        }
        if (kind == 3) {
            implementation =
                address(new ERC4626Adapter(deployed.vaultFactory, factory, deployed.merkl, deployed.cowSettlement));
            init = abi.encode(IERC4626Adapter.InitParams({converters: new address[](0), erc4626Vault: market.erc4626}));
        }
        AdapterFactory(factory).whitelist(implementation);
        return AdapterFactory(factory).create(1, owner, abi.encode(market.vault, init));
    }

    function _rwas(Config memory config, Deployment memory deployed, Market memory market, uint256 marketIndex)
        internal
        returns (RWA[] memory rwas)
    {
        _stop();
        uint256 count;
        for (uint256 i; i < TestnetCatalog.count(); ++i) {
            if (TestnetCatalog.profile(i).market == marketIndex) ++count;
        }
        rwas = new RWA[](count);
        address provider = address(new TestnetProviderDeploymentScript(config.owner, _broadcast()));
        address yield = address(new TestnetYieldDeploymentScript(config.owner, _broadcast()));
        address eth = address(new TestnetEthDeploymentScript(config.owner, _broadcast()));
        uint256 row;
        for (uint256 i; i < TestnetCatalog.count(); ++i) {
            TestnetCatalog.Profile memory profile = TestnetCatalog.profile(i);
            if (profile.market != marketIndex) continue;
            RWA memory rwa;
            rwa.profile = i;
            rwa.symbol = profile.symbol;
            rwa.mechanism = profile.mechanism;
            _start(config.owner);
            rwa.accountFactory = profile.mechanism == 4 && profile.variant == 6
                ? address(new TestnetAssetoFactory(config.owner, keccak256("testnet investor bank account")))
                : address(new MigratablesFactory(config.owner));
            address implementation;
            if (profile.mechanism < 4) {
                rwa.feed = address(
                    new TestnetPriceFeed(
                        config.owner,
                        string.concat(profile.symbol, " / ", TestnetToken(market.asset).symbol()),
                        18,
                        30 hours,
                        int256(profile.fixturePrice)
                    )
                );
                if (profile.mechanism < 3) {
                    rwa.token = address(
                        new TestnetToken(string.concat("Testnet ", profile.symbol), profile.symbol, 18, config.owner)
                    );
                    rwa.redemption = address(
                        new TestnetMidasRedemptionVault(
                            config.owner,
                            rwa.token,
                            rwa.feed,
                            market.asset,
                            profile.mechanism == 2 ? uint48(35 days) : profile.cooldown,
                            10
                        )
                    );
                    rwa.oracle = address(new MidasOracle(profile.minPrice, profile.maxPrice, rwa.feed));
                    if (profile.mechanism == 0) {
                        implementation = address(
                            new MidasCompAccount(
                                rwa.oracle,
                                rwa.accountFactory,
                                profile.cooldown,
                                rwa.token,
                                market.asset,
                                rwa.redemption,
                                deployed.cowSettlement
                            )
                        );
                    } else if (profile.mechanism == 1) {
                        implementation = address(
                            new MidasNonCompAccount(
                                rwa.oracle,
                                rwa.accountFactory,
                                profile.cooldown,
                                rwa.token,
                                market.asset,
                                rwa.redemption,
                                deployed.cowSettlement
                            )
                        );
                    } else {
                        implementation = address(
                            new CutoffMidasAccount(
                                rwa.oracle,
                                rwa.accountFactory,
                                profile.cooldown,
                                1_785_074_400,
                                rwa.token,
                                5 days,
                                market.asset,
                                rwa.redemption,
                                deployed.cowSettlement
                            )
                        );
                    }
                } else {
                    rwa.token = address(
                        new TestnetAsyncVault(
                            config.owner,
                            market.asset,
                            rwa.feed,
                            2 days,
                            string.concat("Testnet ", profile.symbol),
                            profile.symbol
                        )
                    );
                    rwa.redemption = rwa.token;
                    rwa.oracle =
                        address(new AsyncRedeemOracle(profile.minPrice, profile.maxPrice, rwa.token, rwa.token));
                    implementation = address(
                        new TestnetAsyncAccount(
                            rwa.oracle,
                            rwa.accountFactory,
                            profile.cooldown,
                            rwa.token,
                            market.asset,
                            deployed.cowSettlement
                        )
                    );
                }
            } else if (profile.mechanism == 7) {
                rwa.token = address(
                    new TestnetCreditVault(
                        market.asset,
                        deployed.collateral,
                        config.owner,
                        address(0),
                        "Testnet ERC4626 receipt",
                        "sRWA",
                        5e16
                    )
                );
                rwa.redemption = rwa.token;
                rwa.oracle = address(new ERC4626Oracle(profile.minPrice, profile.maxPrice, rwa.token));
                implementation = address(new ERC4626Account(rwa.accountFactory, rwa.token, deployed.cowSettlement));
            }
            _stop();
            if (profile.mechanism == 4) {
                (rwa.token, rwa.oracle, rwa.redemption, implementation) = TestnetProviderDeploymentScript(provider)
                    .deploy(rwa.accountFactory, deployed.cowSettlement, market.asset, profile.variant);
            }
            if (profile.mechanism == 5) {
                (rwa.token, rwa.oracle, rwa.redemption, implementation) = TestnetYieldDeploymentScript(yield)
                    .deploy(rwa.accountFactory, deployed.cowSettlement, market.asset, profile.variant);
            }
            if (profile.mechanism == 6) {
                (rwa.token, rwa.oracle, rwa.redemption, implementation) = TestnetEthDeploymentScript(eth)
                    .deploy(rwa.accountFactory, deployed.cowSettlement, market.asset, profile.variant == 1);
            }
            _start(config.owner);
            MigratablesFactory(rwa.accountFactory).whitelist(implementation);
            AccountRegistry(market.accountRegistry).setAccountFactory(market.asset, rwa.token, rwa.accountFactory);
            LiquidLaneAdapter(market.liquidLaneAdapter).addTokenToRedeem(rwa.token);
            if (profile.mechanism == 5 && profile.variant == 10) {
                TestnetParetoCDO(TestnetParetoQueue(rwa.redemption).idleCDOEpoch())
                    .setWalletAllowed(ILiquidLaneAdapter(market.liquidLaneAdapter).accounts(rwa.token), true);
            }
            if (rwa.feed == address(0)) {
                (bool success, bytes memory data) = rwa.oracle.staticcall(abi.encodeWithSignature("AGGREGATOR_0()"));
                if (success && data.length == 32) {
                    rwa.feed = abi.decode(data, (address));
                } else if (profile.mechanism == 4 && profile.variant == 6) {
                    (, data) = rwa.oracle.staticcall(abi.encodeWithSignature("PRICER()"));
                    rwa.feed = abi.decode(data, (address));
                } else if (profile.mechanism == 4 && profile.variant == 7) {
                    (, data) = rwa.redemption.staticcall(abi.encodeWithSignature("priceOracle()"));
                    rwa.feed = abi.decode(data, (address));
                }
            }
            LiquidLaneAdapter(market.liquidLaneAdapter)
                .setLimit(rwa.token, seedAmount(config.seedAssets, market.asset, marketIndex) / 10);
            OracleRegistry(market.oracleRegistry).setOracle(market.connector, rwa.token, rwa.oracle);
            _stop();
            rwas[row++] = rwa;
        }
        _start(config.owner);
    }

    function assetPrice(uint256 market) public pure returns (uint256) {
        return market == 5 ? 3000e18 : market >= 2 && market <= 4 ? 60_000e18 : 1e18;
    }

    function seedAmount(uint256 budget, address asset, uint256 market) public view returns (uint256) {
        return budget * 10 ** TestnetToken(asset).decimals() * 1e18 / assetPrice(market);
    }

    function _permissions(Config memory config, Deployment memory deployed, Market memory market, uint256 marketIndex)
        internal
    {
        address account = IMerkleAdapter(market.merkle.adapter).account();
        market.actions = new IMerkleAccount.Action[]((market.request == address(0) ? 5 : 9) + market.rwas.length * 2);
        market.actions[0] =
            TestnetPermissions.action(market.asset, abi.encodeCall(IERC20.approve, (market.aave, uint256(0))), 36);
        market.actions[1] = TestnetPermissions.action(
            market.aave, abi.encodeCall(TestnetAavePool.supply, (market.asset, uint256(0), account, uint16(0))), 36
        );
        market.actions[2] = TestnetPermissions.action(
            market.aave, abi.encodeCall(TestnetAavePool.withdraw, (market.asset, uint256(0), account)), 36
        );
        for (uint256 i; i < market.rwas.length; ++i) {
            market.actions[3 + i * 2] = TestnetPermissions.action(
                market.connector,
                abi.encodeCall(LiquidLaneConnector.addTokenToRedeem, (market.rwas[i].token, market.rwas[i].oracle)),
                0
            );
            market.actions[4 + i * 2] = TestnetPermissions.action(
                market.connector,
                abi.encodeCall(
                    LiquidLaneConnector.setMaxAssetsPerDuration,
                    (
                        market.rwas[i].token,
                        seedAmount(config.seedAssets, market.asset, marketIndex) / 10,
                        uint48(1 days)
                    )
                ),
                0
            );
        }
        if (market.request != address(0)) {
            market.actions[3 + market.rwas.length * 2] = TestnetPermissions.action(
                market.policy, abi.encodeCall(ThreeFPolicy.setMinYieldPerRequest, (deployed.collateral, 100_000)), 0
            );
            market.actions[4 + market.rwas.length * 2] = TestnetPermissions.action(
                market.policy,
                abi.encodeCall(
                    ThreeFPolicy.setMaxAssetsPerDuration,
                    (
                        market.asset,
                        deployed.collateral,
                        seedAmount(config.seedAssets, market.asset, marketIndex) / 10,
                        uint48(1 days)
                    )
                ),
                0
            );
            market.actions[market.actions.length - 4] = TestnetPermissions.action(
                market.asset, abi.encodeCall(IERC20.approve, (market.request, uint256(0))), 36
            );
            ThreeFGuardedMint.Leaf memory mintLeaf = ThreeFGuardedMint.build(
                ThreeFGuardedMint.Config({
                    account: account, asset: market.asset, policy: market.policy, request: market.request
                })
            );
            market.actions[market.actions.length - 3] = IMerkleAccount.Action({
                target: account, value: 0, data: mintLeaf.data, dataMask: mintLeaf.dataMask, proof: new bytes32[](0)
            });
        }
        market.actions[market.actions.length - 2] =
            TestnetPermissions.action(market.merkle.adapter, abi.encodeCall(IMerkleAdapter.push, (uint256(0))), 4);
        market.actions[market.actions.length - 1] =
            TestnetPermissions.action(market.merkle.adapter, abi.encodeCall(IMerkleAdapter.pull, (uint256(0))), 4);
        (bytes32 root, bytes32[] memory leaves) = TestnetPermissions.authorize(market.actions);
        RootRegistry(market.merkle.rootRegistry).setRoot(account, root);
        IMerkleAccount(account).acceptRoot(root);
        for (uint256 i; i < leaves.length; ++i) {
            IMerkleAccount(account).grantRole(leaves[i], config.owner);
            IMerkleAccount(account).grantRole(leaves[i], market.executor);
        }
        IMerkleAccount.Action[] memory configure =
            new IMerkleAccount.Action[](market.rwas.length * 2 + (market.request == address(0) ? 0 : 2));
        for (uint256 i; i < configure.length; ++i) {
            configure[i] = market.actions[i + 3];
        }
        IMerkleAccount(account).manage(configure);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IRecipeCapability.execute.selector;
        CapabilitiesRegistry(market.merkle.capabilitiesRegistry)
            .whitelistCapability(account, deployed.recipeCapability, selectors);
        IMerkleAccount(account).addCapability(deployed.recipeCapability, keccak256(abi.encode(selectors)));
        bytes32[] memory manageLeaves = new bytes32[](1);
        manageLeaves[0] = leaves[1];
        uint256[][] memory bindings = new uint256[][](1);
        bindings[0] = new uint256[](1);
        bindings[0][0] = (uint256(36) << 224) | (uint256(SRC_INPUT) << 216);
        market.recipe = new bytes[](market.request == address(0) ? 3 : 6);
        market.recipe[0] = bytes.concat(
            bytes1(OP_APPROVE), abi.encode(uint256(SRC_INPUT) << 216, market.asset, market.aave, leaves[0])
        );
        market.recipe[1] = bytes.concat(bytes1(OP_MANAGE), abi.encode(uint256(1), manageLeaves, bindings));
        market.recipe[2] =
            bytes.concat(bytes1(OP_APPROVE), abi.encode(uint256(0), market.asset, market.aave, leaves[0]));
        if (market.request != address(0)) {
            market.recipe[3] = bytes.concat(
                bytes1(OP_APPROVE),
                abi.encode((uint256(SRC_INPUT) << 216) | 1, market.asset, market.request, leaves[leaves.length - 4])
            );
            manageLeaves[0] = leaves[leaves.length - 3];
            ThreeFGuardedMint.Leaf memory mintLeaf = ThreeFGuardedMint.build(
                ThreeFGuardedMint.Config({
                    account: account, asset: market.asset, policy: market.policy, request: market.request
                })
            );
            bindings[0] = ThreeFGuardedMint.bindings(
                mintLeaf, (uint256(SRC_INPUT) << 216) | 1, (uint256(SRC_INPUT) << 216) | 2, uint160(market.request)
            );
            market.recipe[4] = bytes.concat(bytes1(OP_MANAGE), abi.encode(uint256(1), manageLeaves, bindings));
            market.recipe[5] = bytes.concat(
                bytes1(OP_APPROVE), abi.encode(uint256(0), market.asset, market.request, leaves[leaves.length - 4])
            );
        }
        RecipeExecutor(market.executor).setRecipe(new bytes[](0), market.recipe);
    }

    function _vaultParams(address owner, address asset, uint256 index) internal view returns (bytes memory) {
        return abi.encode(
            IVaultV2.InitParams({
                name: string.concat(
                    index >= 7 ? "Restaking " : "Realistic ", TestnetToken(asset).symbol(), " testnet vault"
                ),
                symbol: string.concat(index >= 7 ? "rs" : "rt", TestnetToken(asset).symbol()),
                asset: asset,
                depositWhitelist: false,
                depositorToWhitelist: address(0),
                depositLimit: 0,
                isDepositLimit: false,
                defaultAdminRoleHolder: owner,
                managementFeeRoleHolder: owner,
                performanceFeeRoleHolder: owner,
                depositLimitSetRoleHolder: owner,
                depositorWhitelistRoleHolder: owner,
                isDepositLimitSetRoleHolder: owner,
                depositWhitelistSetRoleHolder: owner,
                delegatorParams: abi.encode(
                    IUniversalDelegator.InitParams({
                        allocateRoleHolder: owner,
                        deallocateRoleHolder: owner,
                        addAdapterRoleHolder: owner,
                        swapAdaptersRoleHolder: owner,
                        defaultAdminRoleHolder: owner,
                        removeAdapterRoleHolder: owner,
                        forceDeallocateRoleHolder: owner,
                        setAdapterLimitsRoleHolder: owner,
                        setAutoAllocateAdaptersRoleHolder: owner
                    })
                )
            })
        );
    }

    function writeManifest(Deployment memory deployed, string memory path) public {
        string memory key = "realistic-testnet";
        vm.serializeUint(key, "schemaVersion", 2);
        vm.serializeString(
            key,
            "infrastructure",
            deployed.chainId == SepoliaInfrastructure.CHAIN_ID ? "official-sepolia" : "local-fixtures"
        );
        vm.serializeUint(key, "chainId", deployed.chainId);
        vm.serializeUint(key, "startBlock", deployed.startBlock);
        vm.serializeUint(key, "seedAssets", deployed.seedAssets);
        vm.serializeAddress(key, "owner", deployed.owner);
        vm.serializeAddress(key, "vaultFactory", deployed.vaultFactory);
        vm.serializeAddress(key, "adapterRegistry", deployed.adapterRegistry);
        vm.serializeAddress(key, "chainlinkRegistry", deployed.chainlinkRegistry);
        vm.serializeAddress(key, "forwarder", deployed.forwarder);
        vm.serializeAddress(
            key,
            "threeFRequestsFactory",
            (deployed.chainId == SepoliaInfrastructure.CHAIN_ID ? SepoliaInfrastructure.REQUESTS_FACTORY : address(0))
        );
        vm.serializeAddress(
            key,
            "threeFFacility",
            (deployed.chainId == SepoliaInfrastructure.CHAIN_ID ? SepoliaInfrastructure.FACILITY : address(0))
        );
        vm.serializeAddress(
            key,
            "threeFWhitelist",
            (deployed.chainId == SepoliaInfrastructure.CHAIN_ID ? SepoliaInfrastructure.WHITELIST : address(0))
        );
        address[] memory vaults = new address[](deployed.markets.length);
        address[] memory adapters = new address[](vaults.length);
        for (uint256 i; i < vaults.length; ++i) {
            vaults[i] = deployed.markets[i].vault;
            adapters[i] = deployed.markets[i].merkle.adapter;
        }
        vm.serializeAddress(key, "vaults", vaults);
        vm.serializeAddress(key, "merkleAdapters", adapters);
        vm.serializeAddress(key, "collateral", deployed.collateral);
        vm.serializeAddress(key, "merklDistributor", deployed.merkl);
        vm.serializeAddress(key, "cowSettlement", deployed.cowSettlement);
        vm.serializeAddress(key, "recipeCapability", deployed.recipeCapability);
        vm.serializeAddress(key, "universalDelegatorFactory", deployed.universalDelegatorFactory);
        vm.serializeAddress(key, "withdrawalQueueFactory", deployed.withdrawalQueueFactory);
        vm.serializeAddress(key, "protocolFeeRegistry", deployed.protocolFeeRegistry);
        vm.serializeAddress(key, "networkRegistry", deployed.networkRegistry);
        vm.serializeAddress(key, "operatorRegistry", deployed.operatorRegistry);
        vm.serializeAddress(key, "networkMiddlewareService", deployed.networkMiddlewareService);
        vm.serializeAddress(key, "delegatorFactory", deployed.coreServices[0]);
        vm.serializeAddress(key, "slasherFactory", deployed.coreServices[1]);
        vm.serializeAddress(key, "vaultConfigurator", deployed.coreServices[2]);
        vm.serializeAddress(key, "operatorMetadataService", deployed.coreServices[3]);
        vm.serializeAddress(key, "networkMetadataService", deployed.coreServices[4]);
        vm.serializeAddress(key, "operatorVaultOptInService", deployed.coreServices[5]);
        vm.serializeAddress(key, "operatorNetworkOptInService", deployed.coreServices[6]);
        vm.serializeAddress(key, "immutableFactory", deployed.immutableFactory);
        vm.serializeAddress(key, "aaveHealthFactorReader", deployed.readers[0]);
        vm.serializeAddress(key, "eulerHealthFactorReader", deployed.readers[1]);
        vm.serializeAddress(key, "morphoBlueHealthFactorReader", deployed.readers[2]);
        vm.serializeAddress(key, "morphoMidnightHealthFactorReader", deployed.readers[3]);
        vm.serializeAddress(key, "aaveV3LiquidityReader", deployed.readers[4]);
        vm.serializeAddress(key, "aaveV4LiquidityReader", deployed.readers[5]);
        vm.serializeAddress(key, "morphoLiquidityReader", deployed.readers[6]);
        address[] memory workflows = new address[](vaults.length);
        address[] memory accounts = new address[](vaults.length);
        address[] memory oracles = new address[](vaults.length);
        address[] memory executors = new address[](vaults.length);
        address[] memory connectors = new address[](vaults.length);
        string memory marketRows = "[";
        for (uint256 i; i < vaults.length; ++i) {
            workflows[i] = deployed.markets[i].merkle.workflowRegistry;
            accounts[i] = IMerkleAdapter(deployed.markets[i].merkle.adapter).account();
            oracles[i] = IMerkleAdapter(deployed.markets[i].merkle.adapter).oracle();
            executors[i] = deployed.markets[i].executor;
            connectors[i] = deployed.markets[i].connector;
            string memory row = string.concat("market-", i.toString());
            vm.serializeJson(row, "{}");
            vm.serializeAddress(row, "asset", deployed.markets[i].asset);
            vm.serializeUint(row, "decimals", TestnetToken(deployed.markets[i].asset).decimals());
            vm.serializeAddress(row, "vault", deployed.markets[i].vault);
            vm.serializeAddress(row, "delegator", deployed.markets[i].delegator);
            vm.serializeAddress(row, "aavePool", deployed.markets[i].aave);
            vm.serializeAddress(row, "eulerVault", deployed.markets[i].euler);
            vm.serializeAddress(row, "morphoVault", deployed.markets[i].morpho);
            vm.serializeAddress(row, "erc4626Vault", deployed.markets[i].erc4626);
            vm.serializeAddress(row, "morphoBlue", deployed.markets[i].nativeLending.blue);
            vm.serializeAddress(row, "morphoMidnight", deployed.markets[i].nativeLending.midnight);
            vm.serializeAddress(row, "aaveV4", deployed.markets[i].nativeLending.aaveV4);
            vm.serializeAddress(row, "midnightLender", deployed.markets[i].nativeLending.midnightLender);
            vm.serializeAddress(row, "collateralOracle", deployed.markets[i].nativeLending.oracle);
            vm.serializeAddress(row, "interestRateModel", deployed.markets[i].nativeLending.irm);
            vm.serializeBytes32(row, "morphoBlueMarketId", deployed.markets[i].nativeLending.blueId);
            vm.serializeBytes32(row, "morphoMidnightMarketId", deployed.markets[i].nativeLending.midnightId);
            vm.serializeBytes(row, "morphoBlueParams", deployed.markets[i].nativeLending.blueParams);
            vm.serializeBytes(row, "morphoMidnightParams", deployed.markets[i].nativeLending.midnightParams);
            vm.serializeBytes(row, "merkleActions", abi.encode(deployed.markets[i].actions));
            vm.serializeBytes(row, "recipeSteps", abi.encode(deployed.markets[i].recipe));
            vm.serializeAddress(row, "liquidLaneAdapter", deployed.markets[i].liquidLaneAdapter);
            vm.serializeAddress(row, "reactor", deployed.markets[i].reactor);
            vm.serializeAddress(row, "threeFAdapter", deployed.markets[i].threeFAdapter);
            vm.serializeAddress(row, "threeFFacility", deployed.markets[i].threeF);
            vm.serializeAddress(row, "threeFRequest", deployed.markets[i].request);
            vm.serializeAddress(row, "threeFPolicy", deployed.markets[i].policy);
            vm.serializeAddress(row, "appAdapter", deployed.markets[i].appAdapter);
            vm.serializeAddress(row, "aaveAdapter", deployed.markets[i].aaveAdapter);
            vm.serializeAddress(row, "eulerAdapter", deployed.markets[i].eulerAdapter);
            vm.serializeAddress(row, "morphoAdapter", deployed.markets[i].morphoAdapter);
            vm.serializeAddress(row, "erc4626Adapter", deployed.markets[i].erc4626Adapter);
            vm.serializeAddress(row, "merkleAdapter", deployed.markets[i].merkle.adapter);
            vm.serializeAddress(row, "rootRegistry", deployed.markets[i].merkle.rootRegistry);
            vm.serializeAddress(row, "workflowRegistry", workflows[i]);
            vm.serializeAddress(row, "capabilitiesRegistry", deployed.markets[i].merkle.capabilitiesRegistry);
            vm.serializeAddress(row, "merkleAdapterFactory", deployed.markets[i].merkle.adapterFactory);
            vm.serializeAddress(row, "merkleAccountFactory", deployed.markets[i].merkle.accountFactory);
            vm.serializeAddress(row, "creOracleFactory", deployed.markets[i].merkle.oracleFactory);
            vm.serializeAddress(row, "account", accounts[i]);
            vm.serializeAddress(row, "creOracle", oracles[i]);
            vm.serializeAddress(row, "executor", executors[i]);
            vm.serializeAddress(row, "connector", connectors[i]);
            vm.serializeAddress(row, "connectorFactory", deployed.markets[i].connectorFactory);
            vm.serializeAddress(row, "oracleRegistry", deployed.markets[i].oracleRegistry);
            vm.serializeAddress(row, "policyFactory", deployed.markets[i].policyFactory);
            vm.serializeAddress(row, "accountRegistry", deployed.markets[i].accountRegistry);
            vm.serializeBytes32(row, "root", IMerkleAccount(accounts[i]).root());
            vm.serializeBytes(row, "authorizedActions", abi.encode(deployed.markets[i].actions));
            vm.serializeAddress(row, "restakingVault", deployed.markets[i].restakingVault);
            vm.serializeAddress(row, "restakingDelegator", deployed.markets[i].restakingDelegator);
            vm.serializeAddress(row, "restakingAdapter", deployed.markets[i].restakingAdapter);
            vm.serializeBytes(row, "recipe", deployed.markets[i].recipe);
            string[] memory symbols = new string[](deployed.markets[i].rwas.length);
            uint256[] memory profiles = new uint256[](symbols.length);
            address[] memory rwaOracles = new address[](symbols.length);
            address[] memory factories = new address[](symbols.length);
            address[] memory tokens = new address[](deployed.markets[i].rwas.length);
            address[] memory feeds = new address[](tokens.length);
            address[] memory redemptions = new address[](tokens.length);
            for (uint256 j; j < tokens.length; ++j) {
                symbols[j] = deployed.markets[i].rwas[j].symbol;
                profiles[j] = deployed.markets[i].rwas[j].profile;
                rwaOracles[j] = deployed.markets[i].rwas[j].oracle;
                factories[j] = deployed.markets[i].rwas[j].accountFactory;
                tokens[j] = deployed.markets[i].rwas[j].token;
                feeds[j] = deployed.markets[i].rwas[j].feed;
                redemptions[j] = deployed.markets[i].rwas[j].redemption;
            }
            vm.serializeString(row, "rwaSymbols", symbols);
            vm.serializeUint(row, "rwaProfiles", profiles);
            vm.serializeAddress(row, "rwaOracles", rwaOracles);
            vm.serializeAddress(row, "rwaFactories", factories);
            vm.serializeAddress(row, "rwaTokens", tokens);
            vm.serializeAddress(row, "priceFeeds", feeds);
            string memory encoded = vm.serializeAddress(row, "redemptionEndpoints", redemptions);
            marketRows = string.concat(marketRows, i == 0 ? "" : ",", encoded);
        }
        vm.serializeAddress(key, "workflowRegistries", workflows);
        vm.serializeAddress(key, "accounts", accounts);
        vm.serializeAddress(key, "oracles", oracles);
        vm.serializeAddress(key, "executors", executors);
        vm.serializeAddress(key, "connectors", connectors);
        string memory json = vm.serializeBytes(key, "deployment", abi.encode(deployed));
        json = string.concat(string(_prefix(bytes(json), bytes(json).length - 1)), ",\"markets\":", marketRows, "]}");
        // The parent can be absent in a fresh checkout.
        uint256 slash;
        bytes memory value = bytes(path);
        for (uint256 i; i < value.length; ++i) {
            if (value[i] == "/") slash = i;
        }
        if (slash > 0) vm.createDir(string(_prefix(value, slash)), true);
        vm.writeJson(json, path);
        console2.log("Deployment manifest", path);
    }

    function _prefix(bytes memory value, uint256 length) internal pure returns (bytes memory result) {
        result = new bytes(length);
        for (uint256 i; i < length; ++i) {
            result[i] = value[i];
        }
    }

    function _broadcast() internal view virtual returns (bool) {
        return true;
    }

    function _start(address owner) internal {
        if (_broadcast()) vm.startBroadcast(owner);
        else vm.startPrank(owner, owner);
    }

    function _stop() internal {
        if (_broadcast()) vm.stopBroadcast();
        else vm.stopPrank();
    }
}
