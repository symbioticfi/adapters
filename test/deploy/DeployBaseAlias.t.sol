// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseAliasPayloads} from "script/base-chain/BaseAliasPayloads.sol";
import {BaseChain} from "script/base-chain/BaseChain.sol";
import {DeployBaseAliasPolicyScript} from "script/deploy/base-chain/DeployBaseAliasPolicy.s.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";

import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

contract DeployBaseAliasPolicyHarness is DeployBaseAliasPolicyScript {
    function _startBroadcast() internal override {}
    function _stopBroadcast() internal override {}

    function _deployer() internal view override returns (address) {
        return address(this);
    }
}

/// @dev Uses the live Base dependencies on a fork. Set BASE_RPC_URL to run it.
contract DeployBaseAliasForkTest is Test {
    using Bytes for bytes;
    using stdJson for string;

    string private constant MANIFEST = "cache/base-alias-deployment-test.json";
    address private constant UNDERLYING = address(0xBEEF);

    address private _factoriesOwner;
    BaseAliasPayloads.Deployment private _deployment;
    DeployBaseAliasPolicyScript.Deployment private _deployed;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "BASE_RPC_URL is required for the Base manager fork tests");
        vm.createSelectFork(rpc);
        _deployment.ethereumAccount = makeAddr("Ethereum MerkleAccount");
        _factoriesOwner = makeAddr("policy factories owner");
        if (vm.exists(MANIFEST)) vm.removeFile(MANIFEST);
        vm.setEnv("BASE_ALIAS_MANIFEST", MANIFEST);
        vm.setEnv("BASE_ETHEREUM_ACCOUNT", vm.toString(_deployment.ethereumAccount));
        vm.setEnv("BASE_FACTORIES_OWNER", vm.toString(_factoriesOwner));
        _deployed = new DeployBaseAliasPolicyHarness().run();
        _deployment.manager = _deployed.manager;
        _deployment.policy = _deployed.policy;
    }

    function test_DeploysManagerAndBindsExistingPolicy() public view {
        address manager = _deployment.manager;
        address aliasAccount = BaseAliasPayloads.aliasOf(_deployment);
        (bool aliasAdmin, uint32 delay) = IAccessManager(manager).hasRole(0, aliasAccount);
        (bool deployerAdmin,) = IAccessManager(manager).hasRole(0, address(this));
        assertTrue(aliasAdmin);
        assertEq(delay, 0);
        assertFalse(deployerAdmin);
        assertEq(IThreeFPolicy(_deployment.policy).account(), manager);
        assertEq(Ownable(_deployment.policy).owner(), manager);
        assertEq(Ownable(_deployed.policyFactory).owner(), _factoriesOwner);
        assertEq(IThreeFPolicy(_deployment.policy).REQUESTS_FACTORY(), BaseChain.THREE_F_REQUESTS_FACTORY);
        assertEq(IThreeFPolicy(_deployment.policy).FACILITY(), BaseChain.THREE_F_FACILITY);
        string memory json = vm.readFile(MANIFEST);
        assertEq(json.readUint(".chainId"), BaseChain.BASE_CHAIN_ID);
        assertEq(json.readAddress(".manager"), manager);
        assertEq(json.readAddress(".alias"), aliasAccount);
        assertEq(json.readAddress(".threeF.policy"), _deployment.policy);
    }

    function test_CuratorConfiguresPolicyThroughManager() public {
        _deliver(BaseAliasPayloads.setMaxAssetsPerDuration(_deployment, UNDERLYING, 15e6, 1 days));
        _deliver(BaseAliasPayloads.setMinYieldPerRequest(_deployment, UNDERLYING, 1e6));
        assertEq(IThreeFPolicy(_deployment.policy).remainingAssets(BaseChain.BASE_USDC, UNDERLYING), 15e6);
        assertEq(IThreeFPolicy(_deployment.policy).minYieldPerRequest(UNDERLYING), 1e6);
    }

    function test_ManagerBridgesBackAndClearsCctpAllowance() public {
        deal(BaseChain.BASE_USDC, _deployment.manager, 100e6);
        _deliver(BaseAliasPayloads.bridgeToEthereum(_deployment, 40e6));
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(_deployment.manager), 60e6);
        assertEq(IERC20(BaseChain.BASE_USDC).allowance(_deployment.manager, BaseChain.TOKEN_MESSENGER), 0);
    }

    function _deliver(IMerkleAccount.Action memory action) private {
        (address manager,, uint64 gasLimit,, bytes memory data) =
            abi.decode(action.data.slice(4), (address, uint256, uint64, bool, bytes));
        vm.prank(BaseAliasPayloads.aliasOf(_deployment));
        // The deposit gas also pays for the transaction and its calldata.
        (bool success,) = manager.call{gas: gasLimit - 21_000 - 16 * data.length}(data);
        assertTrue(success);
    }
}

/// @dev Uses the live Ethereum portal and CCTP contracts on a fork. Set ETH_RPC_URL to run it.
contract BaseAliasEthereumForkTest is Test {
    event TransactionDeposited(address indexed from, address indexed to, uint256 indexed version, bytes opaqueData);

    BaseAliasPayloads.Deployment private _deployment;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "ETH_RPC_URL is required for the Base manager Ethereum fork tests");
        vm.createSelectFork(rpc);
        _deployment = BaseAliasPayloads.Deployment({
            ethereumAccount: address(this), manager: makeAddr("Base manager"), policy: makeAddr("Base policy")
        });
    }

    function test_RealPortalQueuesOneMintDepositFromAliasToManager() public {
        IMerkleAccount.Action memory action =
            BaseAliasPayloads.mintThreeF(_deployment, makeAddr("3F request"), 10e6, 1e6);
        vm.recordLogs();
        (bool success,) = action.target.call(action.data);
        assertTrue(success);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 deposits;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != BaseChain.BASE_PORTAL || logs[i].topics[0] != TransactionDeposited.selector) {
                continue;
            }
            assertEq(address(uint160(uint256(logs[i].topics[1]))), BaseAliasPayloads.aliasOf(_deployment));
            assertEq(address(uint160(uint256(logs[i].topics[2]))), _deployment.manager);
            ++deposits;
        }
        assertEq(deposits, 1);
    }

    function test_BridgeToBaseBurnsEthereumAccountUsdc() public {
        deal(BaseChain.ETHEREUM_USDC, _deployment.ethereumAccount, 100e6);
        IMerkleAccount.Action memory approval = BaseAliasPayloads.approveBridge(30e6);
        IMerkleAccount.Action memory burn = BaseAliasPayloads.bridgeToBase(_deployment, 30e6);
        (bool approved,) = approval.target.call(approval.data);
        (bool burned,) = burn.target.call(burn.data);
        assertTrue(approved && burned);
        assertEq(IERC20(BaseChain.ETHEREUM_USDC).balanceOf(_deployment.ethereumAccount), 70e6);
    }
}
