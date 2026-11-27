// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChain} from "../../base-chain/BaseChain.sol";
import {ThreeFPolicy} from "src/contracts/merkle-adapter/capabilities/policies/ThreeFPolicy.sol";

import {IThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";
import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {IMessageTransmitterV2, ITokenMessengerV2} from "../../utils/interfaces/ICCTPv2.sol";

/**
 * @title DeployBaseAliasPolicy
 * @notice Deploys the alias-controlled AccessManager and its ThreeFPolicy on Base.
 * @dev The manager owns the policy and holds the funds. The Ethereum MerkleAccount's alias authorizes its batches.
 * Gives the factory to the factories owner and writes a manifest for the Ethereum leaf builder and action scripts.
 */
contract DeployBaseAliasPolicyScript is Script {
    /* ERRORS */

    /// @notice Raised when an external Base dependency is missing or does not match its expected configuration.
    error InvalidBaseDependency();

    /// @notice Raised when an address in the environment is invalid.
    error InvalidConfig();

    /// @notice Raised when the deployed policy differs from the configuration.
    error InvalidDeployment();

    /// @notice Raised when the manifest path already exists.
    error ManifestAlreadyExists();

    /* STRUCTS */

    /**
     * @notice Deployment configuration read from the environment.
     * @param ethereumAccount Ethereum MerkleAccount whose alias controls the manager.
     * @param factoriesOwner Final owner of the ThreeFPolicy factory.
     */
    struct Config {
        address ethereumAccount;
        address factoriesOwner;
    }

    /**
     * @notice Deployed Base addresses.
     * @param manager Alias-controlled AccessManager on Base.
     * @param policyFactory ThreeFPolicy factory.
     * @param policyImplementation ThreeFPolicy implementation.
     * @param policy ThreeFPolicy bound to and owned by the manager.
     */
    struct Deployment {
        address manager;
        address policyFactory;
        address policyImplementation;
        address policy;
    }

    /* PUBLIC FUNCTIONS */

    /**
     * @notice Deploys the alias-controlled manager and its policy, then writes the manifest.
     * @dev Reads BASE_ALIAS_MANIFEST, BASE_ETHEREUM_ACCOUNT, BASE_FACTORIES_OWNER.
     * Refuses to overwrite a manifest. Run on Base with `forge script ... --rpc-url $BASE_RPC_URL --account <deployer>`, adding
     * `--broadcast` to send. A dry run (no `--broadcast`) checks everything but writes no manifest.
     */
    function run() public returns (Deployment memory deployed) {
        string memory manifest = vm.envString("BASE_ALIAS_MANIFEST");
        if (vm.exists(manifest)) revert ManifestAlreadyExists();
        Config memory config = Config({
            ethereumAccount: vm.envAddress("BASE_ETHEREUM_ACCOUNT"),
            factoriesOwner: vm.envAddress("BASE_FACTORIES_OWNER")
        });
        address deployer = _deployer();
        _validate(config);
        uint256 startBlock = block.number;
        _startBroadcast();
        deployed = _deploy(config, deployer);
        _stopBroadcast();
        _verify(config, deployed);
        if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) {
            console2.log("Dry run: the manifest was not written. Add --broadcast to deploy and write", manifest);
            return deployed;
        }
        _writeManifest(manifest, startBlock, config, deployed);
    }

    /* INTERNAL FUNCTIONS */

    /**
     * @notice Deploys the manager and its versioned policy, then hands over the factory.
     * @dev The deployer owns the factory only while it whitelists the implementation and creates the policy.
     */
    function _deploy(Config memory config, address deployer) internal returns (Deployment memory deployed) {
        deployed.manager = address(new AccessManager(BaseChain.l2Alias(config.ethereumAccount)));
        deployed.policyFactory = address(new MigratablesFactory(deployer));
        deployed.policyImplementation = address(
            new ThreeFPolicy(deployed.policyFactory, BaseChain.THREE_F_REQUESTS_FACTORY, BaseChain.THREE_F_FACILITY)
        );
        MigratablesFactory(deployed.policyFactory).whitelist(deployed.policyImplementation);
        deployed.policy = MigratablesFactory(deployed.policyFactory)
            .create(
                MigratablesFactory(deployed.policyFactory).lastVersion(), deployed.manager, abi.encode(deployed.manager)
            );
        Ownable(deployed.policyFactory).transferOwnership(config.factoriesOwner);
    }

    /**
     * @notice Checks the chain, the external Base dependencies and the configuration before broadcasting.
     * @dev The alias must have empty code so the L1 MerkleAccount controls calls from it.
     */
    function _validate(Config memory config) internal view {
        if (
            block.chainid != BaseChain.BASE_CHAIN_ID || BaseChain.THREE_F_REQUESTS_FACTORY.code.length == 0
                || BaseChain.THREE_F_FACILITY.code.length == 0 || IERC20Metadata(BaseChain.BASE_USDC).decimals() != 6
                || ITokenMessengerV2(BaseChain.TOKEN_MESSENGER).localMessageTransmitter()
                    != BaseChain.MESSAGE_TRANSMITTER
                || IMessageTransmitterV2(BaseChain.MESSAGE_TRANSMITTER).localDomain() != BaseChain.BASE_DOMAIN
        ) revert InvalidBaseDependency();
        if (
            config.ethereumAccount == address(0) || config.factoriesOwner == address(0)
                || BaseChain.l2Alias(config.ethereumAccount).code.length != 0
        ) revert InvalidConfig();
    }

    /**
     * @notice Checks the alias's immediate admin role, the policy binding, and the factory owner.
     * @dev Runs against the simulated or broadcast state, so a dry run proves the configuration too.
     */
    function _verify(Config memory config, Deployment memory deployed) internal view {
        (bool isAdmin, uint32 delay) = AccessManager(deployed.manager)
            .hasRole(AccessManager(deployed.manager).ADMIN_ROLE(), BaseChain.l2Alias(config.ethereumAccount));
        if (
            !isAdmin || delay > 0 || IThreeFPolicy(deployed.policy).account() != deployed.manager
                || Ownable(deployed.policy).owner() != deployed.manager
                || IThreeFPolicy(deployed.policy).REQUESTS_FACTORY() != BaseChain.THREE_F_REQUESTS_FACTORY
                || IThreeFPolicy(deployed.policy).FACILITY() != BaseChain.THREE_F_FACILITY
                || Ownable(deployed.policyFactory).owner() != config.factoriesOwner
        ) revert InvalidDeployment();
    }

    /**
     * @notice Writes the alias manifest read by the alias leaf builder and action scripts.
     * @dev Records the Ethereum account, its alias and the manager and policy on Base.
     */
    function _writeManifest(string memory path, uint256 startBlock, Config memory config, Deployment memory deployed)
        internal
    {
        vm.serializeAddress("threeF", "policyFactory", deployed.policyFactory);
        vm.serializeAddress("threeF", "policyImplementation", deployed.policyImplementation);
        vm.serializeAddress("threeF", "requestsFactory", BaseChain.THREE_F_REQUESTS_FACTORY);
        vm.serializeAddress("threeF", "facility", BaseChain.THREE_F_FACILITY);
        string memory threeF = vm.serializeAddress("threeF", "policy", deployed.policy);
        vm.serializeUint("manifest", "chainId", BaseChain.BASE_CHAIN_ID);
        vm.serializeAddress("manifest", "manager", deployed.manager);
        vm.serializeUint("manifest", "fromBlock", startBlock);
        vm.serializeAddress("manifest", "ethereumAccount", config.ethereumAccount);
        vm.serializeAddress("manifest", "alias", BaseChain.l2Alias(config.ethereumAccount));
        vm.serializeAddress("manifest", "factoriesOwner", config.factoriesOwner);
        vm.writeJson(vm.serializeString("manifest", "threeF", ""), path);
        vm.writeJson(threeF, path, ".threeF");
    }

    /// @notice Starts broadcasting from the script sender. Test harnesses override it.
    function _startBroadcast() internal virtual {
        vm.startBroadcast();
    }

    /// @notice Stops broadcasting. Test harnesses override it.
    function _stopBroadcast() internal virtual {
        vm.stopBroadcast();
    }

    /// @notice Returns the address that sends the deployment transactions and temporarily owns the factory.
    function _deployer() internal virtual returns (address sender) {
        (, sender,) = vm.readCallers();
    }
}
