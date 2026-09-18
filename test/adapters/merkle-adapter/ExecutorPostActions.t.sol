// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ActionOracleMock} from "./LiquidLaneConnector.t.sol";
import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {ExecutorLiquiditySource} from "./Executor.t.sol";
import {ExecutorTestHelper} from "./ExecutorTestHelper.sol";
import {ImmutableFactory} from "../../../src/contracts/common/ImmutableFactory.sol";
import {LiquidLaneConnector} from "../../../src/contracts/merkle-adapter/LiquidLaneConnector.sol";
import {LiquidLaneExecutor} from "src/contracts/periphery/LiquidLaneExecutor.sol";
import {OracleRegistry} from "../../../src/contracts/merkle-adapter/OracleRegistry.sol";
import {Token} from "../../mocks/Token.sol";

import {IAssetRateLimits} from "../../../src/interfaces/merkle-adapter/IAssetRateLimits.sol";
import {IExecutor} from "../../../src/interfaces/periphery/IExecutor.sol";
import {IImmutableFactory} from "../../../src/interfaces/common/IImmutableFactory.sol";
import {ILiquidLaneConnector} from "../../../src/interfaces/merkle-adapter/ILiquidLaneConnector.sol";
import {ILiquidLaneExecutor} from "src/interfaces/periphery/ILiquidLaneExecutor.sol";
import {IMerkleAdapter} from "../../../src/interfaces/IMerkleAdapter.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

contract ExecutorPostActionsTest is CapabilityTestBase, ExecutorTestHelper {
    address internal _asset;
    address internal _rwa;
    address internal _executor;
    address internal _lane;
    address internal _source;
    address internal _redeemer;
    address internal _recipient = makeAddr("recipient");
    address internal _stranger = makeAddr("stranger");

    function setUp() public {
        _asset = address(new Token("Funding"));
        _rwa = address(new ExecutorPostActionToken());
        _deployAdapter(_asset);
        address registry = address(new OracleRegistry(address(this)));
        address prices = address(new MigratablesFactory(address(this)));
        MigratablesFactory(prices).whitelist(address(new ActionOracleMock(prices, 1e18)));
        address lanes = address(new MigratablesFactory(address(this)));
        MigratablesFactory(lanes).whitelist(address(new LiquidLaneConnector(lanes, registry)));
        _lane =
            MigratablesFactory(lanes).create(1, address(this), abi.encode(address(adapter), _asset, new address[](0)));
        _executor = IImmutableFactory(address(new ImmutableFactory(type(LiquidLaneExecutor).creationCode)))
            .create(abi.encode(address(this), address(adapter), _lane));
        LiquidLaneExecutor(_executor).setCaller(address(this));
        LiquidLaneExecutor(_executor).setSigner(address(this));
        OracleRegistry(registry)
            .setOracle(_lane, _rwa, MigratablesFactory(prices).create(1, address(this), abi.encode(_asset, _lane)));
        _manage(_lane, abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (_rwa)));
        _manage(_lane, abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (_rwa, type(uint256).max, 1 days)));
        IERC20(_rwa).transfer(_lane, 1_000_000);

        _source = address(new ExecutorLiquiditySource(IERC20(_asset), address(adapter)));
        IERC20(_asset).transfer(_source, 1_000_000);
        ExecutorLiquiditySource(_source).setLiquidity(1_000_000);
        _redeemer = address(new ExecutorPostActionRedeemer(_rwa, _asset));
        IERC20(_asset).transfer(_redeemer, 1_000_000);
        IERC20(_rwa).transfer(_redeemer, 1_000_000);
    }

    function test_OnlyOwnerCanSetPostActionLeaves() public {
        vm.prank(_stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _stranger));
        LiquidLaneExecutor(_executor).setPostActionLeaves(_rwa, new bytes32[](0));
    }

    function test_ReplaceAndClearExposeOnlyCurrentLeaves() public {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("first");
        leaves[1] = keccak256("second");
        LiquidLaneExecutor(_executor).setPostActionLeaves(_rwa, leaves);
        assertEq(LiquidLaneExecutor(_executor).postActionLeavesLength(_rwa), 2);
        assertEq(LiquidLaneExecutor(_executor).postActionLeaves(_rwa, 0), leaves[0]);
        assertEq(LiquidLaneExecutor(_executor).postActionLeaves(_rwa, 1), leaves[1]);
        leaves = new bytes32[](1);
        leaves[0] = keccak256("replacement");
        LiquidLaneExecutor(_executor).setPostActionLeaves(_rwa, leaves);
        assertEq(LiquidLaneExecutor(_executor).postActionLeavesLength(_rwa), 1);
        assertEq(LiquidLaneExecutor(_executor).postActionLeaves(_rwa, 0), leaves[0]);
        assertEq(LiquidLaneExecutor(_executor).postActionLeavesLength(_asset), 0);
        LiquidLaneExecutor(_executor).setPostActionLeaves(_rwa, new bytes32[](0));
        assertEq(LiquidLaneExecutor(_executor).postActionLeavesLength(_rwa), 0);
    }

    function test_EmptyPolicyAllowsSwapWithoutPosts() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](0);
        _publish(actions, posts);
        _execute(actions, posts);
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 100);
        assertEq(IERC20(_asset).balanceOf(_recipient), 100);
    }

    function test_EmptyPolicyRejectsPostsEvenWithValidRootAndRole() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = _bareRedeem(100);
        _publish(actions, posts);
        vm.expectRevert(ILiquidLaneExecutor.InvalidPostActions.selector);
        _execute(actions, posts);
        _assertRollback(0);
    }

    function test_NonemptyPolicyRequiresPosts() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = _bareRedeem(100);
        _publish(actions, posts);
        _allow(_rwa, posts);
        vm.expectRevert(ILiquidLaneExecutor.InvalidPostActions.selector);
        _execute(actions, new IMerkleAdapter.Action[](0));
        _assertRollback(0);
    }

    function test_ReplacementRejectsOldLeafDespiteValidRootAndRole() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = _bareRedeem(100);
        _publish(actions, posts);
        _allow(_rwa, posts);
        bytes32[] memory replacement = new bytes32[](1);
        replacement[0] = keccak256("replacement");
        LiquidLaneExecutor(_executor).setPostActionLeaves(_rwa, replacement);
        vm.expectRevert(IExecutor.InvalidAction.selector);
        _execute(actions, posts);
        _assertRollback(0);
    }

    function test_ClearingPolicyPermitsSwapButProhibitsPreviousPosts() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = _bareRedeem(100);
        _publish(actions, posts);
        _allow(_rwa, posts);
        LiquidLaneExecutor(_executor).setPostActionLeaves(_rwa, new bytes32[](0));
        vm.expectRevert(ILiquidLaneExecutor.InvalidPostActions.selector);
        _execute(actions, posts);
        _assertRollback(0);
        _execute(actions, new IMerkleAdapter.Action[](0));
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 100);
    }

    function test_LeafAllowedForAnotherTokenCannotBeUsed() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = _bareRedeem(100);
        _publish(actions, posts);
        _allow(_asset, posts);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = keccak256("different leaf for RWA");
        LiquidLaneExecutor(_executor).setPostActionLeaves(_rwa, leaves);
        vm.expectRevert(IExecutor.InvalidAction.selector);
        _execute(actions, posts);
        _assertRollback(0);
    }

    function test_ChangedMaskCannotReuseAllowedLeaf() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = _bareRedeem(100);
        _publish(actions, posts);
        _allow(_rwa, posts);
        posts[0].dataMask[4] = 0xff;
        vm.expectRevert(IExecutor.InvalidAction.selector);
        _execute(actions, posts);
        _assertRollback(0);
    }

    function test_EveryPostLeafMustBeAllowed() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = _approvedRedeem(100, 0);
        _publish(actions, posts);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _leaf(posts[0]);
        LiquidLaneExecutor(_executor).setPostActionLeaves(_rwa, leaves);
        vm.expectRevert(IExecutor.InvalidAction.selector);
        _execute(actions, posts);
        _assertRollback(0);
    }

    function test_InvalidMaskLengthUsesCanonicalLeafValidation() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = _bareRedeem(100);
        _publish(actions, posts);
        _allow(_rwa, posts);
        posts[0].dataMask = new bytes(0);
        vm.expectRevert(IMerkleAdapter.InvalidDataMaskLength.selector);
        _execute(actions, posts);
        _assertRollback(0);
    }

    function test_InvalidProofRollsBackFundingAndSwap() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = _bareRedeem(100);
        _publish(actions, posts);
        _allow(_rwa, posts);
        posts[0].proof[0] ^= bytes32(uint256(1));
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        _execute(actions, posts);
        _assertRollback(0);
    }

    function test_MissingProofRollsBackFundingAndSwap() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = _bareRedeem(100);
        _publish(actions, posts);
        _allow(_rwa, posts);
        posts[0].proof = new bytes32[](0);
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        _execute(actions, posts);
        _assertRollback(0);
    }

    function test_CallerRoleCannotReplaceExecutorRole() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = _bareRedeem(100);
        _publish(actions, posts);
        _allow(_rwa, posts);
        bytes32 leaf = _leaf(posts[0]);
        adapter.revokeRole(leaf, _executor);
        assertTrue(adapter.hasRole(leaf, address(this)));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _executor, leaf)
        );
        _execute(actions, posts);
        _assertRollback(0);
    }

    function testFuzz_BareRedeemPreservesPriorHoldings(uint256 amount, uint256 prior) public {
        amount = bound(amount, 1, 1_000_000);
        prior = bound(prior, 0, 1_000_000);
        IERC20(_rwa).transfer(address(adapter), prior);
        IMerkleAdapter.Action[] memory actions = _plan(amount);
        IMerkleAdapter.Action[] memory posts = _bareRedeem(amount);
        _publish(actions, posts);
        _allow(_rwa, posts);
        _execute(actions, posts);
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), prior);
        assertEq(IERC20(_asset).balanceOf(_recipient), amount);
        assertEq(ExecutorPostActionToken(_rwa).redeemed(), amount);
    }

    function test_ApprovalThenRedeemReturnsFundingAsset() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = _approvedRedeem(100, 115);
        _publish(actions, posts);
        _allow(_rwa, posts);
        _execute(actions, posts);
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 0);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 115);
        assertEq(IERC20(_asset).balanceOf(_recipient), 100);
        assertEq(IERC20(_rwa).allowance(address(adapter), _redeemer), 0);
        assertEq(ExecutorPostActionRedeemer(_redeemer).redeemed(), 100);
    }

    function test_RedeemsSwappedRwaAmountRatherThanFundingAmount() public {
        IMerkleAdapter.Action[] memory actions = _plan(80);
        actions[2] = _action(
            _lane, abi.encodeCall(ILiquidLaneConnector.swap, (ILiquidLaneConnector.Swap(_recipient, _rwa, 100, 80)))
        );
        IMerkleAdapter.Action[] memory posts = _bareRedeem(100);
        _publish(actions, posts);
        _allow(_rwa, posts);
        _execute(actions, posts);
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 0);
        assertEq(ExecutorPostActionToken(_rwa).redeemed(), 100);
        assertEq(IERC20(_asset).balanceOf(_recipient), 80);
    }

    function testFuzz_RepeatedAllowedLeafCanRedeemInTwoCalls(uint256 first) public {
        first = bound(first, 1, 99);
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](3);
        posts[0] = _action(_rwa, abi.encodeCall(IERC20.approve, (_redeemer, 100)));
        posts[1] = _action(_redeemer, abi.encodeCall(ExecutorPostActionRedeemer.redeem, (first, uint256(0))));
        posts[2] = _action(_redeemer, abi.encodeCall(ExecutorPostActionRedeemer.redeem, (100 - first, uint256(0))));
        for (uint256 i = 4; i < 36; ++i) {
            posts[1].dataMask[i] = 0xff;
            posts[2].dataMask[i] = 0xff;
        }
        _publish(actions, posts);
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(posts[0]);
        leaves[1] = _leaf(posts[1]);
        assertEq(leaves[1], _leaf(posts[2]));
        LiquidLaneExecutor(_executor).setPostActionLeaves(_rwa, leaves);
        _execute(actions, posts);
        assertEq(ExecutorPostActionRedeemer(_redeemer).calls(), 2);
        assertEq(ExecutorPostActionRedeemer(_redeemer).redeemed(), 100);
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), 0);
    }

    function test_UnusedAllowedLeavesDoNotRequireExecution() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = _bareRedeem(100);
        _publish(actions, posts);
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("unused alternative");
        leaves[1] = _leaf(posts[0]);
        LiquidLaneExecutor(_executor).setPostActionLeaves(_rwa, leaves);
        _execute(actions, posts);
        assertEq(ExecutorPostActionToken(_rwa).redeemed(), 100);
    }

    function testFuzz_UnderConsumptionReverts(uint256 consumed) public {
        consumed = bound(consumed, 0, 99);
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = _bareRedeem(consumed);
        _publish(actions, posts);
        _allow(_rwa, posts);
        vm.expectRevert(ILiquidLaneExecutor.PostActionBalanceMismatch.selector);
        _execute(actions, posts);
        _assertRollback(0);
    }

    function testFuzz_OverConsumptionCannotSpendPriorHoldings(uint256 excess) public {
        excess = bound(excess, 1, 1_000_000);
        IERC20(_rwa).transfer(address(adapter), excess);
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = _bareRedeem(100 + excess);
        _publish(actions, posts);
        _allow(_rwa, posts);
        vm.expectRevert(ILiquidLaneExecutor.PostActionBalanceMismatch.selector);
        _execute(actions, posts);
        _assertRollback(excess);
    }

    function test_ApprovalAloneDoesNotSatisfyRequiredRedemption() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](1);
        posts[0] = _action(_rwa, abi.encodeCall(IERC20.approve, (_redeemer, 100)));
        _publish(actions, posts);
        _allow(_rwa, posts);
        vm.expectRevert(ILiquidLaneExecutor.PostActionBalanceMismatch.selector);
        _execute(actions, posts);
        _assertRollback(0);
    }

    function test_BalanceIncreaseRevertsWithExplicitBalanceError() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](1);
        posts[0] = _action(_redeemer, abi.encodeCall(ExecutorPostActionRedeemer.give, (uint256(1))));
        _publish(actions, posts);
        _allow(_rwa, posts);
        vm.expectRevert(ILiquidLaneExecutor.PostActionBalanceMismatch.selector);
        _execute(actions, posts);
        _assertRollback(0);
    }

    function test_RedemptionRevertRollsBackApprovalFundingAndSwap() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = _approvedRedeem(100, 0);
        ExecutorPostActionRedeemer(_redeemer).setFail(true);
        _publish(actions, posts);
        _allow(_rwa, posts);
        vm.expectRevert(ExecutorPostActionRedeemer.RedemptionFailed.selector);
        _execute(actions, posts);
        _assertRollback(0);
    }

    function test_LaterPostFailureRollsBackEarlierRedemption() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](2);
        posts[0] = _action(_rwa, abi.encodeCall(ExecutorPostActionToken.redeem, (uint256(100))));
        posts[1] = _action(_redeemer, abi.encodeCall(ExecutorPostActionRedeemer.redeem, (uint256(0), uint256(0))));
        ExecutorPostActionRedeemer(_redeemer).setFail(true);
        _publish(actions, posts);
        _allow(_rwa, posts);
        vm.expectRevert(ExecutorPostActionRedeemer.RedemptionFailed.selector);
        _execute(actions, posts);
        _assertRollback(0);
    }

    function test_PostLeafBudgetRemainsEnforcedByAdapter() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = _bareRedeem(100);
        _publish(actions, posts);
        _allow(_rwa, posts);
        IMerkleAdapter.LeafLimit[] memory limits = new IMerkleAdapter.LeafLimit[](1);
        limits[0] = IMerkleAdapter.LeafLimit(_rwa, 99, 1 days);
        adapter.setLeafLimits(_leaf(posts[0]), limits);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        _execute(actions, posts);
        _assertRollback(0);
    }

    function test_RedemptionCannotReenterExecutor() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = _approvedRedeem(100, 0);
        _publish(actions, posts);
        _allow(_rwa, posts);
        ExecutorPostActionRedeemer(_redeemer).setCallback(_executor, _liquidLaneCall(_executor, actions, posts, 0));
        LiquidLaneExecutor(_executor).setCaller(_redeemer);
        vm.prank(_redeemer);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        _execute(actions, posts);
        _assertRollback(0);
    }

    function test_OwnerRedemptionCallbackCannotReplacePolicy() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = _approvedRedeem(100, 0);
        _publish(actions, posts);
        _allow(_rwa, posts);
        LiquidLaneExecutor(_executor).transferOwnership(_redeemer);
        ExecutorPostActionRedeemer(_redeemer)
            .setCallback(_executor, abi.encodeCall(ILiquidLaneExecutor.setPostActionLeaves, (_rwa, new bytes32[](0))));
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        _execute(actions, posts);
        _assertRollback(0);
        assertEq(LiquidLaneExecutor(_executor).postActionLeavesLength(_rwa), 2);
    }

    function test_OwnerFundingCallbackCannotReplacePolicy() public {
        IMerkleAdapter.Action[] memory actions = _plan(100);
        IMerkleAdapter.Action[] memory posts = _bareRedeem(100);
        _publish(actions, posts);
        _allow(_rwa, posts);
        LiquidLaneExecutor(_executor).transferOwnership(_source);
        ExecutorLiquiditySource(_source)
            .setCallback(_executor, abi.encodeCall(ILiquidLaneExecutor.setPostActionLeaves, (_rwa, new bytes32[](0))));
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        _execute(actions, posts);
        _assertRollback(0);
        assertEq(LiquidLaneExecutor(_executor).postActionLeavesLength(_rwa), 1);
    }

    function _execute(IMerkleAdapter.Action[] memory actions, IMerkleAdapter.Action[] memory posts) internal {
        ILiquidLaneConnector.Swap memory swap = abi.decode(_arguments(actions[2].data), (ILiquidLaneConnector.Swap));
        _runLiquidLane(_executor, actions, posts, 1_000_000 - swap.amountOut * 1_000_000 / swap.amountIn);
    }

    function _plan(uint256 amount) internal view returns (IMerkleAdapter.Action[] memory actions) {
        actions = new IMerkleAdapter.Action[](3);
        actions[0] = _action(_source, abi.encodeCall(ExecutorLiquiditySource.withdraw, (address(adapter), amount)));
        actions[1] = _action(_asset, abi.encodeCall(IERC20.approve, (_lane, amount)));
        actions[2] = _action(
            _lane,
            abi.encodeCall(ILiquidLaneConnector.swap, (ILiquidLaneConnector.Swap(_recipient, _rwa, amount, amount)))
        );
    }

    function _bareRedeem(uint256 amount) internal view returns (IMerkleAdapter.Action[] memory posts) {
        posts = new IMerkleAdapter.Action[](1);
        posts[0] = _action(_rwa, abi.encodeCall(ExecutorPostActionToken.redeem, (amount)));
    }

    function _approvedRedeem(uint256 amount, uint256 refund)
        internal
        view
        returns (IMerkleAdapter.Action[] memory posts)
    {
        posts = new IMerkleAdapter.Action[](2);
        posts[0] = _action(_rwa, abi.encodeCall(IERC20.approve, (_redeemer, amount)));
        posts[1] = _action(_redeemer, abi.encodeCall(ExecutorPostActionRedeemer.redeem, (amount, refund)));
    }

    function _action(address target, bytes memory data) internal pure returns (IMerkleAdapter.Action memory) {
        return IMerkleAdapter.Action(target, 0, data, new bytes(data.length), new bytes32[](0));
    }

    function _allow(address token, IMerkleAdapter.Action[] memory posts) internal {
        bytes32[] memory leaves = new bytes32[](posts.length);
        for (uint256 i; i < posts.length; ++i) {
            leaves[i] = _leaf(posts[i]);
        }
        LiquidLaneExecutor(_executor).setPostActionLeaves(token, leaves);
    }

    function _publish(IMerkleAdapter.Action[] memory actions, IMerkleAdapter.Action[] memory posts) internal {
        for (uint256 i = 36; i < 68; ++i) {
            actions[1].dataMask[i] = 0xff;
        }
        uint256 count = actions.length + posts.length;
        uint256 width = 1;
        uint256 depth;
        while (width < count) {
            width *= 2;
            ++depth;
        }
        bytes32[] memory tree = new bytes32[](width * 2);
        for (uint256 i; i < count; ++i) {
            bytes32 leaf = _leaf(i < actions.length ? actions[i] : posts[i - actions.length]);
            tree[width + i] = leaf;
            adapter.grantRole(leaf, address(this));
            adapter.grantRole(leaf, _executor);
        }
        for (uint256 i = width - 1; i > 0; --i) {
            bytes32 a = tree[i * 2];
            bytes32 b = tree[i * 2 + 1];
            tree[i] = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        }
        for (uint256 i; i < count; ++i) {
            bytes32[] memory proof = new bytes32[](depth);
            uint256 index = width + i;
            for (uint256 j; j < depth; ++j) {
                proof[j] = tree[index ^ 1];
                index /= 2;
            }
            if (i < actions.length) actions[i].proof = proof;
            else posts[i - actions.length].proof = proof;
        }
        roots.setRoot(address(adapter), tree[1]);
        adapter.acceptRoot(tree[1]);
        IExecutor.Action[] memory configuration = new IExecutor.Action[](1);
        for (uint256 i; i < configuration.length; ++i) {
            configuration[i] = IExecutor.Action(
                i == 0 ? _source : address(0),
                i == 0 ? abi.encodeCall(ExecutorLiquiditySource.getLiquidity, ()) : bytes(""),
                _leaf(actions[i])
            );
        }
        LiquidLaneExecutor(_executor).setActions(configuration, _leaf(actions[1]), _leaf(actions[2]));
    }

    function _leaf(IMerkleAdapter.Action memory action) internal pure returns (bytes32) {
        bytes memory masked = new bytes(action.data.length);
        for (uint256 i; i < masked.length; ++i) {
            masked[i] = action.data[i] & ~action.dataMask[i];
        }
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        action.target,
                        action.value == 0 ? bytes1(0) : bytes1(0xff),
                        keccak256(action.dataMask),
                        keccak256(masked)
                    )
                )
            )
        );
    }

    function _assertRollback(uint256 priorRwa) internal view {
        assertEq(ExecutorLiquiditySource(_source).calls(), 0);
        assertEq(ExecutorLiquiditySource(_source).withdrawn(), 0);
        assertEq(IERC20(_asset).balanceOf(_source), 1_000_000);
        assertEq(IERC20(_asset).balanceOf(address(adapter)), 0);
        assertEq(IERC20(_asset).balanceOf(_recipient), 0);
        assertEq(IERC20(_asset).allowance(address(adapter), _lane), 0);
        assertEq(IERC20(_rwa).balanceOf(_lane), 1_000_000);
        assertEq(IERC20(_rwa).balanceOf(address(adapter)), priorRwa);
        assertEq(IERC20(_rwa).allowance(address(adapter), _redeemer), 0);
        assertEq(ExecutorPostActionToken(_rwa).redeemed(), 0);
        assertEq(ExecutorPostActionRedeemer(_redeemer).calls(), 0);
        assertEq(LiquidLaneConnector(_lane).remainingAssets(_rwa), type(uint256).max);
    }
}

contract ExecutorPostActionToken is ERC20 {
    uint256 public redeemed;

    constructor() ERC20("Redeemable RWA", "RWA") {
        _mint(msg.sender, 10_000_000);
    }

    function redeem(uint256 amount) public {
        _burn(msg.sender, amount);
        redeemed += amount;
    }
}

contract ExecutorPostActionRedeemer {
    error RedemptionFailed();

    address public immutable rwa;
    address public immutable asset;
    uint256 public calls;
    uint256 public redeemed;
    bool public fail;
    address public callbackTarget;
    bytes public callbackData;

    constructor(address newRwa, address newAsset) {
        rwa = newRwa;
        asset = newAsset;
    }

    function setFail(bool newFail) public {
        fail = newFail;
    }

    function setCallback(address target, bytes calldata data) public {
        callbackTarget = target;
        callbackData = data;
    }

    function redeem(uint256 amount, uint256 refund) public {
        if (fail) revert RedemptionFailed();
        ++calls;
        redeemed += amount;
        IERC20(rwa).transferFrom(msg.sender, address(this), amount);
        IERC20(asset).transfer(msg.sender, refund);
        if (callbackTarget != address(0)) {
            (bool success, bytes memory result) = callbackTarget.call(callbackData);
            if (!success) {
                assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
            }
        }
    }

    function give(uint256 amount) public {
        IERC20(rwa).transfer(msg.sender, amount);
    }
}
