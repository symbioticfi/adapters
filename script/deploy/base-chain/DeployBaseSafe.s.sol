// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChain} from "../../base-chain/BaseChain.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";
import {ThreeFPolicy} from "src/contracts/merkle-adapter/capabilities/policies/ThreeFPolicy.sol";

import {IThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";
import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {IMessageTransmitterV2, ITokenMessengerV2} from "../../utils/interfaces/ICCTPv2.sol";
import {Enum, IGnosisSafe} from "../../utils/interfaces/IGnosisSafe.sol";
import {IMultiSend, ISafeModules, ISafeProxyFactory} from "../../utils/interfaces/ISafeModules.sol";

/**
 * @title DeployBaseSafe
 * @notice Script deploying the Base Safe that the Ethereum MerkleAccount controls through the Base portal, plus the
 * RecipeCapability it delegatecalls and the ThreeFPolicy bound to it.
 * @dev Deploys a Safe v1.4.1 with the deployer as its only owner, then in one Safe transaction enables the
 * MerkleAccount's L2 alias and the Safe itself as modules, makes the alias the only owner with threshold 1 and
 * removes the deployer. No key on Base controls the Safe: every action, admin changes included, goes through the
 * Ethereum MerkleAccount root. The Safe owns its policy, so only the Safe can migrate it. Writes a manifest that the
 * Ethereum action scripts read.
 */
contract DeployBaseSafeScript is Script {
    /* ERRORS */

    /// @notice Raised when an external Base dependency is missing or does not match its expected configuration.
    error InvalidBaseDependency();

    /// @notice Raised when an address in the environment is invalid.
    error InvalidConfig();

    /// @notice Raised when the deployed Safe, modules or policy differ from the configuration.
    error InvalidDeployment();

    /// @notice Raised when the manifest path already exists.
    error ManifestAlreadyExists();

    /* STRUCTS */

    /**
     * @notice Deployment configuration read from the environment.
     * @param ethereumAccount Ethereum MerkleAccount whose alias becomes the only Safe owner and a Safe module.
     * @param saltNonce Safe CREATE2 salt nonce.
     * @param factoriesOwner Final owner of the ThreeFPolicy factory, which whitelists new policy versions.
     */
    struct Config {
        address ethereumAccount;
        uint256 saltNonce;
        address factoriesOwner;
    }

    /**
     * @notice Deployed Base addresses.
     * @param safe Base Safe.
     * @param recipeCapability RecipeCapability delegatecalled by the Safe.
     * @param policyFactory ThreeFPolicy factory.
     * @param policyImplementation ThreeFPolicy implementation.
     * @param policy ThreeFPolicy bound to and owned by the Safe.
     */
    struct Deployment {
        address safe;
        address recipeCapability;
        address policyFactory;
        address policyImplementation;
        address policy;
    }

    /* PUBLIC FUNCTIONS */

    /**
     * @notice Deploys and configures the Base Safe, RecipeCapability and ThreeFPolicy, then writes the manifest.
     * @dev Reads BASE_MANIFEST, BASE_ETHEREUM_ACCOUNT, BASE_SAFE_SALT_NONCE and BASE_FACTORIES_OWNER. Refuses to overwrite a manifest. Run on Base with
     * `forge script ... --rpc-url $BASE_RPC_URL --account <deployer>`, adding `--broadcast` to send. A dry run
     * (no `--broadcast`) checks everything but writes no manifest, so the broadcast run can write it.
     */
    function run() public returns (Deployment memory deployed) {
        string memory manifest = vm.envString("BASE_MANIFEST");
        if (vm.exists(manifest)) revert ManifestAlreadyExists();
        Config memory config = Config({
            ethereumAccount: vm.envAddress("BASE_ETHEREUM_ACCOUNT"),
            saltNonce: vm.envUint("BASE_SAFE_SALT_NONCE"),
            factoriesOwner: vm.envAddress("BASE_FACTORIES_OWNER")
        });
        address deployer = _deployer();
        _validate(config, deployer);
        uint256 startBlock = block.number;
        _startBroadcast();
        deployed = _deploy(config, deployer);
        _stopBroadcast();
        _verify(config, deployer, deployed);
        if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) {
            console2.log("Dry run: the manifest was not written. Add --broadcast to deploy and write", manifest);
            return deployed;
        }
        _writeManifest(manifest, startBlock, config, deployed);
    }

    /* INTERNAL FUNCTIONS */

    /**
     * @notice Deploys the contracts and configures the Safe in one Safe transaction signed by the deployer.
     * @dev The deployer approves the Safe transaction as `msg.sender` (signature type 1). MultiSendCallOnly runs
     * the batch from the Safe, which authorizes `enableModule` and the owner changes. Safe inserts the alias at the
     * head of its owner list, so the alias precedes the deployer when the deployer is removed.
     */
    function _deploy(Config memory config, address deployer) internal returns (Deployment memory deployed) {
        deployed.recipeCapability = address(new RecipeCapability());
        address[] memory initialOwners = new address[](1);
        initialOwners[0] = deployer;
        deployed.safe = ISafeProxyFactory(BaseChain.SAFE_PROXY_FACTORY)
            .createProxyWithNonce(
                BaseChain.SAFE_L2_SINGLETON,
                abi.encodeCall(
                    IGnosisSafe.setup,
                    (initialOwners, 1, address(0), "", BaseChain.SAFE_FALLBACK_HANDLER, address(0), 0, address(0))
                ),
                config.saltNonce
            );

        deployed.policyFactory = address(new MigratablesFactory(deployer));
        deployed.policyImplementation = address(
            new ThreeFPolicy(deployed.policyFactory, BaseChain.THREE_F_REQUESTS_FACTORY, BaseChain.THREE_F_FACILITY)
        );
        MigratablesFactory(deployed.policyFactory).whitelist(deployed.policyImplementation);
        deployed.policy = MigratablesFactory(deployed.policyFactory)
            .create(MigratablesFactory(deployed.policyFactory).lastVersion(), deployed.safe, abi.encode(deployed.safe));
        Ownable(deployed.policyFactory).transferOwnership(config.factoriesOwner);

        address l2Alias = BaseChain.l2Alias(config.ethereumAccount);
        bytes memory calls = abi.encodePacked(
            _multiSendCall(deployed.safe, abi.encodeCall(ISafeModules.enableModule, (l2Alias))),
            _multiSendCall(deployed.safe, abi.encodeCall(ISafeModules.enableModule, (deployed.safe))),
            _multiSendCall(deployed.safe, abi.encodeCall(IGnosisSafe.addOwnerWithThreshold, (l2Alias, 1))),
            _multiSendCall(deployed.safe, abi.encodeCall(IGnosisSafe.removeOwner, (l2Alias, deployer, 1)))
        );
        IGnosisSafe(deployed.safe)
            .execTransaction(
                BaseChain.SAFE_MULTI_SEND_CALL_ONLY,
                0,
                abi.encodeCall(IMultiSend.multiSend, (calls)),
                Enum.Operation.DelegateCall,
                0,
                0,
                0,
                address(0),
                address(0),
                abi.encodePacked(bytes32(uint256(uint160(deployer))), bytes32(0), uint8(1))
            );
    }

    /**
     * @notice Checks the chain, the external Base dependencies and the configuration before broadcasting.
     * @dev Rejects a deployer equal to the alias, because the batch removes the deployer as an owner.
     */
    function _validate(Config memory config, address deployer) internal view {
        if (
            block.chainid != BaseChain.BASE_CHAIN_ID || BaseChain.SAFE_PROXY_FACTORY.code.length == 0
                || BaseChain.SAFE_L2_SINGLETON.code.length == 0 || BaseChain.SAFE_FALLBACK_HANDLER.code.length == 0
                || BaseChain.SAFE_MULTI_SEND_CALL_ONLY.code.length == 0 || BaseChain.MULTICALL3.code.length == 0
                || BaseChain.THREE_F_REQUESTS_FACTORY.code.length == 0 || BaseChain.THREE_F_FACILITY.code.length == 0
                || IERC20Metadata(BaseChain.BASE_USDC).decimals() != 6
                || ITokenMessengerV2(BaseChain.TOKEN_MESSENGER).localMessageTransmitter()
                    != BaseChain.MESSAGE_TRANSMITTER
                || IMessageTransmitterV2(BaseChain.MESSAGE_TRANSMITTER).localDomain() != BaseChain.BASE_DOMAIN
        ) revert InvalidBaseDependency();
        if (
            config.ethereumAccount == address(0) || config.factoriesOwner == address(0)
                || BaseChain.l2Alias(config.ethereumAccount) == deployer
        ) revert InvalidConfig();
    }

    /**
     * @notice Checks that the alias is the only owner with threshold 1, and checks the modules and policy binding.
     * @dev Runs against the simulated or broadcast state, so a plan also proves the batch configures the Safe.
     */
    function _verify(Config memory config, address deployer, Deployment memory deployed) internal view {
        IGnosisSafe safe = IGnosisSafe(deployed.safe);
        address l2Alias = BaseChain.l2Alias(config.ethereumAccount);
        address[] memory owners = safe.getOwners();
        if (
            owners.length != 1 || owners[0] != l2Alias || safe.getThreshold() != 1 || safe.isOwner(deployer)
                || !ISafeModules(deployed.safe).isModuleEnabled(l2Alias)
                || !ISafeModules(deployed.safe).isModuleEnabled(deployed.safe)
                || IThreeFPolicy(deployed.policy).account() != deployed.safe
                || Ownable(deployed.policy).owner() != deployed.safe
                || Ownable(deployed.policyFactory).owner() != config.factoriesOwner
        ) revert InvalidDeployment();
    }

    /**
     * @notice Writes the Base manifest read by the Ethereum leaf builder and action scripts.
     * @dev Records the Ethereum account, its alias (the only Safe owner), the Safe and the ThreeFPolicy addresses.
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
        vm.serializeAddress("manifest", "safe", deployed.safe);
        vm.serializeAddress("manifest", "recipeCapability", deployed.recipeCapability);
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

    /// @notice Returns the address that sends the deployment transactions and temporarily owns the Safe.
    function _deployer() internal virtual returns (address sender) {
        (, sender,) = vm.readCallers();
    }

    /* PRIVATE FUNCTIONS */

    /// @dev Packs one MultiSendCallOnly call: operation, target, value, data length and data.
    function _multiSendCall(address target, bytes memory data) private pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), target, uint256(0), data.length, data);
    }
}
