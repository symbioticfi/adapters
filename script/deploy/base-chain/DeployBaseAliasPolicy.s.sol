// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChain} from "../../base-chain/BaseChain.sol";
import {ThreeFPolicy} from "src/contracts/merkle-adapter/capabilities/policies/ThreeFPolicy.sol";

import {IThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";
import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {IMessageTransmitterV2, ITokenMessengerV2} from "../../utils/interfaces/ICCTPv2.sol";

/**
 * @title DeployBaseAliasPolicy
 * @notice Script deploying the ThreeFPolicy for the alias-only 3F flow on Base, where the Ethereum MerkleAccount's
 * alias is the 3F maker and there is no Safe.
 * @dev Deploys a policy factory and the ThreeFPolicy implementation, then creates one policy whose owner and account
 * are the alias. Only a portal deposit from the MerkleAccount can then configure, charge or migrate the policy.
 * Gives the factory to the factories owner. Writes a manifest that the alias leaf builder and action scripts read.
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
     * @param ethereumAccount Ethereum MerkleAccount whose alias owns and uses the policy.
     * @param factoriesOwner Final owner of the ThreeFPolicy factory, which whitelists new policy versions.
     */
    struct Config {
        address ethereumAccount;
        address factoriesOwner;
    }

    /**
     * @notice Deployed Base addresses.
     * @param policyFactory ThreeFPolicy factory.
     * @param policyImplementation ThreeFPolicy implementation.
     * @param policy ThreeFPolicy bound to and owned by the alias.
     */
    struct Deployment {
        address policyFactory;
        address policyImplementation;
        address policy;
    }

    /* PUBLIC FUNCTIONS */

    /**
     * @notice Deploys the alias ThreeFPolicy, then writes the manifest.
     * @dev Reads BASE_ALIAS_MANIFEST, BASE_ETHEREUM_ACCOUNT and BASE_FACTORIES_OWNER. Refuses to overwrite a
     * manifest. Run on Base with `forge script ... --rpc-url $BASE_RPC_URL --account <deployer>`, adding
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
     * @notice Deploys the factory and implementation, creates the alias policy and hands over the factory.
     * @dev The deployer owns the factory only while it whitelists the implementation and creates the policy.
     */
    function _deploy(Config memory config, address deployer) internal returns (Deployment memory deployed) {
        address l2Alias = BaseChain.l2Alias(config.ethereumAccount);
        deployed.policyFactory = address(new MigratablesFactory(deployer));
        deployed.policyImplementation = address(
            new ThreeFPolicy(deployed.policyFactory, BaseChain.THREE_F_REQUESTS_FACTORY, BaseChain.THREE_F_FACILITY)
        );
        MigratablesFactory(deployed.policyFactory).whitelist(deployed.policyImplementation);
        deployed.policy = MigratablesFactory(deployed.policyFactory)
            .create(MigratablesFactory(deployed.policyFactory).lastVersion(), l2Alias, abi.encode(l2Alias));
        Ownable(deployed.policyFactory).transferOwnership(config.factoriesOwner);
    }

    /**
     * @notice Checks the chain, the external Base dependencies and the configuration before broadcasting.
     * @dev The alias must have no code: a contract there would not be the portal alias of the MerkleAccount.
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
     * @notice Checks that the alias is the policy account and owner, and that the factories owner holds the factory.
     * @dev Runs against the simulated or broadcast state, so a dry run proves the configuration too.
     */
    function _verify(Config memory config, Deployment memory deployed) internal view {
        address l2Alias = BaseChain.l2Alias(config.ethereumAccount);
        if (
            IThreeFPolicy(deployed.policy).account() != l2Alias || Ownable(deployed.policy).owner() != l2Alias
                || IThreeFPolicy(deployed.policy).REQUESTS_FACTORY() != BaseChain.THREE_F_REQUESTS_FACTORY
                || IThreeFPolicy(deployed.policy).FACILITY() != BaseChain.THREE_F_FACILITY
                || Ownable(deployed.policyFactory).owner() != config.factoriesOwner
        ) revert InvalidDeployment();
    }

    /**
     * @notice Writes the alias manifest read by the alias leaf builder and action scripts.
     * @dev Records the Ethereum account, its alias and the ThreeFPolicy addresses.
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
