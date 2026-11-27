// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BaseChain} from "script/base-chain/BaseChain.sol";
import {BaseSafePayloads} from "script/base-chain/BaseSafePayloads.sol";
import {DeployBaseSafeScript} from "script/deploy/base-chain/DeployBaseSafe.s.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";
import {IThreeFRequestFactory} from "src/interfaces/3f-adapter/IThreeFRequestFactory.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IGnosisSafe} from "script/utils/interfaces/IGnosisSafe.sol";
import {ISafeModules} from "script/utils/interfaces/ISafeModules.sol";

/// @dev Runs the deployment from the harness itself, which is the temporary Safe owner.
contract DeployBaseSafeHarness is DeployBaseSafeScript {
    /// @dev Runs calls from the harness instead of a broadcast wallet.
    function _startBroadcast() internal override {}
    /// @dev Pairs with the no-op broadcast start.
    function _stopBroadcast() internal override {}

    /// @dev Makes the harness the temporary Safe owner that approves the configuration batch.
    function _deployer() internal view override returns (address) {
        return address(this);
    }
}

/// @dev Records ThreeFPolicy charges without checking 3F provenance, so recipe tests can use a mock request.
contract PolicyRecorder {
    uint256 public calls;
    address public request;
    uint256 public assets;
    uint256 public yieldAssets;

    /// @dev Records one charge.
    function consume(address request_, uint256 assets_, uint256 yieldAssets_) external {
        ++calls;
        request = request_;
        assets = assets_;
        yieldAssets = yieldAssets_;
    }
}

/// @dev Push-mint 3F request with the deployed Request's mint, authorization and burn behaviour, minus tokens.
contract MockThreeFRequest {
    IERC20 private immutable _usdc;
    mapping(address => uint128[2]) private _authorizations;
    mapping(address => uint256[2]) private _balances;
    bool public pulls = true;
    address public minter;

    /// @dev Binds the mock to the asset it pulls on mint and pays on burn.
    constructor(IERC20 usdc) {
        _usdc = usdc;
    }

    /// @dev Sets the mint authorization of `account`, as 3F's `authorizeMinting` does.
    function authorizeMinting(address account, uint128 pt, uint128 yt) external {
        _authorizations[account] = [pt, yt];
    }

    /// @dev Makes `mint` return without pulling funds, to test the recipe's balance check.
    function setPulls(bool value) external {
        pulls = value;
    }

    /// @dev Gives `account` a position, as a past mint would.
    function setBalances(address account, uint256 pt, uint256 yt) external {
        _balances[account] = [pt, yt];
    }

    /// @dev Returns the authorization of `account`.
    function mintAuthorization(address account) external view returns (uint128, uint128) {
        return (_authorizations[account][0], _authorizations[account][1]);
    }

    /// @dev Mints like 3F: returns early without authorization, checks slippage, clears it and pulls the principal.
    function mint(uint128 maxPt, uint128 minYt) external {
        (uint128 pt, uint128 yt) = (_authorizations[msg.sender][0], _authorizations[msg.sender][1]);
        if (pt == 0 && yt == 0) return;
        require(pt <= maxPt && yt >= minYt, "slippage");
        if (!pulls) return;
        delete _authorizations[msg.sender];
        _usdc.transferFrom(msg.sender, address(this), pt);
        _balances[msg.sender] = [pt, yt];
        minter = msg.sender;
    }

    /// @dev Returns the PT and YT balances of `account`.
    function balancesOf(address account) external view returns (uint256, uint256) {
        return (_balances[account][0], _balances[account][1]);
    }

    /// @dev Burns the whole position of `owner` and pays principal plus yield to `receiver`.
    function burnAll(address owner, address receiver) external returns (uint256 pt, uint256 yt, uint256, uint256) {
        require(msg.sender == owner, "owner");
        (pt, yt) = (_balances[owner][0], _balances[owner][1]);
        delete _balances[owner];
        _usdc.transfer(receiver, pt + yt);
        return (pt, yt, pt, yt);
    }
}

/// @dev Base fork tests. Set BASE_RPC_URL to run them.
contract DeployBaseSafeForkTest is Test {
    using stdJson for string;

    string private constant MANIFEST = "cache/base-safe-deployment-test.json";
    address private constant UNDERLYING = address(0xBEEF);

    address private _ethereumAccount;
    address private _factoriesOwner;
    DeployBaseSafeScript.Deployment private _deployed;
    BaseSafePayloads.Deployment private _payloads;

    /// @dev Forks Base and runs the deployment script.
    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "BASE_RPC_URL is required for the Base Safe fork tests");
        vm.createSelectFork(rpc);
        _ethereumAccount = makeAddr("ethereum account");
        _factoriesOwner = makeAddr("factories owner");
        if (vm.exists(MANIFEST)) vm.removeFile(MANIFEST);
        vm.setEnv("BASE_MANIFEST", MANIFEST);
        vm.setEnv("BASE_ETHEREUM_ACCOUNT", vm.toString(_ethereumAccount));
        vm.setEnv("BASE_SAFE_SALT_NONCE", vm.toString(uint256(keccak256("base safe test"))));
        vm.setEnv("BASE_FACTORIES_OWNER", vm.toString(_factoriesOwner));
        _deployed = new DeployBaseSafeHarness().run();
        _payloads = BaseSafePayloads.Deployment({
            ethereumAccount: _ethereumAccount,
            safe: _deployed.safe,
            recipeCapability: _deployed.recipeCapability,
            policy: _deployed.policy
        });
    }

    /// @dev The alias is the only owner with threshold 1, both modules are enabled, and the Safe owns its policy.
    function test_DeploysSafeControlledByAlias() public {
        IGnosisSafe safe = IGnosisSafe(_deployed.safe);
        address l2Alias = BaseChain.l2Alias(_ethereumAccount);
        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1);
        assertEq(owners[0], l2Alias);
        assertEq(safe.getThreshold(), 1);
        assertTrue(ISafeModules(_deployed.safe).isModuleEnabled(l2Alias));
        assertTrue(ISafeModules(_deployed.safe).isModuleEnabled(_deployed.safe));
        assertEq(IThreeFPolicy(_deployed.policy).account(), _deployed.safe);
        assertEq(IThreeFPolicy(_deployed.policy).REQUESTS_FACTORY(), BaseChain.THREE_F_REQUESTS_FACTORY);
        assertEq(Ownable(_deployed.policyFactory).owner(), _factoriesOwner);

        string memory json = vm.readFile(MANIFEST);
        assertEq(json.readAddress(".safe"), _deployed.safe);
        assertEq(json.readAddress(".alias"), l2Alias);
        assertEq(json.readAddress(".threeF.policy"), _deployed.policy);
        vm.removeFile(MANIFEST);
    }

    /// @dev Portal calls from the alias configure the Safe-owned ThreeFPolicy.
    function test_AliasSetsPolicyLimits() public {
        _deliver(BaseSafePayloads.setMaxAssetsPerDuration(_payloads, UNDERLYING, 1000e6, 1 days), true);
        _deliver(BaseSafePayloads.setMinYieldPerRequest(_payloads, UNDERLYING, 5000), true);
        assertEq(IThreeFPolicy(_deployed.policy).remainingAssets(BaseChain.BASE_USDC, UNDERLYING), 1000e6);
        assertEq(IThreeFPolicy(_deployed.policy).minYieldPerRequest(UNDERLYING), 5000);
    }

    /// @dev The self-call delegatecall path runs the bridge recipe and leaves no approval.
    function test_AliasBridgesUsdcToEthereumThroughRecipe() public {
        deal(BaseChain.BASE_USDC, _deployed.safe, 100e6);
        _deliver(BaseSafePayloads.bridgeToEthereum(_payloads, 40e6), true);
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(_deployed.safe), 60e6);
        assertEq(IERC20(BaseChain.BASE_USDC).allowance(_deployed.safe, BaseChain.TOKEN_MESSENGER), 0);
    }

    /// @dev The Safe-bound ThreeFPolicy accepts a live 3F request on Base: its `request-<intentId>` name resolves
    /// through the Facility, and the budget is charged against the collateral's underlying asset.
    function test_PolicyAcceptsLiveBaseRequest() public {
        address request = 0xf7Ea207B9f27da86ab21f7e2D7bD0F915ADF408D;
        address underlying = 0xFCc9Cc1209651Ed8867332d6F664CF82743A2584;
        vm.startPrank(_deployed.safe);
        IThreeFPolicy(_deployed.policy).setMaxAssetsPerDuration(BaseChain.BASE_USDC, underlying, 10e6, 1 days);
        IThreeFPolicy(_deployed.policy).consume(request, 4e6, 1e5);
        vm.stopPrank();
        assertEq(IThreeFPolicy(_deployed.policy).remainingAssets(BaseChain.BASE_USDC, underlying), 6e6);
    }

    /// @dev The mint recipe reverts for an address that is not a 3F request, so the Safe keeps its USDC.
    function test_MintRejectsUnknownRequest() public {
        deal(BaseChain.BASE_USDC, _deployed.safe, 100e6);
        _deliver(BaseSafePayloads.mintThreeF(_payloads, makeAddr("request"), 10e6), false);
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(_deployed.safe), 100e6);
    }

    /// @dev The Safe mints with the authorization it reads on Base, charges the policy with those amounts, mints
    /// as itself and keeps no approval.
    function test_AliasMintsWithLiveAuthorization() public {
        (PolicyRecorder policy, MockThreeFRequest request) = _mintSetup(10e6, 1e6);
        _deliver(BaseSafePayloads.mintThreeF(_payloads, address(request), 10e6), true);
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(_deployed.safe), 90e6);
        assertEq(request.minter(), _deployed.safe);
        assertEq(policy.calls(), 1);
        assertEq(policy.request(), address(request));
        assertEq(policy.assets(), 10e6);
        assertEq(policy.yieldAssets(), 1e6);
        assertEq(IERC20(BaseChain.BASE_USDC).allowance(_deployed.safe, address(request)), 0);
    }

    /// @dev A revoked or used authorization reverts the recipe, so the policy budget is not charged.
    function test_MintWithoutAuthorizationChargesNothing() public {
        (PolicyRecorder policy, MockThreeFRequest request) = _mintSetup(0, 0);
        _deliver(BaseSafePayloads.mintThreeF(_payloads, address(request), 10e6), false);
        assertEq(policy.calls(), 0);
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(_deployed.safe), 100e6);
    }

    /// @dev An authorization above the executor's cap reverts the recipe.
    function test_MintAboveCapChargesNothing() public {
        (PolicyRecorder policy, MockThreeFRequest request) = _mintSetup(10e6, 1e6);
        _deliver(BaseSafePayloads.mintThreeF(_payloads, address(request), 5e6), false);
        assertEq(policy.calls(), 0);
    }

    /// @dev A mint that moves no USDC fails the recipe's balance check, so the policy budget is not charged.
    function test_MintThatPullsNothingChargesNothing() public {
        (PolicyRecorder policy, MockThreeFRequest request) = _mintSetup(10e6, 1e6);
        request.setPulls(false);
        _deliver(BaseSafePayloads.mintThreeF(_payloads, address(request), 10e6), false);
        assertEq(policy.calls(), 0);
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(_deployed.safe), 100e6);
    }

    /// @dev The Safe redeems its whole position in a request that 3F's factory knows.
    function test_AliasRedeemsKnownRequest() public {
        MockThreeFRequest request = new MockThreeFRequest(IERC20(BaseChain.BASE_USDC));
        request.setBalances(_deployed.safe, 10e6, 1e6);
        deal(BaseChain.BASE_USDC, address(request), 11e6);
        _knownRequest(address(request));
        _deliver(BaseSafePayloads.redeemThreeF(_payloads, address(request)), true);
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(_deployed.safe), 11e6);
        (uint256 pt, uint256 yt) = request.balancesOf(_deployed.safe);
        assertEq(pt + yt, 0);
    }

    /// @dev The redeem recipe reverts for a request that 3F's factory does not know.
    function test_RedeemRejectsUnknownRequest() public {
        MockThreeFRequest request = new MockThreeFRequest(IERC20(BaseChain.BASE_USDC));
        request.setBalances(_deployed.safe, 10e6, 1e6);
        deal(BaseChain.BASE_USDC, address(request), 11e6);
        _deliver(BaseSafePayloads.redeemThreeF(_payloads, address(request)), false);
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(_deployed.safe), 0);
    }

    /// @dev An address that is not a module cannot use the module path.
    function test_OnlyAliasCanUseModulePath() public {
        IMerkleAccount.Action memory action = BaseSafePayloads.setMinYieldPerRequest(_payloads, UNDERLYING, 1);
        (, bytes memory module) = _l2Call(action);
        vm.prank(makeAddr("stranger"));
        (bool success,) = _deployed.safe.call(module);
        assertFalse(success);
    }

    /// @dev The alias approves one message from Ethereum; the Safe then accepts the alias signature for that digest
    /// only, and the local Safe message hash matches the fallback handler's.
    function test_AliasApprovesOneMessage() public {
        bytes32 digest = keccak256("EnrollMaker digest");
        bytes memory signature = BaseSafePayloads.aliasSignature(_payloads);
        vm.expectRevert();
        IERC1271(_deployed.safe).isValidSignature(digest, signature);

        (address to, bytes memory data) = _l2Call(BaseSafePayloads.approveMessage(_payloads, digest));
        vm.prank(BaseChain.l2Alias(_ethereumAccount));
        (bool success,) = to.call{gas: BaseChain.PORTAL_GAS_LIMIT - 21_000 - 16 * data.length}(data);
        assertTrue(success);

        assertEq(IERC1271(_deployed.safe).isValidSignature(digest, signature), IERC1271.isValidSignature.selector);
        (bool handled, bytes memory result) = _deployed.safe
            .staticcall(
                abi.encodeWithSignature("getMessageHashForSafe(address,bytes)", _deployed.safe, abi.encode(digest))
            );
        assertTrue(handled);
        assertEq(abi.decode(result, (bytes32)), BaseSafePayloads.safeMessageHash(_deployed.safe, digest));
        vm.expectRevert();
        IERC1271(_deployed.safe).isValidSignature(keccak256("USDC permit digest"), signature);
    }

    /// @dev Points the payloads at a policy recorder and funds the Safe with 100 USDC. Returns a mock request that
    /// has authorized the Safe for `pt` principal and `yt` yield.
    function _mintSetup(uint128 pt, uint128 yt) private returns (PolicyRecorder policy, MockThreeFRequest request) {
        policy = new PolicyRecorder();
        _payloads.policy = address(policy);
        request = new MockThreeFRequest(IERC20(BaseChain.BASE_USDC));
        request.authorizeMinting(_deployed.safe, pt, yt);
        deal(BaseChain.BASE_USDC, _deployed.safe, 100e6);
    }

    /// @dev Makes 3F's RequestFactory on Base report `request` as one of its requests.
    function _knownRequest(address request) private {
        vm.mockCall(
            BaseChain.THREE_F_REQUESTS_FACTORY,
            abi.encodeCall(IThreeFRequestFactory.isRequest, (request)),
            abi.encode(true)
        );
    }

    /// @dev Replays the L2 side of a portal deposit within its pinned gas limit: the alias calls the Safe with the
    /// deposit calldata. The Safe returns true even when the nested call fails, so the inner result is read from its
    /// module events.
    function _deliver(IMerkleAccount.Action memory action, bool innerSuccess) private {
        (address to, bytes memory module) = _l2Call(action);
        vm.recordLogs();
        vm.prank(BaseChain.l2Alias(_ethereumAccount));
        // A deposit's gas limit also pays the transaction's intrinsic and calldata gas.
        (bool success, bytes memory result) =
            to.call{gas: BaseChain.PORTAL_GAS_LIMIT - 21_000 - 16 * module.length}(module);
        assertTrue(success);
        assertTrue(abi.decode(result, (bool)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool failed;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == _deployed.safe
                    && logs[i].topics[0] == ISafeModules.ExecutionFromModuleFailure.selector
            ) failed = true;
        }
        assertEq(failed, !innerSuccess);
    }

    /// @dev Returns the L2 target and calldata carried by a portal deposit.
    function _l2Call(IMerkleAccount.Action memory action) private pure returns (address to, bytes memory module) {
        bytes memory arguments = new bytes(action.data.length - 4);
        for (uint256 i; i < arguments.length; ++i) {
            arguments[i] = action.data[i + 4];
        }
        (to,,,, module) = abi.decode(arguments, (address, uint256, uint64, bool, bytes));
    }
}

/// @dev Ethereum fork tests. Set ETH_RPC_URL to run them.
contract BaseSafeEthereumForkTest is Test {
    /// @dev OptimismPortal event carrying the aliased L2 sender.
    event TransactionDeposited(address indexed from, address indexed to, uint256 indexed version, bytes opaqueData);

    BaseSafePayloads.Deployment private _payloads;

    /// @dev Forks Ethereum with arbitrary Base deployment addresses.
    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "ETH_RPC_URL is required for the Base Safe Ethereum fork tests");
        vm.createSelectFork(rpc);
        _payloads = BaseSafePayloads.Deployment({
            ethereumAccount: makeAddr("ethereum account"),
            safe: makeAddr("safe"),
            recipeCapability: makeAddr("recipe capability"),
            policy: makeAddr("policy")
        });
    }

    /// @dev A deposit sent by the MerkleAccount reaches the Safe from the account alias.
    function test_PortalDepositIsSentFromAlias() public {
        IMerkleAccount.Action memory action = BaseSafePayloads.bridgeToEthereum(_payloads, 1e6);
        vm.recordLogs();
        vm.prank(_payloads.ethereumAccount);
        (bool success,) = action.target.call(action.data);
        assertTrue(success);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, BaseChain.BASE_PORTAL);
        assertEq(logs[0].topics[0], TransactionDeposited.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), BaseChain.l2Alias(_payloads.ethereumAccount));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), _payloads.safe);
    }

    /// @dev The Ethereum bridge actions burn the approved USDC from the MerkleAccount.
    function test_BridgeToBaseBurnsAccountUsdc() public {
        deal(BaseChain.ETHEREUM_USDC, _payloads.ethereumAccount, 100e6);
        IMerkleAccount.Action memory approval = BaseSafePayloads.approveBridge(30e6);
        IMerkleAccount.Action memory burn = BaseSafePayloads.bridgeToBase(_payloads, 30e6);
        vm.startPrank(_payloads.ethereumAccount);
        (bool approved,) = approval.target.call(approval.data);
        (bool burned,) = burn.target.call(burn.data);
        vm.stopPrank();
        assertTrue(approved && burned);
        assertEq(IERC20(BaseChain.ETHEREUM_USDC).balanceOf(_payloads.ethereumAccount), 70e6);
    }
}
