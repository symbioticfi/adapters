// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {ThreeFExecuting} from "script/recipes/ThreeFExecuting.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {ThreeFPolicy} from "src/contracts/merkle-adapter/automations/ThreeFPolicy.sol";
import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/automations/IThreeFPolicy.sol";
import {IThreeFRequestFactory} from "src/interfaces/3f-adapter/IThreeFRequestFactory.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
    IMerkleAdapter.Action internal _approval;
    IMerkleAdapter.Action internal _mint;
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
        _executor = address(new RecipeExecutor(address(this), address(adapter)));
        RecipeExecutor(_executor).setCaller(address(this));
        _policy = address(new ThreeFPolicy(address(this), _executor));
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(PRINCIPAL, 1 days);
        ThreeFPolicy(_policy).setMinYieldPerRequest(20_000);
        deal(_asset, address(adapter), PRINCIPAL);
        vm.prank(IThreeFNativeRequest(REQUEST).owner());
        IThreeFNativeRequest(REQUEST).authorizeMinting(address(adapter), PRINCIPAL, YIELD);
        _approval = IMerkleAdapter.Action(
            _asset, 0, abi.encodeCall(IERC20.approve, (REQUEST, PRINCIPAL)), new bytes(68), new bytes32[](1)
        );
        _mint = IMerkleAdapter.Action(
            REQUEST, 0, abi.encodeCall(IThreeFPushRequest.mint, (PRINCIPAL, YIELD)), new bytes(68), new bytes32[](1)
        );
        for (uint256 i = 36; i < 68; ++i) {
            _approval.dataMask[i] = 0xff;
        }
        for (uint256 i = 4; i < 68; ++i) {
            _mint.dataMask[i] = 0xff;
        }
        bytes32 a = MerkleAdapterVerifier.leaf(_asset, 0, _approval.data, _approval.dataMask);
        bytes32 b = MerkleAdapterVerifier.leaf(REQUEST, 0, _mint.data, _mint.dataMask);
        bytes32 root = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        roots.setRoot(address(adapter), root);
        adapter.acceptRoot(root);
        adapter.grantRole(a, _executor);
        adapter.grantRole(b, _executor);
        _approval.proof[0] = b;
        _mint.proof[0] = a;
        _configureRecipe(REQUEST);
    }

    function _configureRecipe(address request) internal {
        ThreeFExecuting.Config memory config;
        config.funding = ExecutingRecipe.Funding(address(adapter), _asset, new ExecutingRecipe.Source[](0));
        config.request = request;
        config.requestsFactory = REQUESTS_FACTORY;
        config.policy = _policy;
        config.maxPrincipal = PRINCIPAL;
        config.approvalLeaf = MerkleAdapterVerifier.leaf(_asset, 0, _approval.data, _approval.dataMask);
        config.mintLeaf = MerkleAdapterVerifier.leaf(REQUEST, 0, _mint.data, _mint.dataMask);
        (IRecipeExecutor.Recipe memory recipe, ThreeFExecuting.Layout memory layout) = ThreeFExecuting.build(config);
        _recipe = abi.encode(recipe);
        RecipeExecutor(_executor).setRecipe(recipe);
        delete _runtime;
        uint256 runtimeLength = ExecutingRecipe.runtimeSteps(recipe).length;
        for (uint256 i; i < runtimeLength; ++i) {
            _runtime.push("");
        }
        _runtime[layout.approve] = abi.encode(IRecipeExecutor.Permission(_approval.dataMask, _approval.proof));
        _runtime[layout.clearApproval] = _runtime[layout.approve];
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](1);
        actions[0] = _mint;
        _runtime[layout.operation] = abi.encode(actions);
    }

    function test_MainnetFactoryAndNativeMintFromAdapter() public {
        uint256 beforeCash = IERC20(_asset).balanceOf(REQUEST);
        RecipeExecutor(_executor).execute(abi.decode(_recipe, (IRecipeExecutor.Recipe)), new uint256[](0), _runtime);
        assertEq(IERC20(_asset).balanceOf(REQUEST), beforeCash + PRINCIPAL);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 0);
        assertEq(IERC20(_asset).allowance(address(adapter), REQUEST), 0);
        (uint256 principal, uint256 yieldAssets) = IThreeFNativeRequest(REQUEST).balancesOf(address(adapter));
        assertEq(principal, PRINCIPAL);
        assertEq(yieldAssets, YIELD);
        assertEq(ThreeFPolicy(_policy).remainingAssets(), 0);
    }

    function test_MainnetFactoryRejectsNonRequest() public {
        _configureRecipe(_asset);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        RecipeExecutor(_executor).execute(abi.decode(_recipe, (IRecipeExecutor.Recipe)), new uint256[](0), _runtime);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), PRINCIPAL);
    }

    function test_MainnetOwnerChangesYieldWithoutRootUpdate() public {
        ThreeFPolicy(_policy).setMinYieldPerRequest(20_001);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        RecipeExecutor(_executor).execute(abi.decode(_recipe, (IRecipeExecutor.Recipe)), new uint256[](0), _runtime);
        ThreeFPolicy(_policy).setMinYieldPerRequest(20_000);
        RecipeExecutor(_executor).execute(abi.decode(_recipe, (IRecipeExecutor.Recipe)), new uint256[](0), _runtime);
    }
}
