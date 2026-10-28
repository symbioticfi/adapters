// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {TestnetCollateralOracle} from "./TestnetNativeLending.sol";
import {UpstreamArtifacts} from "./UpstreamArtifacts.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IMorpho, MarketParams} from "morpho-blue/src/interfaces/IMorpho.sol";

interface IUpstreamMorphoFactory {
    function createVaultV2(address owner, address asset, bytes32 salt) external returns (address);
    function isVaultV2(address vault) external view returns (bool);
}

interface IUpstreamMorphoAllocationFactory {
    function createMorphoMarketV1AdapterV2(address vault) external returns (address);
}

interface IUpstreamMorphoVault {
    function setCurator(address curator) external;
    function setName(string calldata name) external;
    function setSymbol(string calldata symbol) external;
    function submit(bytes calldata data) external;
    function setIsAllocator(address allocator, bool allowed) external;
    function setAdapterRegistry(address registry) external;
    function addAdapter(address adapter) external;
    function increaseAbsoluteCap(bytes calldata idData, uint256 cap) external;
    function increaseRelativeCap(bytes calldata idData, uint256 cap) external;
    function setMaxRate(uint256 rate) external;
    function setLiquidityAdapterAndData(address adapter, bytes calldata data) external;
    function abdicate(bytes4 selector) external;
}

/// @title UpstreamMorpho
/// @notice Deploys real Blue markets and factory-attested Vault V2s with native allocation adapters and caps.
contract UpstreamMorpho is UpstreamArtifacts {
    struct Deployment {
        address blue;
        address irm;
        address vaultFactory;
        address allocationFactory;
        address registry;
    }

    struct Market {
        address vault;
        address allocation;
        address oracle;
        bytes blueParams;
        bytes32 blueId;
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
        deployed.blue = _deployArtifact("morpho-blue", "Morpho", abi.encode(_OWNER));
        deployed.irm = _deployArtifact("morpho-vault-v2", "AdaptiveCurveIrm", abi.encode(deployed.blue));
        IMorpho(deployed.blue).enableIrm(deployed.irm);
        IMorpho(deployed.blue).enableLltv(75e16);
        deployed.vaultFactory = _deployArtifact("morpho-vault-v2", "VaultV2Factory", "");
        deployed.allocationFactory = _deployArtifact(
            "morpho-vault-v2", "MorphoMarketV1AdapterV2Factory", abi.encode(deployed.blue, deployed.irm)
        );
        deployed.registry =
            _deployArtifact("morpho-vault-v2", "MorphoMarketV1RegistryV2", abi.encode(deployed.allocationFactory));
        _deployment = deployed;
        if (_BROADCAST) vm.stopBroadcast();
        else vm.stopPrank();
    }

    function addMarket(address asset, address collateral, uint256 collateralPrice)
        public
        returns (Market memory market)
    {
        if (_BROADCAST) vm.startBroadcast(_OWNER);
        else vm.startPrank(_OWNER, _OWNER);
        market.oracle = address(new TestnetCollateralOracle(_OWNER, collateralPrice));
        MarketParams memory params = MarketParams({
            loanToken: asset, collateralToken: collateral, oracle: market.oracle, irm: _deployment.irm, lltv: 75e16
        });
        IMorpho(_deployment.blue).createMarket(params);
        market.blueParams = abi.encode(asset, collateral, market.oracle, _deployment.irm, params.lltv);
        market.blueId = keccak256(market.blueParams);
        market.vault = IUpstreamMorphoFactory(_deployment.vaultFactory)
            .createVaultV2(_OWNER, asset, bytes32(uint256(uint160(asset))));
        IUpstreamMorphoVault(market.vault).setName(string.concat("Morpho ", IERC20Metadata(asset).symbol()));
        IUpstreamMorphoVault(market.vault).setSymbol(string.concat("mv", IERC20Metadata(asset).symbol()));
        IUpstreamMorphoVault(market.vault).setCurator(_OWNER);
        _curate(market.vault, abi.encodeCall(IUpstreamMorphoVault.setIsAllocator, (_OWNER, true)));
        market.allocation =
            IUpstreamMorphoAllocationFactory(_deployment.allocationFactory).createMorphoMarketV1AdapterV2(market.vault);
        _curate(market.vault, abi.encodeCall(IUpstreamMorphoVault.setAdapterRegistry, (_deployment.registry)));
        _curate(market.vault, abi.encodeCall(IUpstreamMorphoVault.addAdapter, (market.allocation)));
        bytes[3] memory ids = [
            abi.encode("this", market.allocation),
            abi.encode("collateralToken", collateral),
            abi.encode("this/marketParams", market.allocation, params)
        ];
        for (uint256 i; i < ids.length; ++i) {
            _curate(
                market.vault,
                abi.encodeCall(IUpstreamMorphoVault.increaseAbsoluteCap, (ids[i], uint256(type(uint128).max)))
            );
            _curate(market.vault, abi.encodeCall(IUpstreamMorphoVault.increaseRelativeCap, (ids[i], uint256(1e18))));
        }
        _curate(
            market.vault,
            abi.encodeCall(IUpstreamMorphoVault.abdicate, (IUpstreamMorphoVault.setAdapterRegistry.selector))
        );
        IUpstreamMorphoVault(market.vault).setMaxRate(2e18 / uint256(365 days));
        IUpstreamMorphoVault(market.vault).setLiquidityAdapterAndData(market.allocation, market.blueParams);
        if (_BROADCAST) vm.stopBroadcast();
        else vm.stopPrank();
    }

    function _curate(address vault, bytes memory data) internal {
        IUpstreamMorphoVault(vault).submit(data);
        (bool success, bytes memory result) = vault.call(data);
        if (!success) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
    }
}
