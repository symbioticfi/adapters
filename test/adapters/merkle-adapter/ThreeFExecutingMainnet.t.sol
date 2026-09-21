// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {ThreeFPolicy} from "src/contracts/merkle-adapter/automations/ThreeFPolicy.sol";

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/automations/IThreeFPolicy.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFRequestFactory} from "src/interfaces/3f-adapter/IThreeFRequestFactory.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {ThreeFExecuting} from "script/recipes/ThreeFExecuting.sol";

interface IThreeFNativeRequest is IThreeFPushRequest {
    function owner() external view returns (address);
    function authorizeMinting(address account, uint128 principal, uint128 yieldAmount) external;
}

/// @dev A pinned historical active request, using its actual factory and native mint code.
contract ThreeFExecutingMainnetTest is CapabilityTestBase {
    bytes internal _recipe;

    address internal constant REQUESTS_FACTORY = 0xDE293185e96a42F4c7d1C6479407920b19012Ca5;
    address internal constant REQUEST = 0x4929b2Ef3356e1D5233a5459f1B7281FFC56a60E;
    uint128 internal constant PRINCIPAL = 100_000e6;
    uint128 internal constant YIELD = 2000e6;
    address internal _executor;
    address internal _asset;
    address internal _policy;
    IMerkleAccount.Action internal _approval;
    IMerkleAccount.Action internal _mint;
    bytes[] internal _runtime;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 25_892_000);
        assertTrue(IThreeFRequestFactory(REQUESTS_FACTORY).isRequest(REQUEST));
        _asset = IThreeFNativeRequest(REQUEST).asset();
        _deployAdapter(_asset);
        _executor = address(new RecipeExecutor(address(this), account));
        RecipeExecutor(_executor).setCaller(address(this));
        _policy = address(new ThreeFPolicy(address(this), _executor));
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(PRINCIPAL, 1 days);
        ThreeFPolicy(_policy).setMinYieldPerRequest(20_000);
        deal(_asset, account, PRINCIPAL);
        vm.prank(IThreeFNativeRequest(REQUEST).owner());
        IThreeFNativeRequest(REQUEST).authorizeMinting(account, PRINCIPAL, YIELD);
        _approval = IMerkleAccount.Action({
            target: _asset,
            value: 0,
            data: abi.encodeCall(IERC20.approve, (REQUEST, PRINCIPAL)),
            dataMask: new bytes(68),
            proof: new bytes32[](1)
        });
        _mint = IMerkleAccount.Action({
            target: REQUEST,
            value: 0,
            data: abi.encodeCall(IThreeFPushRequest.mint, (PRINCIPAL, YIELD)),
            dataMask: new bytes(68),
            proof: new bytes32[](1)
        });
        for (uint256 i = 36; i < 68; ++i) {
            _approval.dataMask[i] = 0xff;
        }
        for (uint256 i = 4; i < 68; ++i) {
            _mint.dataMask[i] = 0xff;
        }
        bytes32 a = MerkleAdapterVerifier.leaf(_asset, 0, _approval.data, _approval.dataMask);
        bytes32 b = MerkleAdapterVerifier.leaf(REQUEST, 0, _mint.data, _mint.dataMask);
        bytes32 root = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        roots.setRoot(account, root);
        MerkleAccount(payable(account)).acceptRoot(root);
        MerkleAccount(payable(account)).grantRole(a, _executor);
        MerkleAccount(payable(account)).grantRole(b, _executor);
        _approval.proof[0] = b;
        _mint.proof[0] = a;
        _configureRecipe(REQUEST);
    }

    function _configureRecipe(address request) internal {
        ThreeFExecuting.Config memory config;
        config.funding = ExecutingRecipe.Funding({
            adapter: address(adapter),
            account: account,
            pushLeaf: bytes32(0),
            asset: _asset,
            sources: new ExecutingRecipe.Source[](0)
        });
        config.request = request;
        config.requestsFactory = REQUESTS_FACTORY;
        config.policy = _policy;
        config.maxPrincipal = PRINCIPAL;
        config.approvalLeaf = MerkleAdapterVerifier.leaf(_asset, 0, _approval.data, _approval.dataMask);
        config.mintLeaf = MerkleAdapterVerifier.leaf(REQUEST, 0, _mint.data, _mint.dataMask);
        (ExecutingRecipe.Recipe memory recipe, ThreeFExecuting.Layout memory layout) = ThreeFExecuting.build(config);
        _recipe = abi.encode(recipe.queries, recipe.steps);
        RecipeExecutor(_executor).setRecipe(recipe.queries, recipe.steps);
        delete _runtime;
        uint256 runtimeLength = ExecutingRecipe.runtimeSteps(recipe).length;
        for (uint256 i; i < runtimeLength; ++i) {
            _runtime.push("");
        }
        _runtime[layout.approve] = abi.encode(_approval.dataMask, _approval.proof);
        _runtime[layout.clearApproval] = _runtime[layout.approve];
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        actions[0] = _mint;
        _runtime[layout.operation] = abi.encode(actions);
    }

    function _execute() internal {
        (bytes[] memory queries, IRecipeExecutor.Step[] memory steps) =
            abi.decode(_recipe, (bytes[], IRecipeExecutor.Step[]));
        RecipeExecutor(_executor).execute(queries, steps, new uint256[](0), _runtime);
    }

    function test_MainnetFactoryAndNativeMintFromAdapter() public {
        uint256 beforeCash = IERC20(_asset).balanceOf(REQUEST);
        _execute();
        assertEq(IERC20(_asset).balanceOf(REQUEST), beforeCash + PRINCIPAL);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).allowance(account, REQUEST), 0);
        (uint256 principal, uint256 yieldAssets) = IThreeFNativeRequest(REQUEST).balancesOf(account);
        assertEq(principal, PRINCIPAL);
        assertEq(yieldAssets, YIELD);
        assertEq(ThreeFPolicy(_policy).remainingAssets(), 0);
    }

    function test_MainnetFactoryRejectsNonRequest() public {
        _configureRecipe(_asset);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _execute();
        assertEq(IERC20(_asset).balanceOf(account), PRINCIPAL);
    }

    function test_MainnetOwnerChangesYieldWithoutRootUpdate() public {
        ThreeFPolicy(_policy).setMinYieldPerRequest(20_001);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        _execute();
        ThreeFPolicy(_policy).setMinYieldPerRequest(20_000);
        _execute();
    }
}
