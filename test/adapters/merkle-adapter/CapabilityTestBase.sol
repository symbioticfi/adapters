// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle_adapter/CapabilitiesRegistry.sol";
import {CapabilitiesRegistryProposer} from "src/contracts/merkle_adapter/CapabilitiesRegistryProposer.sol";
import {RootRegistry} from "src/contracts/merkle_adapter/RootRegistry.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IBorrowCapability} from "src/interfaces/merkle_adapter/IBorrowCapability.sol";
import {ICoWSwapCapability} from "src/interfaces/merkle_adapter/ICoWSwapCapability.sol";
import {IThreeFCapability} from "src/interfaces/merkle_adapter/IThreeFCapability.sol";
import {IAssetRateLimits} from "src/interfaces/merkle_adapter/IAssetRateLimits.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";
import {
    MerkleAdapterOracleMock,
    MerkleAdapterVaultMock,
    MerkleAdapterVaultRegistry
} from "test/adapters/MerkleAdapter.t.sol";

abstract contract CapabilityManifestTestHelper {
    function _installCapability(MerkleAdapter target, address implementation, bytes4[] memory selectors) internal {
        CapabilitiesRegistry registry = CapabilitiesRegistry(target.CAPABILITIES_REGISTRY());
        CapabilitiesRegistryProposer proposer = CapabilitiesRegistryProposer(registry.PROPOSER());
        if (proposer.capabilityCodeHash(implementation) == bytes32(0)) {
            proposer.initCapability(implementation, selectors);
        }
        proposer.setProposedStatus(address(registry), address(target), implementation, true);
        registry.acceptCapability(address(target), implementation);
        target.addCapability(implementation);
    }

    function _borrowSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](10);
        selectors[0] = IBorrowCapability.borrow.selector;
        selectors[1] = IBorrowCapability.setMinHealthFactor.selector;
        selectors[2] = IBorrowCapability.borrowTarget.selector;
        selectors[3] = IBorrowCapability.borrowSelector.selector;
        selectors[4] = IBorrowCapability.borrowAsset.selector;
        selectors[5] = IBorrowCapability.healthFactorTarget.selector;
        selectors[6] = IBorrowCapability.healthFactorData.selector;
        selectors[7] = IBorrowCapability.healthFactorOffset.selector;
        selectors[8] = IBorrowCapability.minHealthFactor.selector;
        selectors[9] = IBorrowCapability.getHealthFactor.selector;
    }

    function _cowSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = ICoWSwapCapability.convert.selector;
        selectors[1] = ICoWSwapCapability.invalidateConvert.selector;
        selectors[2] = ICoWSwapCapability.activeOrderUid.selector;
        selectors[3] = ICoWSwapCapability.COW_SWAP_SETTLEMENT.selector;
        selectors[4] = ICoWSwapCapability.COW_SWAP_VAULT_RELAYER.selector;
    }

    function _threeFSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](14);
        selectors[0] = IThreeFCapability.REQUEST_WHITELIST.selector;
        selectors[1] = IThreeFCapability.FACILITY.selector;
        selectors[2] = IThreeFCapability.setMinYieldPerRequest.selector;
        selectors[3] = IThreeFCapability.minYieldPerRequest.selector;
        selectors[4] = IAssetRateLimits.setMaxAssetsPerDuration.selector;
        selectors[5] = IAssetRateLimits.remainingAssets.selector;
        selectors[6] = IThreeFCapability.mintRequest.selector;
        selectors[7] = IThreeFCapability.finalizeRequest.selector;
        selectors[8] = IThreeFCapability.requestsLength.selector;
        selectors[9] = IThreeFCapability.threeFPositionAssets.selector;
        selectors[10] = IThreeFCapability.requests.selector;
        selectors[11] = IThreeFCapability.requestIndex.selector;
        selectors[12] = IThreeFCapability.pendingAssets.selector;
        selectors[13] = IAssetRateLimits.assetLimits.selector;
    }
}

/// @dev Shared deployment and manifest helpers for tests exercising production Merkle routing.
abstract contract CapabilityTestBase is Test, CapabilityManifestTestHelper {
    MerkleAdapter internal adapter;
    RootRegistry internal roots;

    function _deployAdapter(address asset) internal {
        MerkleAdapterVaultRegistry vaults = new MerkleAdapterVaultRegistry();
        MerkleAdapterVaultMock vault = new MerkleAdapterVaultMock(asset);
        vaults.add(address(vault));
        AdapterFactory adapters = new AdapterFactory(address(this));
        MigratablesFactory oracles = new MigratablesFactory(address(this));
        oracles.whitelist(address(new MerkleAdapterOracleMock(address(oracles))));
        roots = new RootRegistry(address(this));
        CapabilitiesRegistry registry =
            new CapabilitiesRegistry(address(this), address(new CapabilitiesRegistryProposer(address(this))));
        adapters.whitelist(
            address(
                new MerkleAdapter(
                    address(vaults), address(adapters), address(oracles), address(roots), address(registry)
                )
            )
        );
        adapter = MerkleAdapter(
            payable(adapters.create(
                    1, address(this), abi.encode(address(vault), abi.encode(IMerkleAdapter.InitParams(address(this))))
                ))
        );
    }

    function _manage(address target, bytes memory data) internal returns (bytes memory) {
        return adapter.manage(_publishCall(target, data))[0];
    }

    function _publishCall(address target, bytes memory data) internal returns (IMerkleAdapter.Action[] memory actions) {
        bytes memory mask = new bytes(data.length);
        for (uint256 i; i < mask.length; ++i) {
            mask[i] = 0xff;
        }
        bytes32 leaf =
            keccak256(bytes.concat(keccak256(abi.encode(target, uint96(0), keccak256(mask), keccak256(data)))));
        roots.setRoot(address(adapter), leaf);
        adapter.acceptRoot(leaf);
        adapter.grantRole(leaf, address(this));
        actions = new IMerkleAdapter.Action[](1);
        actions[0] = IMerkleAdapter.Action(target, 0, data, mask, new bytes32[](0));
    }
}
