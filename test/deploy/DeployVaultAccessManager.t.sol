// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DeployVaultAccessManagerScript} from "../../script/deploy/merkle/DeployVaultAccessManager.s.sol";
import {ICreateXVaultAuthority} from "../../script/deploy/merkle/DeployVaultAccessManager.s.sol";
import {VaultAccessManagerAddress} from "../../script/deploy/merkle/VaultAccessManagerAddress.sol";

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    AccessManagerUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagerUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Test} from "forge-std/Test.sol";

contract CreateXTarget {
    uint256 public value = 1;
}

contract DeployVaultAccessManagerTest is Test {
    address internal constant VAULT = 0x491eFeD81DB47D208DB7a90A8a8d3a89821F91B5;
    address internal admin = makeAddr("admin");
    address internal proxyAdminOwner = makeAddr("proxy admin");
    DeployVaultAccessManagerScript internal script;

    function setUp() public {
        vm.chainId(1);
        vm.deal(VaultAccessManagerAddress.MAINNET_DEPLOYER, 100 ether);
        vm.etch(
            VaultAccessManagerAddress.CREATE_X, vm.parseJsonBytes(vm.readFile("test/fixtures/createx.json"), ".runtime")
        );
        script = new DeployVaultAccessManagerScript();
    }

    function testDeploysInitializedTransparentProxyAtPredictedAddress() public {
        address predicted = script.predict(VAULT);
        assertEq(predicted, 0xcBB8D0D393D13b59C3BECB447E421b7c38f007df);
        (address manager, address implementation) = script.run(VAULT, admin, proxyAdminOwner);
        assertEq(manager, predicted);
        (bool active,) = AccessManagerUpgradeable(manager).hasRole(0, admin);
        assertTrue(active);
        (bool permitted, uint32 delay) = AccessManagerUpgradeable(manager).canCall(address(this), address(1), bytes4(0));
        assertFalse(permitted);
        assertEq(delay, 0);
        bytes32 implementationSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        bytes32 adminSlot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        assertEq(address(uint160(uint256(vm.load(manager, implementationSlot)))), implementation);
        assertEq(ProxyAdmin(address(uint160(uint256(vm.load(manager, adminSlot))))).owner(), proxyAdminOwner);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        AccessManagerUpgradeable(implementation).initialize(address(this));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        AccessManagerUpgradeable(manager).initialize(address(this));
    }

    function testCannotFrontRunProtectedVaultAddress() public {
        vm.prank(makeAddr("attacker"));
        address other = ICreateXVaultAuthority(VaultAccessManagerAddress.CREATE_X)
            .deployCreate3(
                VaultAccessManagerAddress.salt(VAULT, VaultAccessManagerAddress.MAINNET_DEPLOYER),
                type(CreateXTarget).creationCode
            );
        assertTrue(other != script.predict(VAULT));
        (address manager,) = script.run(VAULT, admin, proxyAdminOwner);
        assertEq(manager, script.predict(VAULT));
    }

    function testDifferentVaultAndConfiguration() public {
        address secondVault = address(0x1234);
        address first = script.predict(VAULT);
        address second = script.predict(secondVault);
        assertEq(second, 0x34Fd65B522f1091C35125BdA05350BD82fCD9895);
        assertTrue(first != second);
        (address manager,) = script.run(VAULT, admin, proxyAdminOwner);
        (address other,) = script.run(secondVault, proxyAdminOwner, admin);
        assertEq(manager, first);
        assertEq(other, second);
        vm.expectRevert(DeployVaultAccessManagerScript.AlreadyDeployed.selector);
        script.run(VAULT, admin, proxyAdminOwner);
    }

    function testRejectsInvalidConfiguration() public {
        vm.chainId(11_155_111);
        vm.expectRevert(DeployVaultAccessManagerScript.WrongChain.selector);
        script.run(VAULT, admin, proxyAdminOwner);
        vm.chainId(1);
        vm.expectRevert(DeployVaultAccessManagerScript.InvalidAddress.selector);
        script.run(address(0), admin, proxyAdminOwner);
        vm.expectRevert(DeployVaultAccessManagerScript.InvalidAddress.selector);
        script.run(VAULT, address(0), proxyAdminOwner);
        vm.expectRevert(DeployVaultAccessManagerScript.InvalidAddress.selector);
        script.run(VAULT, admin, address(0));
        vm.etch(VaultAccessManagerAddress.CREATE_X, "");
        vm.expectRevert(DeployVaultAccessManagerScript.InvalidDeployment.selector);
        script.run(VAULT, admin, proxyAdminOwner);
    }
}
