// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {BaseAliasPayloads} from "script/base-chain/BaseAliasPayloads.sol";
import {BaseChain} from "script/base-chain/BaseChain.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";

import {AssetRateLimits} from "src/contracts/merkle-adapter/libraries/AssetRateLimits.sol";

import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipes} from "src/interfaces/merkle-adapter/IRecipes.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";
import {Test, Vm} from "forge-std/Test.sol";

import {createThreeFPolicy} from "test/helpers/ThreeFPolicyFactory.sol";
import {
    ThreeFFacilityMock,
    ThreeFPositionManagerMock,
    ThreeFRequestFactoryMock,
    ThreeFRequestMock,
    ThreeFUnderlyingAssetMock
} from "test/mocks/ThreeFRequestMocks.sol";
import {Token} from "test/mocks/Token.sol";

import {CapabilityTestBase} from "./CapabilityTestBase.sol";

contract BaseAliasPortalRecorder {
    event TransactionDeposited(address indexed from, address indexed to, uint256 indexed version, bytes opaqueData);

    function depositTransaction(address to, uint256, uint64, bool, bytes calldata data) external {
        emit TransactionDeposited(BaseChain.l2Alias(msg.sender), to, 0, data);
    }
}

contract BaseAliasDispatchTest is CapabilityTestBase {
    using Bytes for bytes;

    function test_MintDispatchSendsOneBaseDeposit() public {
        _deployAdapter(address(new Token("Asset")));
        vm.etch(BaseChain.BASE_PORTAL, address(new BaseAliasPortalRecorder()).code);
        BaseAliasPayloads.Deployment memory deployment = BaseAliasPayloads.Deployment({
            ethereumAccount: account, manager: makeAddr("Base manager"), policy: makeAddr("Base policy")
        });
        IMerkleAccount.Action[] memory actions =
            BaseAliasPayloads.mintActions(deployment, makeAddr("wrong request"), 1, 1);
        bytes32 leaf = BaseAliasPayloads.leaf(actions[0]);
        roots.setRoot(account, leaf);
        IMerkleAccount(account).acceptRoot(leaf);
        address executor = address(new RecipeExecutor(address(this), account));
        MerkleAccount(payable(account)).grantRole(leaf, executor);
        ExecutingRecipe.Recipe memory recipe = BaseAliasPayloads.mintRecipe(deployment, 20e6);
        RecipeExecutor(executor).setRecipe(recipe.queries, recipe.steps);
        RecipeExecutor(executor).setCaller(address(this));

        address request = makeAddr("request");
        bytes[] memory runtime = new bytes[](1);
        runtime[0] = abi.encode(actions);
        vm.recordLogs();
        vm.expectRevert(IRecipes.CheckFailed.selector);
        RecipeExecutor(executor)
            .execute(recipe.queries, recipe.steps, BaseAliasPayloads.mintInputs(request, 20e6 + 1, 1e6), runtime);
        assertEq(vm.getRecordedLogs().length, 0);

        vm.recordLogs();
        RecipeExecutor(executor)
            .execute(recipe.queries, recipe.steps, BaseAliasPayloads.mintInputs(request, 10e6, 1e6), runtime);
        (,,,, bytes memory expected) = abi.decode(
            BaseAliasPayloads.mintThreeF(deployment, request, 10e6, 1e6).data.slice(4),
            (address, uint256, uint64, bool, bytes)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 deposits;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != BaseChain.BASE_PORTAL) continue;
            assertEq(logs[i].topics[0], BaseAliasPortalRecorder.TransactionDeposited.selector);
            assertEq(address(uint160(uint256(logs[i].topics[1]))), BaseAliasPayloads.aliasOf(deployment));
            assertEq(address(uint160(uint256(logs[i].topics[2]))), deployment.manager);
            assertEq(abi.decode(logs[i].data, (bytes)), expected);
            ++deposits;
        }
        assertEq(deposits, 1);
    }
}

contract BaseAliasMintTest is Test {
    using Bytes for bytes;

    address private constant UNDERLYING = address(0xBEEF);

    address private _request;
    address private _requestsFactory;
    BaseAliasPayloads.Deployment private _deployment;

    function setUp() public {
        vm.chainId(BaseChain.BASE_CHAIN_ID);
        vm.etch(BaseChain.BASE_USDC, address(new Token("USDC")).code);
        _deployment.ethereumAccount = makeAddr("Ethereum MerkleAccount");
        _deployment.manager = address(new AccessManager(BaseAliasPayloads.aliasOf(_deployment)));
        _request = address(new ThreeFRequestMock(BaseChain.BASE_USDC, "request-1"));
        _requestsFactory = address(new ThreeFRequestFactoryMock());
        ThreeFRequestFactoryMock(_requestsFactory).set(_request, true);
        address facility = address(new ThreeFFacilityMock());
        ThreeFFacilityMock(facility)
            .setIntent(
                1,
                _request,
                address(
                    new ThreeFPositionManagerMock(
                        address(new ThreeFUnderlyingAssetMock(UNDERLYING)), BaseChain.BASE_USDC
                    )
                ),
                true
            );
        _deployment.policy = createThreeFPolicy(address(this), _deployment.manager, _requestsFactory, facility);
        _deliver(BaseAliasPayloads.setMaxAssetsPerDuration(_deployment, UNDERLYING, 20e6, 1 days));
        _deliver(BaseAliasPayloads.setMinYieldPerRequest(_deployment, UNDERLYING, 10e6));
        deal(BaseChain.BASE_USDC, _deployment.manager, 100e6);
        ThreeFRequestMock(_request).authorizeMinting(_deployment.manager, 10e6, 1e6);
    }

    function test_OnlyAliasHasImmediateAdminRole() public view {
        (bool aliasAdmin, uint32 delay) =
            IAccessManager(_deployment.manager).hasRole(0, BaseAliasPayloads.aliasOf(_deployment));
        (bool deployerAdmin,) = IAccessManager(_deployment.manager).hasRole(0, address(this));
        assertTrue(aliasAdmin);
        assertEq(delay, 0);
        assertFalse(deployerAdmin);
    }

    function test_RevertedConsumeBlocksMint() public {
        _deliver(BaseAliasPayloads.setMaxAssetsPerDuration(_deployment, UNDERLYING, 9e6, 1 days));
        vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
        _deliver(BaseAliasPayloads.mintThreeF(_deployment, _request, 10e6, 1e6));
        _assertUnspent(9e6);
    }

    function test_MinimumYieldRejectionBlocksMint() public {
        _deliver(BaseAliasPayloads.setMinYieldPerRequest(_deployment, UNDERLYING, 10e6 + 1));
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        _deliver(BaseAliasPayloads.mintThreeF(_deployment, _request, 10e6, 1e6));
        _assertUnspent(20e6);
    }

    function test_UnregisteredRequestBlocksMint() public {
        ThreeFRequestFactoryMock(_requestsFactory).set(_request, false);
        vm.expectRevert(IThreeFPolicy.InvalidRequest.selector);
        _deliver(BaseAliasPayloads.mintThreeF(_deployment, _request, 10e6, 1e6));
        _assertUnspent(20e6);
    }

    function test_MintUsesManagerAndChargesLivePrincipal() public {
        _deliver(BaseAliasPayloads.mintThreeF(_deployment, _request, 12e6, 900_000));

        assertEq(ThreeFRequestMock(_request).mintCaller(), _deployment.manager);
        (uint256 pt, uint256 yt) = ThreeFRequestMock(_request).balancesOf(_deployment.manager);
        assertEq(pt, 10e6);
        assertEq(yt, 1e6);
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(_deployment.manager), 90e6);
        assertEq(IERC20(BaseChain.BASE_USDC).allowance(_deployment.manager, _request), 0);
        assertEq(IThreeFPolicy(_deployment.policy).remainingAssets(BaseChain.BASE_USDC, UNDERLYING), 10e6);
    }

    function test_MintFailureRollsBackPolicyAndAllowance() public {
        ThreeFRequestMock(_request).setFailMint(true);
        vm.expectRevert(ThreeFRequestMock.MintFailed.selector);
        _deliver(BaseAliasPayloads.mintThreeF(_deployment, _request, 10e6, 1e6));
        _assertUnspent(20e6);
        (uint128 principal, uint128 yieldAssets) = ThreeFRequestMock(_request).mintAuthorization(_deployment.manager);
        assertEq(principal, 10e6);
        assertEq(yieldAssets, 1e6);
    }

    function test_NoOpMintRollsBackPolicyAndAllowance() public {
        vm.mockCall(_request, abi.encodeCall(IThreeFPushRequest.mint, (10e6, 1e6)), bytes(""));
        vm.expectRevert(IThreeFPolicy.InvalidPushMintBalance.selector);
        _deliver(BaseAliasPayloads.mintThreeF(_deployment, _request, 10e6, 1e6));
        _assertUnspent(20e6);
    }

    function test_MintChecksCallerBoundsAndRevokedAuthorization() public {
        vm.expectRevert(IThreeFPolicy.InvalidPushMintAuthorization.selector);
        _deliver(BaseAliasPayloads.mintThreeF(_deployment, _request, 9e6, 1e6));
        vm.expectRevert(IThreeFPolicy.InvalidPushMintAuthorization.selector);
        _deliver(BaseAliasPayloads.mintThreeF(_deployment, _request, 10e6, 1e6 + 1));
        ThreeFRequestMock(_request).authorizeMinting(_deployment.manager, 0, 0);
        vm.expectRevert(IThreeFPolicy.InvalidPushMintAuthorization.selector);
        _deliver(BaseAliasPayloads.mintThreeF(_deployment, _request, 10e6, 0));
        _assertUnspent(20e6);
    }

    function test_MintRejectsWrongFundingAsset() public {
        address otherRequest = address(new ThreeFRequestMock(address(new Token("Other token")), "request-2"));
        vm.expectRevert(IThreeFPolicy.InvalidAsset.selector);
        _deliver(BaseAliasPayloads.mintThreeF(_deployment, otherRequest, 10e6, 1e6));
    }

    function test_NonAdminCannotExecuteMint() public {
        (, bytes memory data) = _decode(BaseAliasPayloads.mintThreeF(_deployment, _request, 10e6, 1e6));
        bytes[] memory batch = abi.decode(data.slice(4), (bytes[]));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                address(this),
                _deployment.policy,
                IThreeFPolicy.beginPushMint.selector
            )
        );
        AccessManager(_deployment.manager).multicall(batch);
        _assertUnspent(20e6);
    }

    function test_CheckCannotFinishWithoutStarting() public {
        vm.prank(_deployment.manager);
        vm.expectRevert(IThreeFPolicy.InvalidPushMintBalance.selector);
        IThreeFPolicy(_deployment.policy).finishPushMint(BaseChain.BASE_USDC);
    }

    function test_DoubleBeginRollsBackCharge() public {
        (, bytes memory data) = _decode(BaseAliasPayloads.mintThreeF(_deployment, _request, 10e6, 1e6));
        bytes[] memory mint = abi.decode(data.slice(4), (bytes[]));
        bytes[] memory batch = new bytes[](2);
        batch[0] = mint[0];
        batch[1] = mint[0];

        vm.prank(BaseAliasPayloads.aliasOf(_deployment));
        vm.expectRevert(IThreeFPolicy.InvalidPushMintBalance.selector);
        AccessManager(_deployment.manager).multicall(batch);
        _assertUnspent(20e6);
    }

    function test_InsufficientFundingRollsBackCharge() public {
        deal(BaseChain.BASE_USDC, _deployment.manager, 9e6);
        vm.expectRevert(IThreeFPolicy.InvalidPushMintBalance.selector);
        _deliver(BaseAliasPayloads.mintThreeF(_deployment, _request, 10e6, 1e6));
        assertEq(IThreeFPolicy(_deployment.policy).remainingAssets(BaseChain.BASE_USDC, UNDERLYING), 20e6);
    }

    function test_RedeemReturnsPTAndYTProceedsToManager() public {
        _deliver(BaseAliasPayloads.mintThreeF(_deployment, _request, 10e6, 1e6));
        ThreeFRequestMock(_request).setCanWithdraw(true);
        deal(BaseChain.BASE_USDC, _request, 11e6);
        _deliver(BaseAliasPayloads.redeemThreeF(_deployment, _request));
        (uint256 pt, uint256 yt) = ThreeFRequestMock(_request).balancesOf(_deployment.manager);
        assertEq(pt + yt, 0);
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(_deployment.manager), 101e6);
    }

    function _assertUnspent(uint256 budget) private view {
        assertEq(ThreeFRequestMock(_request).mintCalls(), 0);
        assertEq(IERC20(BaseChain.BASE_USDC).balanceOf(_deployment.manager), 100e6);
        assertEq(IERC20(BaseChain.BASE_USDC).allowance(_deployment.manager, _request), 0);
        assertEq(IThreeFPolicy(_deployment.policy).remainingAssets(BaseChain.BASE_USDC, UNDERLYING), budget);
    }

    function _deliver(IMerkleAccount.Action memory action) private {
        (address manager, bytes memory data) = _decode(action);
        if (bytes4(data) == Multicall.multicall.selector) {
            bytes[] memory batch = abi.decode(data.slice(4), (bytes[]));
            vm.prank(BaseAliasPayloads.aliasOf(_deployment));
            AccessManager(manager).multicall(batch);
        } else {
            (address target, bytes memory callData) = abi.decode(data.slice(4), (address, bytes));
            vm.prank(BaseAliasPayloads.aliasOf(_deployment));
            IAccessManager(manager).execute(target, callData);
        }
    }

    function _decode(IMerkleAccount.Action memory action) private pure returns (address manager, bytes memory data) {
        (manager,,,, data) = abi.decode(action.data.slice(4), (address, uint256, uint64, bool, bytes));
    }
}
