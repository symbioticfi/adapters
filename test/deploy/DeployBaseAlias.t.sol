// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChain} from "script/base-chain/BaseChain.sol";
import {BaseAliasPayloads} from "script/base-chain/BaseAliasPayloads.sol";
import {BaseAliasThreeFPolicy} from "src/contracts/merkle-adapter/capabilities/policies/BaseAliasThreeFPolicy.sol";
import {DeployBaseAliasPolicyScript} from "script/deploy/base-chain/DeployBaseAliasPolicy.s.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IBaseAliasThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IBaseAliasThreeFPolicy.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {MockThreeFRequest} from "./DeployBaseSafe.t.sol";

/// @dev Runs the deployment without a broadcast wallet.
contract DeployBaseAliasPolicyHarness is DeployBaseAliasPolicyScript {
    /// @dev Runs calls from the harness instead of a broadcast wallet.
    function _startBroadcast() internal override {}
    /// @dev Pairs with the no-op broadcast start.
    function _stopBroadcast() internal override {}
}

contract DeployBaseAliasPolicyTest is Test {
    using stdJson for string;

    string private constant MANIFEST = "cache/base-alias-deployment-test.json";

    function test_DeploysOnEthereumBoundToMerkleAccount() public {
        vm.chainId(BaseChain.ETHEREUM_CHAIN_ID);
        vm.etch(BaseChain.BASE_PORTAL, hex"00");
        if (vm.exists(MANIFEST)) vm.removeFile(MANIFEST);
        vm.setEnv("BASE_ALIAS_MANIFEST", MANIFEST);
        vm.setEnv("BASE_ETHEREUM_ACCOUNT", vm.toString(address(this)));
        address policy = new DeployBaseAliasPolicyHarness().run();

        assertEq(IBaseAliasThreeFPolicy(policy).account(), address(this));
        string memory json = vm.readFile(MANIFEST);
        assertEq(json.readUint(".chainId"), BaseChain.BASE_CHAIN_ID);
        assertEq(json.readUint(".policyChainId"), BaseChain.ETHEREUM_CHAIN_ID);
        assertEq(json.readAddress(".ethereumAccount"), address(this));
        assertEq(json.readAddress(".alias"), BaseChain.l2Alias(address(this)));
        assertEq(json.readAddress(".threeF.policy"), policy);
        vm.removeFile(MANIFEST);
    }

    function test_RejectsDeploymentOnBase() public {
        vm.chainId(BaseChain.BASE_CHAIN_ID);
        vm.setEnv("BASE_ALIAS_MANIFEST", MANIFEST);
        address deployer = address(new DeployBaseAliasPolicyHarness());
        vm.expectRevert(DeployBaseAliasPolicyScript.InvalidChain.selector);
        DeployBaseAliasPolicyScript(deployer).run();
    }
}

/// @dev Base fork tests. Set BASE_RPC_URL to run them.
contract DeployBaseAliasForkTest is Test {
    address private _alias;
    BaseAliasPayloads.Deployment private _payloads;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "BASE_RPC_URL is required for the Base alias fork tests");
        vm.createSelectFork(rpc);
        _payloads = BaseAliasPayloads.Deployment({ethereumAccount: makeAddr("ethereum account"), policy: address(0)});
        _alias = BaseAliasPayloads.aliasOf(_payloads);
    }

    function test_AliasMintsThroughThreeDeposits() public {
        address request = _mintSetup(10e6, 1e6);
        _deliverMint(request, 10e6, 1e6);
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(_alias), 90e6);
        assertEq(MockThreeFRequest(request).minter(), _alias);
        (uint256 pt, uint256 yt) = MockThreeFRequest(request).balancesOf(_alias);
        assertEq(pt, 10e6);
        assertEq(yt, 1e6);
        assertEq(IERC20(BaseChain.BASE_USDC).allowance(_alias, request), 0);
    }

    /// @dev Recovery: when a mint leaves an approval open, the reset deposit alone closes it and charges nothing.
    function test_StandaloneResetClosesOpenApproval() public {
        address request = makeAddr("request");
        deal(BaseChain.BASE_USDC, _alias, 100e6);
        assertTrue(_deliver(BaseAliasPayloads.approveThreeF(request, 10e6)));
        assertEq(IERC20(BaseChain.BASE_USDC).allowance(_alias, request), 10e6);
        assertTrue(_deliver(BaseAliasPayloads.resetThreeFApproval(request)));
        assertEq(IERC20(BaseChain.BASE_USDC).allowance(_alias, request), 0);
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(_alias), 100e6);
    }

    /// @dev The Base mint pulls nothing after authorization has been revoked. The reset still clears the approval.
    function test_StaleAuthorizationLeavesNoApproval() public {
        address request = _mintSetup(0, 0);
        _deliverMint(request, 10e6, 1e6);
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(_alias), 100e6);
        assertEq(IERC20(BaseChain.BASE_USDC).allowance(_alias, request), 0);
    }

    /// @dev The alias redeems its whole position and receives the principal and yield.
    function test_AliasRedeemsPosition() public {
        address request = address(new MockThreeFRequest(IERC20(BaseChain.BASE_USDC)));
        MockThreeFRequest(request).setBalances(_alias, 10e6, 1e6);
        deal(BaseChain.BASE_USDC, request, 11e6);
        assertTrue(_deliver(BaseAliasPayloads.redeemThreeF(_payloads, request)));
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(_alias), 11e6);
        (uint256 pt, uint256 yt) = MockThreeFRequest(request).balancesOf(_alias);
        assertEq(pt + yt, 0);
    }

    /// @dev The two bridge deposits burn alias USDC through the live TokenMessenger and leave no approval.
    function test_AliasBridgesUsdcToEthereum() public {
        deal(BaseChain.BASE_USDC, _alias, 100e6);
        assertTrue(_deliver(BaseAliasPayloads.approveBurn(40e6)));
        assertTrue(_deliver(BaseAliasPayloads.bridgeToEthereum(_payloads, 40e6)));
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(_alias), 60e6);
        assertEq(IERC20(BaseChain.BASE_USDC).allowance(_alias, BaseChain.TOKEN_MESSENGER), 0);
    }

    /// @dev Funds the alias and authorizes it to mint the specified amounts.
    function _mintSetup(uint128 pt, uint128 yt) private returns (address request) {
        request = address(new MockThreeFRequest(IERC20(BaseChain.BASE_USDC)));
        MockThreeFRequest(request).authorizeMinting(_alias, pt, yt);
        deal(BaseChain.BASE_USDC, _alias, 100e6);
    }

    /// @dev Replays the Base deposits after Ethereum has accepted the dispatch.
    function _deliverMint(address request, uint256 principal, uint256 yieldAssets) private {
        IMerkleAccount.Action[] memory actions =
            BaseAliasPayloads.mintActions(_payloads, request, principal, yieldAssets);
        for (uint256 i = 1; i < actions.length; ++i) {
            assertTrue(_deliver(actions[i]));
        }
    }

    /// @dev Replays the L2 side of a portal deposit within its pinned gas limit: the alias calls the deposit target
    /// with the deposit calldata. Returns whether the Base transaction succeeded.
    function _deliver(IMerkleAccount.Action memory action) private returns (bool success) {
        bytes memory arguments = new bytes(action.data.length - 4);
        for (uint256 i; i < arguments.length; ++i) {
            arguments[i] = action.data[i + 4];
        }
        (address to,,,, bytes memory data) = abi.decode(arguments, (address, uint256, uint64, bool, bytes));
        vm.prank(_alias);
        // A deposit's gas limit also pays the transaction's intrinsic and calldata gas.
        (success,) = to.call{gas: BaseChain.PORTAL_GAS_LIMIT - 21_000 - 16 * data.length}(data);
    }
}

/// @dev Ethereum fork tests. Set ETH_RPC_URL to run them.
contract BaseAliasEthereumForkTest is Test {
    /// @dev OptimismPortal event carrying the aliased L2 sender.
    event TransactionDeposited(address indexed from, address indexed to, uint256 indexed version, bytes opaqueData);

    BaseAliasPayloads.Deployment private _payloads;

    /// @dev Forks Ethereum and deploys the policy bound to the contract that sends the deposits.
    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "ETH_RPC_URL is required for the Base alias Ethereum fork tests");
        vm.createSelectFork(rpc);
        _payloads = BaseAliasPayloads.Deployment({
            ethereumAccount: address(this), policy: address(new BaseAliasThreeFPolicy(address(this)))
        });
    }

    /// @dev The approved mint dispatch emits three portal deposits from the alias, in order.
    function test_MintDepositsAreSentFromAliasInOrder() public {
        address request = makeAddr("request");
        address underlying = makeAddr("underlying");
        IBaseAliasThreeFPolicy(_payloads.policy).setRequestUnderlying(request, underlying);
        IBaseAliasThreeFPolicy(_payloads.policy).setMaxAssetsPerDuration(underlying, 20e6, 1 days);
        IMerkleAccount.Action[] memory actions = BaseAliasPayloads.mintActions(_payloads, request, 10e6, 1e6);
        address[3] memory targets = [BaseChain.BASE_USDC, request, BaseChain.BASE_USDC];

        vm.recordLogs();
        for (uint256 i; i < actions.length; ++i) {
            (bool success,) = actions[i].target.call(actions[i].data);
            assertTrue(success);
        }

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 deposits;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != BaseChain.BASE_PORTAL) continue;
            assertEq(logs[i].topics[0], TransactionDeposited.selector);
            assertEq(address(uint160(uint256(logs[i].topics[1]))), BaseAliasPayloads.aliasOf(_payloads));
            assertEq(address(uint160(uint256(logs[i].topics[2]))), targets[deposits++]);
        }
        assertEq(deposits, 3);
    }

    /// @dev The Ethereum bridge actions burn the approved USDC from the MerkleAccount to the alias.
    function test_BridgeToBaseAliasBurnsAccountUsdc() public {
        deal(BaseChain.ETHEREUM_USDC, _payloads.ethereumAccount, 100e6);
        IMerkleAccount.Action memory approval = BaseAliasPayloads.approveBridge(30e6);
        IMerkleAccount.Action memory burn = BaseAliasPayloads.bridgeToBase(_payloads, 30e6);
        vm.startPrank(_payloads.ethereumAccount);
        (bool approved,) = approval.target.call(approval.data);
        (bool burned,) = burn.target.call(burn.data);
        vm.stopPrank();
        assertTrue(approved && burned);
        assertEq(IERC20(BaseChain.ETHEREUM_USDC).balanceOf(_payloads.ethereumAccount), 70e6);
    }
}
