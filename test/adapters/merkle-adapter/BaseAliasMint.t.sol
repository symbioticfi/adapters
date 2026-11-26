// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {BaseAliasPayloads} from "script/base-chain/BaseAliasPayloads.sol";
import {BaseChain} from "script/base-chain/BaseChain.sol";
import {TestnetPermissions} from "script/deploy/testnet/TestnetPermissions.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {BaseAliasThreeFPolicy} from "src/contracts/merkle-adapter/capabilities/policies/BaseAliasThreeFPolicy.sol";
import {AssetRateLimits} from "src/contracts/merkle-adapter/libraries/AssetRateLimits.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IBaseAliasThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IBaseAliasThreeFPolicy.sol";
import {IOptimismPortal} from "script/utils/interfaces/IOptimismPortal.sol";

import {Token} from "test/mocks/Token.sol";

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {Vm} from "forge-std/Vm.sol";

contract BaseAliasPortalRecorder {
    event TransactionDeposited(address indexed from, address indexed to, uint256 indexed version, bytes opaqueData);

    function depositTransaction(address to, uint256, uint64, bool, bytes calldata data) external {
        emit TransactionDeposited(BaseChain.l2Alias(msg.sender), to, 0, data);
    }
}

contract BaseAliasMintTest is CapabilityTestBase {
    address private constant REQUEST = address(0x3F);
    address private constant UNDERLYING = address(0xBEEF);

    address private _policy;
    address private _executor;
    ExecutingRecipe.Recipe private _recipe;
    bytes private _actions;

    function setUp() public {
        vm.chainId(BaseChain.ETHEREUM_CHAIN_ID);
        _deployAdapter(address(new Token("Asset")));
        vm.etch(BaseChain.BASE_PORTAL, address(new BaseAliasPortalRecorder()).code);

        _policy = address(new BaseAliasThreeFPolicy(account));
        BaseAliasPayloads.Deployment memory deployment =
            BaseAliasPayloads.Deployment({ethereumAccount: account, policy: _policy});
        IMerkleAccount.Action[] memory actions = BaseAliasPayloads.mintActions(deployment, address(0), 0, 0);
        (bytes32 root, bytes32[] memory leaves) = TestnetPermissions.authorize(actions);
        roots.setRoot(account, root);
        IMerkleAccount(account).acceptRoot(root);
        _actions = abi.encode(actions);

        _executor = address(new RecipeExecutor(address(this), account));
        _recipe = BaseAliasPayloads.mintRecipe(deployment, 100e6);
        RecipeExecutor(_executor).setRecipe(_recipe.queries, _recipe.steps);
        RecipeExecutor(_executor).setCaller(address(this));
        for (uint256 i; i < leaves.length; ++i) {
            MerkleAccount(payable(account)).grantRole(leaves[i], _executor);
        }
    }

    function test_RevertedConsumeSendsZeroBaseDeposits() public {
        _configure(9e6, 0);
        _expectRejectedDispatch(AssetRateLimits.AssetLimitExceeded.selector);
        assertEq(IBaseAliasThreeFPolicy(_policy).remainingAssets(UNDERLYING), 9e6);
    }

    function test_UnregisteredRequestSendsZeroBaseDeposits() public {
        _expectRejectedDispatch(IBaseAliasThreeFPolicy.InvalidRequest.selector);
    }

    function test_RevokedRequestSendsZeroBaseDeposits() public {
        _configure(20e6, 0);
        vm.prank(account);
        IBaseAliasThreeFPolicy(_policy).setRequestUnderlying(REQUEST, address(0));
        _expectRejectedDispatch(IBaseAliasThreeFPolicy.InvalidRequest.selector);
    }

    function test_TooLowYieldSendsZeroBaseDeposits() public {
        _configure(20e6, 10e6 + 1);
        _expectRejectedDispatch(IBaseAliasThreeFPolicy.TooLowYield.selector);
        assertEq(IBaseAliasThreeFPolicy(_policy).remainingAssets(UNDERLYING), 20e6);
    }

    function test_PolicyConfigurationRequiresTheBoundAccount() public {
        vm.expectRevert(IBaseAliasThreeFPolicy.InvalidCaller.selector);
        IBaseAliasThreeFPolicy(_policy).setRequestUnderlying(REQUEST, UNDERLYING);
        vm.expectRevert(IBaseAliasThreeFPolicy.InvalidCaller.selector);
        IBaseAliasThreeFPolicy(_policy).setMaxAssetsPerDuration(UNDERLYING, 20e6, 1 days);
        vm.expectRevert(IBaseAliasThreeFPolicy.InvalidCaller.selector);
        IBaseAliasThreeFPolicy(_policy).setMinYieldPerRequest(UNDERLYING, 10e6);
        vm.expectRevert(IBaseAliasThreeFPolicy.InvalidCaller.selector);
        IBaseAliasThreeFPolicy(_policy).consume(REQUEST, 10e6, 1e6);
    }

    function test_ValidConsumeSendsThreeBaseDepositsFromAlias() public {
        _configure(20e6, 10e6);
        vm.recordLogs();
        _dispatch();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address[3] memory targets = [BaseChain.BASE_USDC, REQUEST, BaseChain.BASE_USDC];
        uint256 deposits;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != BaseChain.BASE_PORTAL) continue;
            assertEq(logs[i].topics[0], BaseAliasPortalRecorder.TransactionDeposited.selector);
            assertEq(address(uint160(uint256(logs[i].topics[1]))), BaseChain.l2Alias(account));
            assertEq(address(uint160(uint256(logs[i].topics[2]))), targets[deposits++]);
        }
        assertEq(deposits, 3);
        assertEq(IBaseAliasThreeFPolicy(_policy).remainingAssets(UNDERLYING), 10e6);
    }

    function test_RevertedPortalCallRollsBackEthereumBudget() public {
        _configure(20e6, 0);
        bytes memory errorData = abi.encodeWithSignature("Error(string)", "portal rejected deposit");
        vm.mockCallRevert(
            BaseChain.BASE_PORTAL, abi.encodePacked(IOptimismPortal.depositTransaction.selector), errorData
        );

        vm.expectRevert(errorData);
        _dispatch();
        assertEq(IBaseAliasThreeFPolicy(_policy).remainingAssets(UNDERLYING), 20e6);
    }

    function _configure(uint256 maxAssets, uint256 minYield) private {
        vm.startPrank(account);
        IBaseAliasThreeFPolicy(_policy).setRequestUnderlying(REQUEST, UNDERLYING);
        IBaseAliasThreeFPolicy(_policy).setMaxAssetsPerDuration(UNDERLYING, maxAssets, 1 days);
        IBaseAliasThreeFPolicy(_policy).setMinYieldPerRequest(UNDERLYING, minYield);
        vm.stopPrank();
    }

    function _expectRejectedDispatch(bytes4 selector) private {
        vm.recordLogs();
        vm.expectRevert(selector);
        _dispatch();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].emitter, BaseChain.BASE_PORTAL);
        }
    }

    function _dispatch() private {
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = _actions;
        RecipeExecutor(_executor)
            .execute(_recipe.queries, _recipe.steps, BaseAliasPayloads.mintInputs(REQUEST, 10e6, 1e6), runtime);
    }
}
