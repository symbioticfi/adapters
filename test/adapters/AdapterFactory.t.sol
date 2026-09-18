// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {Test} from "forge-std/Test.sol";

import {Adapter} from "../../src/contracts/Adapter.sol";
import {AdapterFactory} from "../../src/contracts/AdapterFactory.sol";
import {MigratableEntityProxy} from "@symbioticfi/core/src/contracts/common/MigratableEntityProxy.sol";
import {Registry} from "@symbioticfi/core/src/contracts/common/Registry.sol";

import {IAdapter} from "../../src/interfaces/IAdapter.sol";
import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";

import {Token} from "../mocks/Token.sol";

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract AdapterFactoryTest is Test {
    MockRegistry internal vaultFactory;
    AdapterFactory internal factory;
    MockAdapter internal implementation;
    Token internal assetToken;

    address internal owner = makeAddr("owner");
    address internal curator = makeAddr("curator");
    address internal vault;

    function setUp() public {
        vaultFactory = new MockRegistry();
        factory = new AdapterFactory(owner);
        assetToken = new Token("Asset");
        vault = address(new MockVault(address(assetToken)));
        implementation = new MockAdapter(address(vaultFactory), address(factory));

        vm.prank(owner);
        factory.whitelist(address(implementation));
    }

    /// @notice Confirms failed initialization rolls back the predicted proxy deployment and registry entry.
    function test_CreateRevertsForNonVault() public {
        bytes memory data = _initData(vault);
        address predicted = _predictedAdapter(data);

        vm.expectRevert(IAdapter.InvalidVault.selector);
        factory.create(1, curator, data);

        assertEq(factory.totalEntities(), 0);
        assertFalse(factory.isEntity(predicted));
        assertEq(predicted.code.length, 0);
    }

    function test_InitializeRevertsForNonVault() public {
        bytes memory data = _initData(vault);
        bytes memory initData = abi.encodeCall(IMigratableEntity.initialize, (1, curator, data));

        vm.expectRevert(IAdapter.InvalidVault.selector);
        new MigratableEntityProxy(address(implementation), initData);
    }

    /// @notice Confirms factory CREATE2 salting, registry registration, adapter initialization, and owner setup.
    function test_CreateUsesMigratablesFactorySaltAndInitializesAdapterVault() public {
        vaultFactory.add(vault);

        bytes memory data = _initData(vault);
        bytes memory initCode =
            abi.encodePacked(type(MigratableEntityProxy).creationCode, abi.encode(address(implementation), ""));
        address predicted = Create2.computeAddress(
            keccak256(abi.encode(uint256(0), uint64(1), curator, data)), keccak256(initCode), address(factory)
        );

        address adapter = factory.create(1, curator, data);

        assertEq(adapter, predicted);
        assertTrue(factory.isEntity(adapter));
        assertEq(IAdapter(adapter).vault(), vault);
        assertEq(IMigratableEntity(adapter).FACTORY(), address(factory));
        assertEq(IMigratableEntity(adapter).version(), 1);
        assertEq(Ownable(adapter).owner(), curator);
    }

    /// @notice Creates an adapter through the factory and confirms its atomic initialization rejects a second call.
    function test_CreateInitializedAdapterRejectsReinitialization() public {
        vaultFactory.add(vault);
        address adapter = factory.create(1, curator, _initData(vault));

        vm.expectRevert(IMigratableEntity.AlreadyInitialized.selector);
        IMigratableEntity(adapter).initialize(1, curator, _initData(vault));
    }

    function test_CreateAllowsMultipleAdaptersForSameVault() public {
        vaultFactory.add(vault);

        bytes memory data = _initData(vault);

        address firstAdapter = factory.create(1, curator, data);
        address secondAdapter = factory.create(1, curator, data);

        assertNotEq(firstAdapter, secondAdapter);
        assertTrue(factory.isEntity(firstAdapter));
        assertTrue(factory.isEntity(secondAdapter));
        assertEq(IAdapter(firstAdapter).vault(), vault);
        assertEq(IAdapter(secondAdapter).vault(), vault);
    }

    function test_SeparateFactoriesCanCreateForSameVault() public {
        vaultFactory.add(vault);

        AdapterFactory otherFactory = new AdapterFactory(owner);
        MockAdapter otherImplementation = new MockAdapter(address(vaultFactory), address(otherFactory));
        vm.prank(owner);
        otherFactory.whitelist(address(otherImplementation));

        address adapter = factory.create(1, curator, _initData(vault));
        address otherAdapter = otherFactory.create(1, curator, _initData(vault));

        assertNotEq(adapter, otherAdapter);
        assertEq(IAdapter(otherAdapter).vault(), vault);
    }

    function _initData(address targetVault) internal view returns (bytes memory) {
        return abi.encode(targetVault, "");
    }

    /// @dev Computes the deterministic proxy address used by `MigratablesFactory.create` for a test payload.
    function _predictedAdapter(bytes memory data) internal view returns (address) {
        bytes memory initCode =
            abi.encodePacked(type(MigratableEntityProxy).creationCode, abi.encode(address(implementation), ""));
        bytes32 salt = keccak256(abi.encode(factory.totalEntities(), uint64(1), curator, data));
        return Create2.computeAddress(salt, keccak256(initCode), address(factory));
    }
}

contract MockRegistry is Registry {
    function add(address entity) external {
        _addEntity(entity);
    }
}

contract MockAdapter is Adapter {
    constructor(address vaultFactory, address adapterFactory) Adapter(vaultFactory, adapterFactory) {}

    function totalAssets() public view override returns (uint256) {
        return 0;
    }

    function allocatable() public view override returns (uint256) {
        return type(uint256).max;
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        return amount;
    }

    function _deallocate(uint256) internal override returns (uint256) {
        return 0;
    }
}

contract MockVault {
    address public immutable asset;

    constructor(address asset_) {
        asset = asset_;
    }
}
