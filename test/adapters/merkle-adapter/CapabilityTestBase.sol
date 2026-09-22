// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {merkleAdapterInitParams} from "test/helpers/MerkleInitialization.sol";

import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";

import {IGuardedCallsCapability} from "src/interfaces/merkle-adapter/capabilities/IGuardedCallsCapability.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

import {
    MerkleAdapterOracleMock,
    MerkleAdapterVaultMock,
    MerkleAdapterVaultRegistry
} from "test/adapters/MerkleAdapter.t.sol";
import {createMerkleAccountFactory} from "test/helpers/MerkleAccountFactory.sol";

abstract contract CapabilityManifestTestHelper {
    // Test-only literal used when constructing a new approved leaf.
    uint256 internal _minimum = 1.2e18;

    function _installCapability(MerkleAdapter target, address implementation, bytes4[] memory selectors) internal {
        address account = target.account();
        CapabilitiesRegistry registry = CapabilitiesRegistry(IMerkleAccount(account).CAPABILITIES_REGISTRY());
        registry.whitelistCapability(account, implementation, selectors);
        IMerkleAccount(account).addCapability(implementation);
    }

    function _guardedData(address target, address healthTarget, bytes memory data, bytes memory healthData)
        internal
        view
        returns (bytes memory)
    {
        IGuardedCallsCapability.Call[] memory calls = new IGuardedCallsCapability.Call[](1);
        calls[0] = IGuardedCallsCapability.Call({target: target, data: data});
        IGuardedCallsCapability.Check[] memory checks = new IGuardedCallsCapability.Check[](1);
        checks[0] = IGuardedCallsCapability.Check({
            query: IGuardedCallsCapability.Call({target: healthTarget, data: healthData}),
            offset: 0,
            observation: IGuardedCallsCapability.Observation.After,
            comparison: IGuardedCallsCapability.Comparison.GreaterOrEqual,
            bound: IGuardedCallsCapability.Bound({
                source: IGuardedCallsCapability.Source.Constant, value: _minimum, offset: 0
            })
        });
        return abi.encodeCall(IGuardedCallsCapability.execute, (calls, checks));
    }

    function _healthValue(address target, bytes memory data) internal view returns (uint256) {
        (bool success, bytes memory result) = target.staticcall(data);
        require(success);
        return abi.decode(result, (uint256));
    }

    function _guardedSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IGuardedCallsCapability.execute.selector;
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
