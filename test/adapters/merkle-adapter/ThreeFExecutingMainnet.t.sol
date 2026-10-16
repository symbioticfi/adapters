// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {RecipeCapability} from "src/contracts/merkle-adapter/capabilities/RecipeCapability.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {ThreeFPolicy} from "src/contracts/merkle-adapter/automations/policies/ThreeFPolicy.sol";

import {MerkleAdapterVerifier} from "src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IRecipeCapability} from "src/interfaces/merkle-adapter/capabilities/IRecipeCapability.sol";
import {
    IThreeFFacility,
    IThreeFPositionManager,
    IThreeFRequestName,
    IThreeFUnderlyingAsset
} from "src/interfaces/3f-adapter/IThreeFAdapterDependencies.sol";
import {
    IThreeFPolicy,
    REQUEST_NAME_PREFIX_LENGTH,
    YIELD_PRECISION
} from "src/interfaces/merkle-adapter/automations/policies/IThreeFPolicy.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFRequestFactory} from "src/interfaces/3f-adapter/IThreeFRequestFactory.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {ThreeFExecuting} from "script/recipes/ThreeFExecuting.sol";
import {ThreeFGuardedMint} from "script/recipes/ThreeFGuardedMint.sol";

import {createThreeFPolicy} from "test/helpers/ThreeFPolicyFactory.sol";

interface IThreeFNativeRequest is IThreeFPushRequest {
    function owner() external view returns (address);
    function authorizeMinting(address account, uint128 principal, uint128 yieldAmount) external;
}

/// @dev A pinned historical active request, using its actual factory and native mint code.
contract ThreeFExecutingMainnetTest is CapabilityTestBase {
    bytes internal _recipe;

    address internal constant REQUESTS_FACTORY = 0xDE293185e96a42F4c7d1C6479407920b19012Ca5;
    address internal constant FACILITY = 0x4e013ca8fF612a58F53C822904cDD0eC538a4A4F;
    address internal constant REQUEST = 0x4929b2Ef3356e1D5233a5459f1B7281FFC56a60E;
    uint128 internal constant PRINCIPAL = 100_000e6;
    uint128 internal constant YIELD = 2000e6;
    address internal _executor;
    address internal _asset;
    address internal _underlying;
    address internal _policy;
    IMerkleAccount.Action internal _approval;
    IMerkleAccount.Action internal _mint;
    IMerkleAccount.Action internal _foreignMint;
    bytes[] internal _runtime;
    bool internal _guardedMintMode = true;
    bool internal _skipZeroApprovals;
    bool internal _reuseTupleReads;

    function setUp() public virtual {
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
        _policy = createThreeFPolicy(address(this), account, REQUESTS_FACTORY, FACILITY);
        string memory name = IThreeFRequestName(REQUEST).name();
        (IThreeFFacility.IntentProperties memory properties,, address boundRequest,) =
            IThreeFFacility(FACILITY).getIntent(Strings.parseUint(name, REQUEST_NAME_PREFIX_LENGTH, bytes(name).length));
        assertEq(boundRequest, REQUEST);
        assertTrue(properties.targetAsset.isPositionManager);
        (address collateralAsset,) = IThreeFPositionManager(properties.targetAsset.asset).assets();
        _underlying = IThreeFUnderlyingAsset(collateralAsset).underlying();
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_underlying, PRINCIPAL, 1 days);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_underlying, uint256(YIELD) * YIELD_PRECISION / PRINCIPAL);
        _installCapability(adapter, address(new RecipeCapability()), _recipeSelectors());
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
        for (uint256 i = 36; i < 68; ++i) {
            _approval.dataMask[i] = 0xff;
        }
        _mint = _guardedMint(REQUEST);
        // A second published leaf lets the factory condition, rather than the proof, reject a non-request.
        _foreignMint = _guardedMint(_asset);
        _publish();
        _configureRecipe(REQUEST);
    }

    function _configureRecipe(address request) internal {
        ThreeFExecuting.Config memory config;
        config.funding = ExecutingRecipe.Funding({
            adapter: address(adapter),
            account: account,
            pushLeaf: bytes32(0),
            asset: _asset,
            skipUnusedReads: false,
            sources: new ExecutingRecipe.Source[](0)
        });
        config.request = request;
        config.guardedMint = _guardedMintMode;
        config.skipZeroApprovals = _skipZeroApprovals;
        config.reuseTupleReads = _reuseTupleReads;
        config.policy = _policy;
        config.maxPrincipal = PRINCIPAL;
        config.approvalLeaf = MerkleAdapterVerifier.leaf(_asset, 0, _approval.data, _approval.dataMask);
        IMerkleAccount.Action memory mint = request == REQUEST ? _mint : _foreignMint;
        config.mintLeaf = _leaf(mint);
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
        actions[0] = mint;
        _runtime[layout.operation] = abi.encode(actions);
    }

    /// @dev The leaf pins policy, funding asset and request; only the four amount words stay maskable.
    function _guardedMint(address request) internal view returns (IMerkleAccount.Action memory) {
        ThreeFGuardedMint.Leaf memory leaf = ThreeFGuardedMint.build(
            ThreeFGuardedMint.Config({account: account, asset: _asset, policy: _policy, request: request}),
            _reuseTupleReads
        );
        return IMerkleAccount.Action({
            target: account, value: 0, data: leaf.data, dataMask: leaf.dataMask, proof: new bytes32[](0)
        });
    }

    function _leaf(IMerkleAccount.Action memory action) internal pure returns (bytes32) {
        return MerkleAdapterVerifier.leaf(action.target, action.value, action.data, action.dataMask);
    }

    /// @dev Four-leaf balanced tree over approval, both guarded mints and one unused filler.
    function _publish() internal {
        bytes32[] memory tree = new bytes32[](8);
        tree[4] = _leaf(_approval);
        tree[5] = _leaf(_mint);
        tree[6] = _leaf(_foreignMint);
        tree[7] = keccak256("filler");
        for (uint256 i = 3; i > 0; --i) {
            bytes32 a = tree[i * 2];
            bytes32 b = tree[i * 2 + 1];
            tree[i] = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        }
        roots.setRoot(account, tree[1]);
        MerkleAccount(payable(account)).acceptRoot(tree[1]);
        _approval.proof = _proof(tree, 4);
        _mint.proof = _proof(tree, 5);
        _foreignMint.proof = _proof(tree, 6);
        for (uint256 i = 4; i < 7; ++i) {
            MerkleAccount(payable(account)).grantRole(tree[i], _executor);
        }
    }

    function _proof(bytes32[] memory tree, uint256 index) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](2);
        proof[0] = tree[index ^ 1];
        proof[1] = tree[(index / 2) ^ 1];
    }

    function _requestInput() internal view returns (uint256[] memory inputs) {
        inputs = new uint256[](3);
        inputs[0] = uint160(_selectedRequest);
        inputs[1] = PRINCIPAL;
        inputs[2] = YIELD;
    }

    function _execute() internal {
        (bytes[] memory queries, bytes[] memory steps) = abi.decode(_recipe, (bytes[], bytes[]));
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
        assertEq(ThreeFPolicy(_policy).remainingAssets(_underlying), 0);
    }

    /// forge-config: default.isolate = true
    function test_MainnetConditionalApprovalCleanupSavesGas() public {
        uint256 state = vm.snapshotState();
        _execute();
        uint256 originalGas = vm.snapshotGasLastCall(
            "ThreeFExecutingMainnet", _guardedMintMode ? "guardedUnconditionalCleanup" : "directUnconditionalCleanup"
        );
        assertTrue(vm.revertToState(state));
        _skipZeroApprovals = true;
        _configureRecipe(REQUEST);
        _execute();
        uint256 optimizedGas = vm.snapshotGasLastCall(
            "ThreeFExecutingMainnet", _guardedMintMode ? "guardedConditionalCleanup" : "directConditionalCleanup"
        );
        assertLt(optimizedGas, originalGas);
        assertEq(IERC20(_asset).allowance(account, REQUEST), 0);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        (uint256 principal, uint256 yieldAssets) = IThreeFNativeRequest(REQUEST).balancesOf(account);
        assertEq(principal, PRINCIPAL);
        assertEq(yieldAssets, YIELD);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_underlying), 0);
        emit log_named_uint("native 3F cleanup gas saved", originalGas - optimizedGas);
    }

    /// forge-config: default.isolate = true
    function test_MainnetTupleReadReuseSavesGas() public {
        _skipZeroApprovals = false;
        _configureTupleReads(false);
        uint256 beforeCash = IERC20(_asset).balanceOf(REQUEST);
        uint256 state = vm.snapshotState();
        _execute();
        uint256 originalGas = vm.snapshotGasLastCall(
            "ThreeFExecutingMainnet", _guardedMintMode ? "guardedSeparateTupleReads" : "directSeparateTupleReads"
        );
        _assertNativeMint(beforeCash);
        assertTrue(vm.revertToState(state));
        _configureTupleReads(true);
        _execute();
        uint256 optimizedGas = vm.snapshotGasLastCall(
            "ThreeFExecutingMainnet", _guardedMintMode ? "guardedCachedTupleReads" : "directCachedTupleReads"
        );
        _assertNativeMint(beforeCash);
        assertLt(optimizedGas, originalGas);
        emit log_named_uint("native 3F separate tuple reads gas", originalGas);
        emit log_named_uint("native 3F cached tuple reads gas", optimizedGas);
        emit log_named_uint("native 3F tuple reads gas saved", originalGas - optimizedGas);
    }

    function test_MainnetFactoryRejectsNonRequest() public {
        vm.mockCall(REQUESTS_FACTORY, abi.encodeCall(IThreeFRequestFactory.isRequest, (REQUEST)), abi.encode(false));
        vm.expectRevert(IThreeFPolicy.InvalidRequest.selector);
        _execute();
        assertEq(IERC20(_asset).balanceOf(account), PRINCIPAL);
    }

    function test_MainnetOwnerChangesYieldWithoutRootUpdate() public {
        ThreeFPolicy(_policy).setMinYieldPerRequest(_underlying, uint256(YIELD) * YIELD_PRECISION / PRINCIPAL + 1);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        _execute();
        ThreeFPolicy(_policy).setMinYieldPerRequest(_underlying, uint256(YIELD) * YIELD_PRECISION / PRINCIPAL);
        _execute();
    }

    function _configureTupleReads(bool enabled) internal {
        _reuseTupleReads = enabled;
        if (_guardedMintMode) {
            _mint = _guardedMint(REQUEST);
            _foreignMint = _guardedMint(_asset);
            _publish();
        }
        _configureRecipe(REQUEST);
    }

    function _assertNativeMint(uint256 beforeCash) internal view {
        assertEq(IERC20(_asset).balanceOf(REQUEST), beforeCash + PRINCIPAL);
        assertEq(IERC20(_asset).balanceOf(account), 0);
        assertEq(IERC20(_asset).allowance(account, REQUEST), 0);
        (uint256 principal, uint256 yieldAssets) = IThreeFNativeRequest(REQUEST).balancesOf(account);
        assertEq(principal, PRINCIPAL);
        assertEq(yieldAssets, YIELD);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_underlying), 0);
    }
}

contract ThreeFDirectExecutingMainnetTest is ThreeFExecutingMainnetTest {
    function setUp() public virtual override {
        super.setUp();
        _guardedMintMode = false;
        ThreeFPolicy(_policy).setConsumer(_executor);
        address[] memory capabilities = IMerkleAccount(account).getCapabilities();
        IMerkleAccount(account).removeCapability(capabilities[0]);
        _mint = _nativeMint(REQUEST);
        _foreignMint = _nativeMint(_asset);
        _publish();
        _configureRecipe(REQUEST);
    }

    function _nativeMint(address request) internal pure returns (IMerkleAccount.Action memory action) {
        bytes memory data = abi.encodeCall(IThreeFPushRequest.mint, (0, 0));
        action = IMerkleAccount.Action({
            target: request, value: 0, data: data, dataMask: new bytes(data.length), proof: new bytes32[](0)
        });
        for (uint256 i = 4; i < data.length; ++i) {
            action.dataMask[i] = 0xff;
        }
    }
}

contract ThreeFCachedExecutingMainnetTest is ThreeFExecutingMainnetTest {
    function setUp() public override {
        super.setUp();
        _configureTupleReads(true);
    }
}

contract ThreeFCachedDirectExecutingMainnetTest is ThreeFDirectExecutingMainnetTest {
    function setUp() public override {
        super.setUp();
        _configureTupleReads(true);
    }
}
