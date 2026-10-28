// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {TestnetPriceFeed} from "./TestnetAssets.sol";
import {UpstreamArtifacts} from "./UpstreamArtifacts.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IUpstreamAaveProvider {
    function setACLAdmin(address admin) external;
    function setACLManager(address manager) external;
    function setPoolImpl(address implementation) external;
    function setPoolConfiguratorImpl(address implementation) external;
    function setPriceOracle(address oracle) external;
    function setPoolDataProvider(address dataProvider) external;
    function getPool() external view returns (address);
    function getPoolConfigurator() external view returns (address);
}

interface IUpstreamACL {
    function addPoolAdmin(address admin) external;
    function addEmergencyAdmin(address admin) external;
}

interface IUpstreamAaveOracle {
    function setAssetSources(address[] calldata assets, address[] calldata feeds) external;
    function setSpoke(address spoke) external;
}

interface IUpstreamAaveConfigurator {
    struct ReserveInput {
        address aTokenImpl;
        address variableDebtTokenImpl;
        address underlyingAsset;
        string aTokenName;
        string aTokenSymbol;
        string variableDebtTokenName;
        string variableDebtTokenSymbol;
        bytes params;
        bytes interestRateData;
    }
    function initReserves(ReserveInput[] calldata inputs) external;
    function configureReserveAsCollateral(address asset, uint256 ltv, uint256 threshold, uint256 bonus) external;
    function setReserveBorrowing(address asset, bool enabled) external;
    function setReserveFactor(address asset, uint256 factor) external;
}

interface IUpstreamAavePool {
    function getReservesList() external view returns (address[] memory);
    function supply(address asset, uint256 amount, address account, uint16 referral) external;
    function borrow(address asset, uint256 amount, uint256 mode, uint16 referral, address account) external;
    function repay(address asset, uint256 amount, uint256 mode, address account) external returns (uint256);
    function withdraw(address asset, uint256 amount, address receiver) external returns (uint256);
    function getReserveVariableDebtToken(address asset) external view returns (address);
    function getReserveAToken(address asset) external view returns (address);
}

interface IUpstreamAaveData {
    function getReserveTokensAddresses(address asset) external view returns (address, address, address);
}

interface IUpstreamAccessManager {
    function setTargetFunctionRole(address target, bytes4[] calldata selectors, uint64 role) external;
    function grantRole(uint64 role, address account, uint32 delay) external;
}

interface IUpstreamHub {
    struct SpokeConfig {
        uint40 addCap;
        uint40 drawCap;
        uint24 riskPremiumThreshold;
        bool active;
        bool halted;
    }
    function addAsset(address asset, uint8 decimals, address treasury, address strategy, bytes calldata rates)
        external
        returns (uint256);
    function addSpoke(uint256 id, address spoke, SpokeConfig calldata config) external;
}

interface IUpstreamSpoke {
    struct ReserveConfig {
        uint24 collateralRisk;
        bool paused;
        bool frozen;
        bool borrowable;
        bool receiveSharesEnabled;
    }

    struct DynamicConfig {
        uint16 collateralFactor;
        uint32 maxLiquidationBonus;
        uint16 liquidationFee;
    }

    struct LiquidationConfig {
        uint128 targetHealthFactor;
        uint64 healthFactorForMaxBonus;
        uint16 liquidationBonusFactor;
    }
    function updateLiquidationConfig(LiquidationConfig calldata config) external;
    function addReserve(
        address hub,
        uint256 assetId,
        address feed,
        ReserveConfig calldata config,
        DynamicConfig calldata dynamicConfig
    ) external returns (uint256);
    function getReserve(uint256 reserveId)
        external
        view
        returns (address, address, uint16, uint8, uint24, uint8, uint32);
    function getReserveCount() external view returns (uint256);
    function supply(uint256 reserveId, uint256 assets, address account) external returns (uint256, uint256);
    function withdraw(uint256 reserveId, uint256 assets, address account) external returns (uint256, uint256);
    function borrow(uint256 reserveId, uint256 assets, address account) external returns (uint256, uint256);
    function repay(uint256 reserveId, uint256 assets, address account) external returns (uint256, uint256);
    function setUsingAsCollateral(uint256 reserveId, bool enabled, address account) external;
    function getUserSuppliedShares(uint256 reserveId, address account) external view returns (uint256);
    function getUserSuppliedAssets(uint256 reserveId, address account) external view returns (uint256);
    function getUserTotalDebt(uint256 reserveId, address account) external view returns (uint256);
}

/// @title UpstreamAave
/// @notice Deploys genuine shared V3 and V4 markets using upstream artifacts and administrative calls.
contract UpstreamAave is UpstreamArtifacts {
    struct Deployment {
        address provider;
        address pool;
        address configurator;
        address dataProvider;
        address oracle;
        address aTokenImplementation;
        address debtTokenImplementation;
        address hub;
        address spoke;
        address treasury;
        address v4Strategy;
    }

    struct Reserve {
        address feed;
        uint256 hubAssetId;
        uint256 spokeReserveId;
    }
    address internal immutable _OWNER;
    bool internal immutable _BROADCAST;
    Deployment internal _deployment;

    constructor(address newOwner, bool newBroadcast) {
        _OWNER = newOwner;
        _BROADCAST = newBroadcast;
    }

    function deploy() public returns (Deployment memory deployed) {
        if (_BROADCAST) vm.startBroadcast(_OWNER);
        else vm.startPrank(_OWNER, _OWNER);
        deployed.provider = _deployArtifact("aave-v3", "PoolAddressesProvider", abi.encode("Aave", _OWNER));
        IUpstreamAaveProvider(deployed.provider).setACLAdmin(_OWNER);
        address acl = _deployArtifact("aave-v3", "ACLManager", abi.encode(deployed.provider));
        IUpstreamAaveProvider(deployed.provider).setACLManager(acl);
        IUpstreamACL(acl).addPoolAdmin(_OWNER);
        IUpstreamACL(acl).addEmergencyAdmin(_OWNER);
        address strategy =
            _deployArtifact("aave-v3", "DefaultReserveInterestRateStrategyV2", abi.encode(deployed.provider));
        IUpstreamAaveProvider(deployed.provider)
            .setPoolImpl(_deployArtifact("aave-v3", "PoolInstance", abi.encode(deployed.provider, strategy)));
        IUpstreamAaveProvider(deployed.provider)
            .setPoolConfiguratorImpl(_deployArtifact("aave-v3", "PoolConfiguratorInstance", ""));
        deployed.pool = IUpstreamAaveProvider(deployed.provider).getPool();
        deployed.configurator = IUpstreamAaveProvider(deployed.provider).getPoolConfigurator();
        deployed.oracle = _deployArtifact(
            "aave-v3",
            "AaveOracle",
            abi.encode(deployed.provider, new address[](0), new address[](0), address(0), address(0), uint256(1e8))
        );
        IUpstreamAaveProvider(deployed.provider).setPriceOracle(deployed.oracle);
        deployed.dataProvider = _deployArtifact("aave-v3", "AaveProtocolDataProvider", abi.encode(deployed.provider));
        IUpstreamAaveProvider(deployed.provider).setPoolDataProvider(deployed.dataProvider);
        deployed.aTokenImplementation =
            _deployArtifact("aave-v3", "ATokenInstance", abi.encode(deployed.pool, address(0), _OWNER));
        deployed.debtTokenImplementation =
            _deployArtifact("aave-v3", "VariableDebtTokenInstance", abi.encode(deployed.pool, address(0)));
        address authority = _deployArtifact("aave-v4", "AccessManagerEnumerable", abi.encode(_OWNER));
        deployed.hub = _deployArtifact(
            "aave-v4",
            "TransparentUpgradeableProxy",
            abi.encode(
                _deployArtifact("aave-v4", "HubInstance", ""),
                _OWNER,
                abi.encodeWithSignature("initialize(address)", authority)
            )
        );
        address oracle = _deployArtifact("aave-v4", "AaveOracle", abi.encode(uint8(8)));
        deployed.spoke = _deployArtifact(
            "aave-v4",
            "TransparentUpgradeableProxy",
            abi.encode(
                _deployArtifact("aave-v4", "SpokeInstance", abi.encode(oracle, uint16(16))),
                _OWNER,
                abi.encodeWithSignature("initialize(address)", authority)
            )
        );
        IUpstreamAaveOracle(oracle).setSpoke(deployed.spoke);
        deployed.treasury = _deployArtifact(
            "aave-v4",
            "TransparentUpgradeableProxy",
            abi.encode(
                _deployArtifact("aave-v4", "TreasurySpokeInstance", ""),
                _OWNER,
                abi.encodeWithSignature("initialize(address)", _OWNER)
            )
        );
        deployed.v4Strategy = _deployArtifact("aave-v4", "AssetInterestRateStrategy", abi.encode(deployed.hub));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IUpstreamHub.addAsset.selector;
        selectors[1] = IUpstreamHub.addSpoke.selector;
        IUpstreamAccessManager(authority).setTargetFunctionRole(deployed.hub, selectors, 101);
        IUpstreamAccessManager(authority).grantRole(101, _OWNER, 0);
        selectors[0] = IUpstreamSpoke.addReserve.selector;
        selectors[1] = IUpstreamSpoke.updateLiquidationConfig.selector;
        IUpstreamAccessManager(authority).setTargetFunctionRole(deployed.spoke, selectors, 301);
        IUpstreamAccessManager(authority).grantRole(301, _OWNER, 0);
        IUpstreamSpoke(deployed.spoke)
            .updateLiquidationConfig(
                IUpstreamSpoke.LiquidationConfig({
                    targetHealthFactor: 1.05e18, healthFactorForMaxBonus: 0.8e18, liquidationBonusFactor: 2000
                })
            );
        _deployment = deployed;
        if (_BROADCAST) vm.stopBroadcast();
        else vm.stopPrank();
    }

    function addReserve(address asset, uint256 usdPrice) public returns (Reserve memory reserve) {
        if (_BROADCAST) vm.startBroadcast(_OWNER);
        else vm.startPrank(_OWNER, _OWNER);
        reserve.feed = address(
            new TestnetPriceFeed(
                _OWNER, string.concat(IERC20Metadata(asset).symbol(), " / USD"), 8, 365 days, int256(usdPrice / 1e10)
            )
        );
        address[] memory assets = new address[](1);
        address[] memory feeds = new address[](1);
        assets[0] = asset;
        feeds[0] = reserve.feed;
        IUpstreamAaveOracle(_deployment.oracle).setAssetSources(assets, feeds);
        IUpstreamAaveConfigurator.ReserveInput[] memory inputs = new IUpstreamAaveConfigurator.ReserveInput[](1);
        inputs[0] = IUpstreamAaveConfigurator.ReserveInput({
            aTokenImpl: _deployment.aTokenImplementation,
            variableDebtTokenImpl: _deployment.debtTokenImplementation,
            underlyingAsset: asset,
            aTokenName: string.concat("Aave ", IERC20Metadata(asset).symbol()),
            aTokenSymbol: string.concat("a", IERC20Metadata(asset).symbol()),
            variableDebtTokenName: string.concat("Aave debt ", IERC20Metadata(asset).symbol()),
            variableDebtTokenSymbol: string.concat("vd", IERC20Metadata(asset).symbol()),
            params: "",
            interestRateData: abi.encode(uint16(8000), uint32(100), uint32(400), uint32(7500))
        });
        IUpstreamAaveConfigurator(_deployment.configurator).initReserves(inputs);
        IUpstreamAaveConfigurator(_deployment.configurator).configureReserveAsCollateral(asset, 7500, 8000, 10_500);
        IUpstreamAaveConfigurator(_deployment.configurator).setReserveBorrowing(asset, true);
        IUpstreamAaveConfigurator(_deployment.configurator).setReserveFactor(asset, 1000);
        reserve.hubAssetId = IUpstreamHub(_deployment.hub)
            .addAsset(
                asset,
                IERC20Metadata(asset).decimals(),
                _deployment.treasury,
                _deployment.v4Strategy,
                abi.encode(uint16(8000), uint32(100), uint32(400), uint32(7500))
            );
        IUpstreamHub(_deployment.hub)
            .addSpoke(
                reserve.hubAssetId,
                _deployment.spoke,
                IUpstreamHub.SpokeConfig({
                    addCap: type(uint40).max,
                    drawCap: type(uint40).max,
                    riskPremiumThreshold: 100_000,
                    active: true,
                    halted: false
                })
            );
        reserve.spokeReserveId = IUpstreamSpoke(_deployment.spoke)
            .addReserve(
                _deployment.hub,
                reserve.hubAssetId,
                reserve.feed,
                IUpstreamSpoke.ReserveConfig({
                    collateralRisk: 1000, paused: false, frozen: false, borrowable: true, receiveSharesEnabled: true
                }),
                IUpstreamSpoke.DynamicConfig({
                    collateralFactor: 8000, maxLiquidationBonus: 10_500, liquidationFee: 1000
                })
            );
        if (_BROADCAST) vm.stopBroadcast();
        else vm.stopPrank();
    }
}
