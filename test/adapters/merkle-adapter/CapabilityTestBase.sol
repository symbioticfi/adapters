// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {Test} from "forge-std/Test.sol";
import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IBorrowCapability} from "src/interfaces/merkle-adapter/capabilities/IBorrowCapability.sol";
import {ICoWSwapCapability} from "src/interfaces/merkle-adapter/capabilities/ICoWSwapCapability.sol";
import {IThreeFCapability} from "src/interfaces/merkle-adapter/capabilities/IThreeFCapability.sol";
import {IAssetRateLimits} from "src/interfaces/merkle-adapter/IAssetRateLimits.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";
import {
    MerkleAdapterOracleMock,
    MerkleAdapterVaultMock,
    MerkleAdapterVaultRegistry
} from "test/adapters/MerkleAdapter.t.sol";

abstract contract CapabilityManifestTestHelper {
    function _installCapability(MerkleAdapter target, address implementation, bytes4[] memory selectors) internal {
        CapabilitiesRegistry registry = CapabilitiesRegistry(target.CAPABILITIES_REGISTRY());
        registry.whitelistCapability(address(target), implementation, selectors);
        target.addCapability(implementation);
    }

    function _borrowSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IBorrowCapability.borrow.selector;
        selectors[1] = IBorrowCapability.setHealthFactor.selector;
        selectors[2] = IBorrowCapability.minHealthFactor.selector;
        selectors[3] = IBorrowCapability.getHealthFactor.selector;
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
    IMerkleAdapter.Action internal _healthUpdate;
    bytes32 internal _healthUpdateRoot;
    bytes32 internal _healthUpdateId;

    function _setHealthFactor(bytes32 id, uint256 minimum) internal {
        if (_healthUpdateRoot != adapter.merkleRoot() || _healthUpdateId != id) {
            _healthUpdate = _healthFactorAction(id);
            _healthUpdateId = id;
            _healthUpdateRoot = _healthFactorLeaf(_healthUpdate);
            roots.setRoot(address(adapter), _healthUpdateRoot);
            adapter.acceptRoot(_healthUpdateRoot);
            adapter.grantRole(_healthUpdateRoot, address(this));
        }
        adapter.manage(_minimumCalls(minimum));
    }

    function _minimumCalls(uint256 minimum) internal view returns (IMerkleAdapter.Action[] memory calls) {
        calls = new IMerkleAdapter.Action[](1);
        calls[0] = _healthUpdate;
        calls[0].data = abi.encodeCall(IBorrowCapability.setHealthFactor, (_healthUpdateId, minimum));
    }

    /// @dev Adds a curator-only setter leaf as a sibling of the existing execution tree.
    function _includeHealthFactorLeaf(IMerkleAdapter.Action[] memory actions, bytes32 id) internal {
        bytes32 previousRoot = adapter.merkleRoot();
        IMerkleAdapter.Action memory setter = _healthFactorAction(id);
        bytes32 leaf = _healthFactorLeaf(setter);
        bytes32 root = previousRoot < leaf
            ? keccak256(abi.encodePacked(previousRoot, leaf))
            : keccak256(abi.encodePacked(leaf, previousRoot));
        for (uint256 i; i < actions.length; ++i) {
            bytes32[] memory proof = new bytes32[](actions[i].proof.length + 1);
            for (uint256 j; j < actions[i].proof.length; ++j) {
                proof[j] = actions[i].proof[j];
            }
            proof[proof.length - 1] = leaf;
            actions[i].proof = proof;
        }
        setter.proof = new bytes32[](1);
        setter.proof[0] = previousRoot;
        _healthUpdate = setter;
        _healthUpdateId = id;
        _healthUpdateRoot = root;
        roots.setRoot(address(adapter), root);
        adapter.acceptRoot(root);
        adapter.grantRole(leaf, address(this));
    }

    function _healthFactorAction(bytes32 id) internal view returns (IMerkleAdapter.Action memory action) {
        bytes memory data = abi.encodeCall(IBorrowCapability.setHealthFactor, (id, uint256(0)));
        bytes memory mask = new bytes(data.length);
        for (uint256 i = 36; i < 68; ++i) {
            mask[i] = 0xff;
        }
        return IMerkleAdapter.Action(address(adapter), 0, data, mask, new bytes32[](0));
    }

    function _healthFactorLeaf(IMerkleAdapter.Action memory action) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(abi.encode(action.target, bytes1(0), keccak256(action.dataMask), keccak256(action.data)))
            )
        );
    }

    function _deployAdapter(address asset) internal {
        MerkleAdapterVaultRegistry vaults = new MerkleAdapterVaultRegistry();
        MerkleAdapterVaultMock vault = new MerkleAdapterVaultMock(asset);
        vaults.add(address(vault));
        AdapterFactory adapters = new AdapterFactory(address(this));
        MigratablesFactory oracles = new MigratablesFactory(address(this));
        oracles.whitelist(address(new MerkleAdapterOracleMock(address(oracles))));
        roots = new RootRegistry(address(this));
        CapabilitiesRegistry registry = new CapabilitiesRegistry(address(this));
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
        bytes32 leaf =
            keccak256(bytes.concat(keccak256(abi.encode(target, bytes1(0), keccak256(mask), keccak256(data)))));
        roots.setRoot(address(adapter), leaf);
        adapter.acceptRoot(leaf);
        adapter.grantRole(leaf, address(this));
        actions = new IMerkleAdapter.Action[](1);
        actions[0] = IMerkleAdapter.Action(target, 0, data, mask, new bytes32[](0));
    }
}
