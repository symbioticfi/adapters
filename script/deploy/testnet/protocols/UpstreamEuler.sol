// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {UpstreamArtifacts} from "./UpstreamArtifacts.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IUpstreamEulerFactory {
    function setImplementation(address implementation) external;
    function createProxy(address implementation, bool upgradeable, bytes calldata data) external returns (address);
    function isProxy(address vault) external view returns (bool);
}

interface IUpstreamEVault {
    function setHookConfig(address target, uint32 operations) external;
    function setInterestRateModel(address model) external;
    function setMaxLiquidationDiscount(uint16 discount) external;
    function setLTV(address collateral, uint16 borrowLTV, uint16 liquidationLTV, uint32 duration) external;
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    function borrow(uint256 assets, address receiver) external returns (uint256);
    function repay(uint256 assets, address account) external returns (uint256);
    function debtOf(address account) external view returns (uint256);
    function disableController() external;
}

interface IUpstreamEVC {
    function enableCollateral(address account, address collateral) external;
    function enableController(address account, address controller) external;
    function call(address target, address account, uint256 value, bytes calldata data)
        external
        payable
        returns (bytes memory);
    function getControllers(address account) external view returns (address[] memory);
    function getAccountOwner(address account) external view returns (address);
}

/// @title TestnetEulerOracle
/// @notice Controlled USD prices for real EVault assets, including collateral share conversion.
contract TestnetEulerOracle is Ownable {
    using Math for uint256;
    error InvalidQuote();

    address public constant UNIT_OF_ACCOUNT = address(1);
    mapping(address asset => uint256 price) public prices;
    mapping(address vault => address asset) public vaultAssets;

    constructor(address newOwner) Ownable(newOwner) {}

    function setAsset(address asset, uint256 price) public onlyOwner {
        if (price == 0) revert InvalidQuote();
        prices[asset] = price;
    }

    function setVault(address vault) public onlyOwner {
        address asset = IERC4626(vault).asset();
        if (prices[asset] == 0) revert InvalidQuote();
        vaultAssets[vault] = asset;
    }

    function getQuote(uint256 amount, address base, address quote) public view returns (uint256) {
        if (quote != UNIT_OF_ACCOUNT) revert InvalidQuote();
        address asset = vaultAssets[base];
        if (asset != address(0)) {
            amount = IERC4626(base).convertToAssets(amount);
            base = asset;
        }
        uint256 price = prices[base];
        if (price == 0) revert InvalidQuote();
        return amount.mulDiv(price, 10 ** IERC20Metadata(base).decimals());
    }

    function getQuotes(uint256 amount, address base, address quote) public view returns (uint256, uint256) {
        uint256 value = getQuote(amount, base, quote);
        return (value, value);
    }
}

/// @title UpstreamEuler
/// @notice Deploys actual EVC, EVault modules, attested factory and linked collateral/debt vaults.
contract UpstreamEuler is UpstreamArtifacts {
    struct Deployment {
        address evc;
        address factory;
        address implementation;
        address oracle;
        address irm;
        address collateralVault;
    }
    address internal immutable _OWNER;
    bool internal immutable _BROADCAST;
    Deployment internal _deployment;

    constructor(address newOwner, bool newBroadcast) {
        _OWNER = newOwner;
        _BROADCAST = newBroadcast;
    }

    function deploy(address collateral, uint256 price) public returns (Deployment memory deployed) {
        if (_BROADCAST) vm.startBroadcast(_OWNER);
        else vm.startPrank(_OWNER, _OWNER);
        deployed.evc = _deployArtifact("euler", "EthereumVaultConnector", "");
        address[5] memory integrations = [
            deployed.evc,
            _deployArtifact("euler", "ProtocolConfig", abi.encode(_OWNER, _OWNER)),
            _deployArtifact("euler", "SequenceRegistry", ""),
            address(0),
            address(0)
        ];
        string[8] memory names = [
            "Initialize", "Token", "Vault", "Borrowing", "Liquidation", "RiskManager", "BalanceForwarder", "Governance"
        ];
        address[8] memory modules;
        for (uint256 i; i < names.length; ++i) {
            modules[i] = _deployArtifact("euler", names[i], abi.encode(integrations));
        }
        deployed.implementation = _deployArtifact("euler", "EVault", abi.encode(integrations, modules));
        deployed.factory = _deployArtifact("euler", "GenericFactory", abi.encode(_OWNER));
        IUpstreamEulerFactory(deployed.factory).setImplementation(deployed.implementation);
        deployed.irm =
            _deployArtifact("euler", "IRMLinearKink", abi.encode(uint256(1e18), uint256(0), uint256(0), uint32(0)));
        deployed.oracle = address(new TestnetEulerOracle(_OWNER));
        _deployment = deployed;
        if (_BROADCAST) vm.stopBroadcast();
        else vm.stopPrank();
        deployed.collateralVault = addVault(collateral, price);
        _deployment.collateralVault = deployed.collateralVault;
    }

    function addVault(address asset, uint256 price) public returns (address vault) {
        if (_BROADCAST) vm.startBroadcast(_OWNER);
        else vm.startPrank(_OWNER, _OWNER);
        TestnetEulerOracle(_deployment.oracle).setAsset(asset, price);
        vault = IUpstreamEulerFactory(_deployment.factory)
            .createProxy(_deployment.implementation, true, abi.encodePacked(asset, _deployment.oracle, address(1)));
        IUpstreamEVault(vault).setHookConfig(address(0), 0);
        IUpstreamEVault(vault).setInterestRateModel(_deployment.irm);
        IUpstreamEVault(vault).setMaxLiquidationDiscount(1500);
        TestnetEulerOracle(_deployment.oracle).setVault(vault);
        if (_deployment.collateralVault != address(0)) {
            IUpstreamEVault(vault).setLTV(_deployment.collateralVault, 7500, 8000, 0);
        }
        if (_BROADCAST) vm.stopBroadcast();
        else vm.stopPrank();
    }
}
