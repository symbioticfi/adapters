// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {VaultAccessManagerAddress} from "./VaultAccessManagerAddress.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {
    AccessManagerUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagerUpgradeable.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title ICreateXVaultAuthority
 * @notice Interface for CreateX CREATE3 deployment.
 */
interface ICreateXVaultAuthority {
    /// @notice Deploy a contract with CreateX sender-protected CREATE3.
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
}

/// @dev Locks implementation storage; proxy storage is initialized in its constructor.
contract VaultAccessManagerImplementation is AccessManagerUpgradeable {
    constructor() {
        _disableInitializers();
    }
}

/// @title DeployVaultAccessManagerScript
/// @notice Deploys a mainnet vault's automation authority without configuring any executor roles.
contract DeployVaultAccessManagerScript is Script {
    error AlreadyDeployed();
    error InvalidAddress();
    error InvalidDeployment();
    error WrongChain();

    /// @notice Return the deterministic automation authority for a vault.
    function predict(address vault) public pure returns (address) {
        return VaultAccessManagerAddress.predict(vault, VaultAccessManagerAddress.MAINNET_DEPLOYER);
    }

    /// @notice Deploy an initialized AccessManager proxy for a vault.
    function run(address vault, address admin, address proxyAdminOwner)
        public
        returns (address manager, address implementation)
    {
        if (block.chainid != 1) revert WrongChain();
        if (vault == address(0) || admin == address(0) || proxyAdminOwner == address(0)) revert InvalidAddress();
        manager = predict(vault);
        if (manager.code.length > 0) revert AlreadyDeployed();
        if (VaultAccessManagerAddress.CREATE_X.code.length == 0) revert InvalidDeployment();

        vm.startBroadcast(VaultAccessManagerAddress.MAINNET_DEPLOYER);
        implementation = address(new VaultAccessManagerImplementation());
        address deployed = ICreateXVaultAuthority(VaultAccessManagerAddress.CREATE_X)
            .deployCreate3(
                VaultAccessManagerAddress.salt(vault, VaultAccessManagerAddress.MAINNET_DEPLOYER),
                abi.encodePacked(
                    type(TransparentUpgradeableProxy).creationCode,
                    abi.encode(
                        implementation, proxyAdminOwner, abi.encodeCall(AccessManagerUpgradeable.initialize, (admin))
                    )
                )
            );
        vm.stopBroadcast();
        (bool isAdmin,) = AccessManagerUpgradeable(manager).hasRole(0, admin);
        if (deployed != manager || !isAdmin) revert InvalidDeployment();
        console2.log("Vault", vault);
        console2.log("AccessManager", manager);
        console2.log("Implementation", implementation);
    }
}
