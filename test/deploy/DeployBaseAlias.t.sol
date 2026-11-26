// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChain} from "script/base-chain/BaseChain.sol";
import {BaseAliasPayloads} from "script/base-chain/BaseAliasPayloads.sol";
import {DeployBaseAliasPolicyScript} from "script/deploy/base-chain/DeployBaseAliasPolicy.s.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {MockThreeFRequest, PolicyRecorder} from "./DeployBaseSafe.t.sol";

/// @dev Runs the deployment from the harness itself, which temporarily owns the policy factory.
contract DeployBaseAliasPolicyHarness is DeployBaseAliasPolicyScript {
    /// @dev Runs calls from the harness instead of a broadcast wallet.
    function _startBroadcast() internal override {}
    /// @dev Pairs with the no-op broadcast start.
    function _stopBroadcast() internal override {}

    /// @dev Makes the harness the deployer.
    function _deployer() internal view override returns (address) {
        return address(this);
    }
}

/// @dev Base fork tests. Set BASE_RPC_URL to run them.
contract DeployBaseAliasForkTest is Test {
    using stdJson for string;

    string private constant MANIFEST = "cache/base-alias-deployment-test.json";
    address private constant UNDERLYING = address(0xBEEF);

    address private _ethereumAccount;
    address private _alias;
    address private _factoriesOwner;
    DeployBaseAliasPolicyScript.Deployment private _deployed;
    BaseAliasPayloads.Deployment private _payloads;

    /// @dev Forks Base and runs the deployment script.
    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "BASE_RPC_URL is required for the Base alias fork tests");
        vm.createSelectFork(rpc);
        _ethereumAccount = makeAddr("ethereum account");
        _alias = BaseChain.l2Alias(_ethereumAccount);
        _factoriesOwner = makeAddr("factories owner");
        if (vm.exists(MANIFEST)) vm.removeFile(MANIFEST);
        vm.setEnv("BASE_ALIAS_MANIFEST", MANIFEST);
        vm.setEnv("BASE_ETHEREUM_ACCOUNT", vm.toString(_ethereumAccount));
        vm.setEnv("BASE_FACTORIES_OWNER", vm.toString(_factoriesOwner));
        _deployed = new DeployBaseAliasPolicyHarness().run();
        _payloads = BaseAliasPayloads.Deployment({ethereumAccount: _ethereumAccount, policy: _deployed.policy});
    }

    /// @dev The alias owns and uses the policy, the factories owner holds the factory, and the manifest records them.
    function test_DeploysPolicyOwnedByAlias() public {
        assertEq(IThreeFPolicy(_deployed.policy).account(), _alias);
        assertEq(Ownable(_deployed.policy).owner(), _alias);
        assertEq(IThreeFPolicy(_deployed.policy).REQUESTS_FACTORY(), BaseChain.THREE_F_REQUESTS_FACTORY);
        assertEq(Ownable(_deployed.policyFactory).owner(), _factoriesOwner);

        string memory json = vm.readFile(MANIFEST);
        assertEq(json.readAddress(".ethereumAccount"), _ethereumAccount);
        assertEq(json.readAddress(".alias"), _alias);
        assertEq(json.readAddress(".threeF.policy"), _deployed.policy);
        vm.removeFile(MANIFEST);
    }

    /// @dev Deposits from the alias configure the policy; other senders cannot.
    function test_AliasSetsPolicyLimits() public {
        assertTrue(_deliver(BaseAliasPayloads.setMaxAssetsPerDuration(_payloads, UNDERLYING, 1000e6, 1 days)));
        assertTrue(_deliver(BaseAliasPayloads.setMinYieldPerRequest(_payloads, UNDERLYING, 5000)));
        assertEq(IThreeFPolicy(_deployed.policy).remainingAssets(BaseChain.BASE_USDC, UNDERLYING), 1000e6);
        assertEq(IThreeFPolicy(_deployed.policy).minYieldPerRequest(UNDERLYING), 5000);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IThreeFPolicy.InvalidCaller.selector);
        IThreeFPolicy(_deployed.policy).setMinYieldPerRequest(UNDERLYING, 0);
    }

    /// @dev The alias policy accepts a live 3F request on Base and charges the collateral's underlying asset.
    function test_AliasChargesPolicyForLiveRequest() public {
        address request = 0xf7Ea207B9f27da86ab21f7e2D7bD0F915ADF408D;
        address underlying = 0xFCc9Cc1209651Ed8867332d6F664CF82743A2584;
        assertTrue(_deliver(BaseAliasPayloads.setMaxAssetsPerDuration(_payloads, underlying, 10e6, 1 days)));
        assertTrue(_deliver(BaseAliasPayloads.consumeThreeF(_payloads, request, 4e6, 1e5)));
        assertEq(IThreeFPolicy(_deployed.policy).remainingAssets(BaseChain.BASE_USDC, underlying), 6e6);
    }

    /// @dev The four mint deposits charge the policy, mint as the alias and leave no approval.
    function test_AliasMintsThroughFourDeposits() public {
        (PolicyRecorder policy, MockThreeFRequest request) = _mintSetup(10e6, 1e6);
        bool[4] memory results = _deliverMint(address(request), 10e6, 1e6);
        for (uint256 i; i < 4; ++i) {
            assertTrue(results[i]);
        }
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(_alias), 90e6);
        assertEq(request.minter(), _alias);
        (uint256 pt, uint256 yt) = request.balancesOf(_alias);
        assertEq(pt, 10e6);
        assertEq(yt, 1e6);
        assertEq(policy.calls(), 1);
        assertEq(policy.request(), address(request));
        assertEq(policy.assets(), 10e6);
        assertEq(policy.yieldAssets(), 1e6);
        assertEq(IERC20(BaseChain.BASE_USDC).allowance(_alias, address(request)), 0);
    }

    /// @dev Documents the trust assumption: deposits are separate transactions, so when `consume` refuses an
    /// address that is not a 3F request, `approve` and `mint` still run and that address pulls the principal.
    function test_FailedConsumeDoesNotStopMint() public {
        MockThreeFRequest request = new MockThreeFRequest(IERC20(BaseChain.BASE_USDC));
        request.authorizeMinting(_alias, 10e6, 1e6);
        deal(BaseChain.BASE_USDC, _alias, 100e6);
        bool[4] memory results = _deliverMint(address(request), 10e6, 1e6);
        assertFalse(results[0]);
        assertTrue(results[1] && results[2] && results[3]);
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(_alias), 90e6);
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(address(request)), 10e6);
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

    /// @dev Documents the budget cost of a stale authorization: `mint` pulls nothing, but `consume` already charged
    /// the policy. The approval reset still runs.
    function test_StaleAuthorizationChargesPolicyOnly() public {
        (PolicyRecorder policy, MockThreeFRequest request) = _mintSetup(0, 0);
        bool[4] memory results = _deliverMint(address(request), 10e6, 1e6);
        assertTrue(results[0] && results[1] && results[2] && results[3]);
        assertEq(policy.calls(), 1);
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(_alias), 100e6);
        assertEq(IERC20(BaseChain.BASE_USDC).allowance(_alias, address(request)), 0);
    }

    /// @dev The alias redeems its whole position and receives the principal and yield.
    function test_AliasRedeemsPosition() public {
        MockThreeFRequest request = new MockThreeFRequest(IERC20(BaseChain.BASE_USDC));
        request.setBalances(_alias, 10e6, 1e6);
        deal(BaseChain.BASE_USDC, address(request), 11e6);
        assertTrue(_deliver(BaseAliasPayloads.redeemThreeF(_payloads, address(request))));
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(_alias), 11e6);
        (uint256 pt, uint256 yt) = request.balancesOf(_alias);
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

    /// @dev Points the payloads at a policy recorder and funds the alias with 100 USDC. Returns a mock request that
    /// has authorized the alias for `pt` principal and `yt` yield.
    function _mintSetup(uint128 pt, uint128 yt) private returns (PolicyRecorder policy, MockThreeFRequest request) {
        policy = new PolicyRecorder();
        _payloads.policy = address(policy);
        request = new MockThreeFRequest(IERC20(BaseChain.BASE_USDC));
        request.authorizeMinting(_alias, pt, yt);
        deal(BaseChain.BASE_USDC, _alias, 100e6);
    }

    /// @dev Replays the four mint deposits in order, each as its own transaction, and returns each result.
    function _deliverMint(address request, uint256 principal, uint256 yieldAssets)
        private
        returns (bool[4] memory results)
    {
        IMerkleAccount.Action[] memory actions =
            BaseAliasPayloads.mintActions(_payloads, request, principal, yieldAssets);
        for (uint256 i; i < actions.length; ++i) {
            results[i] = _deliver(actions[i]);
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

    /// @dev Forks Ethereum with arbitrary Base deployment addresses.
    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "ETH_RPC_URL is required for the Base alias Ethereum fork tests");
        vm.createSelectFork(rpc);
        _payloads =
            BaseAliasPayloads.Deployment({ethereumAccount: makeAddr("ethereum account"), policy: makeAddr("policy")});
    }

    /// @dev The four mint deposits leave the portal from the alias, in order, to the policy, USDC, the request and
    /// USDC.
    function test_MintDepositsAreSentFromAliasInOrder() public {
        address request = makeAddr("request");
        IMerkleAccount.Action[] memory actions = BaseAliasPayloads.mintActions(_payloads, request, 10e6, 1e6);
        address[4] memory targets = [_payloads.policy, BaseChain.BASE_USDC, request, BaseChain.BASE_USDC];
        vm.recordLogs();
        vm.startPrank(_payloads.ethereumAccount);
        for (uint256 i; i < actions.length; ++i) {
            (bool success,) = actions[i].target.call(actions[i].data);
            assertTrue(success);
        }
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 4);
        for (uint256 i; i < logs.length; ++i) {
            assertEq(logs[i].emitter, BaseChain.BASE_PORTAL);
            assertEq(logs[i].topics[0], TransactionDeposited.selector);
            assertEq(address(uint160(uint256(logs[i].topics[1]))), BaseAliasPayloads.aliasOf(_payloads));
            assertEq(address(uint160(uint256(logs[i].topics[2]))), targets[i]);
        }
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
