// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {OP_CALL, OP_LESS_OR_EQUAL, OP_READ, SRC_RESULT} from "src/interfaces/merkle-adapter/IRecipes.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

import {
    MerkleAdapterOracleMock,
    MerkleAdapterVaultMock,
    MerkleAdapterVaultRegistry
} from "test/adapters/MerkleAdapter.t.sol";
import {createMerkleAccountFactory} from "test/helpers/MerkleAccountFactory.sol";
import {merkleAdapterInitParams} from "test/helpers/MerkleInitialization.sol";

abstract contract CapabilityManifestTestHelper {
    // Test-only literal used when constructing a new approved leaf.
    uint256 internal _minimum = 1.2e18;

    function _installCapability(MerkleAdapter target, address implementation, bytes4[] memory selectors) internal {
        address account = target.account();
        CapabilitiesRegistry registry = CapabilitiesRegistry(IMerkleAccount(account).CAPABILITIES_REGISTRY());
        registry.whitelistCapability(account, implementation, selectors);
        IMerkleAccount(account).addCapability(implementation);
    }

    function _checkedCallData(address target, address healthTarget, bytes memory data, bytes memory healthData)
        internal
        view
        returns (bytes memory)
    {
        bytes[] memory queries = new bytes[](1);
        queries[0] = abi.encode(healthTarget, healthData, new uint256[](0), uint256(0));
        bytes[] memory steps = new bytes[](3);
        steps[0] = abi.encodePacked(OP_CALL, abi.encode(target, data, new uint256[](0)));
        steps[1] = abi.encodePacked(OP_READ, abi.encode(uint256(0)));
        steps[2] = abi.encodePacked(OP_LESS_OR_EQUAL, abi.encode(_minimum, (uint256(SRC_RESULT) << 216) | 1));
        return abi.encodeCall(IRecipeCapability.execute, (queries, steps, new uint256[](0)));
    }

    /// @dev Locate a nested word from two encodings differing only in that word.
    function _changedWord(bytes memory zero, bytes memory marked) internal pure returns (uint256) {
        require(zero.length == marked.length);
        for (uint256 i; i + 32 <= zero.length; ++i) {
            if (zero[i] != marked[i]) return i;
        }
        revert("Unchanged recipe word");
    }

    function _checkedCallWordOffset(
        address target,
        address healthTarget,
        bytes memory data,
        bytes memory healthData,
        uint256 offset
    ) internal view returns (uint256) {
        bytes memory cleared = bytes.concat(data);
        bytes memory marked = bytes.concat(data);
        assembly ("memory-safe") {
            mstore(add(add(cleared, 32), offset), 0)
            mstore(add(add(marked, 32), offset), not(0))
        }
        return _changedWord(
            _checkedCallData(target, healthTarget, cleared, healthData),
            _checkedCallData(target, healthTarget, marked, healthData)
        );
    }

    function _healthValue(address target, bytes memory data) internal view returns (uint256) {
        (bool success, bytes memory result) = target.staticcall(data);
        require(success);
        return abi.decode(result, (uint256));
    }

    function _recipeSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IRecipeCapability.execute.selector;
    }
}

/// @dev Shared deployment and manifest helpers for tests exercising production Merkle routing.
abstract contract CapabilityTestBase is Test, CapabilityManifestTestHelper {
    MerkleAdapter internal adapter;
    address internal account;
    RootRegistry internal roots;

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
                    address(vaults),
                    address(adapters),
                    address(oracles),
                    createMerkleAccountFactory(address(this), address(adapters), address(roots), address(registry))
                )
            )
        );
        adapter = MerkleAdapter(
            payable(adapters.create(
                    1, address(this), abi.encode(address(vault), abi.encode(merkleAdapterInitParams(address(this))))
                ))
        );
        account = adapter.account();
    }

    function _manage(address target, bytes memory data) internal returns (bytes memory) {
        return MerkleAccount(payable(account)).manage(_publishCall(target, data))[0];
    }

    function _publishCall(address target, bytes memory data) internal returns (IMerkleAccount.Action[] memory actions) {
        bytes memory mask = new bytes(data.length);
        bytes32 leaf =
            keccak256(bytes.concat(keccak256(abi.encode(target, bytes1(0), keccak256(mask), keccak256(data)))));
        roots.setRoot(account, leaf);
        MerkleAccount(payable(account)).acceptRoot(leaf);
        MerkleAccount(payable(account)).grantRole(leaf, address(this));
        actions = new IMerkleAccount.Action[](1);
        actions[0] =
            IMerkleAccount.Action({target: target, value: 0, data: data, dataMask: mask, proof: new bytes32[](0)});
    }
}
