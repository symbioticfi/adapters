// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {CapabilitiesRegistry} from "src/contracts/merkle_adapter/CapabilitiesRegistry.sol";
import {CapabilitiesRegistryProposer} from "src/contracts/merkle_adapter/CapabilitiesRegistryProposer.sol";
import {Test} from "forge-std/Test.sol";
import {Executor} from "../../../src/contracts/periphery/Executor.sol";
import {IExecutor} from "../../../src/interfaces/periphery/IExecutor.sol";
import {AdapterFactory} from "../../../src/contracts/AdapterFactory.sol";
import {MerkleAdapter} from "../../../src/contracts/MerkleAdapter.sol";
import {LiquidLaneAction} from "../../../src/contracts/merkle_adapter/LiquidLaneAction.sol";
import {OracleRegistry} from "../../../src/contracts/merkle_adapter/OracleRegistry.sol";
import {RootRegistry} from "../../../src/contracts/merkle_adapter/RootRegistry.sol";
import {ANY_VALUE, ANY_VALUE_FLAG, IMerkleAdapter} from "../../../src/interfaces/IMerkleAdapter.sol";
import {ILiquidLaneAction} from "../../../src/interfaces/merkle_adapter/ILiquidLaneAction.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Token} from "../../mocks/Token.sol";
import {
    MerkleAdapterVaultRegistry,
    MerkleAdapterVaultMock,
    MerkleAdapterDelegatorMock,
    MerkleAdapterOracleMock
} from "../MerkleAdapter.t.sol";
import {ActionOracleMock} from "./LiquidLaneAction.t.sol";
import {ThreeFAction} from "../../../src/contracts/merkle_adapter/ThreeFAction.sol";
import {IThreeFAction} from "../../../src/interfaces/merkle_adapter/IThreeFAction.sol";
import {IAssetRateLimits} from "../../../src/interfaces/merkle_adapter/IAssetRateLimits.sol";
import {IThreeFWhitelist} from "../../../src/interfaces/3f-adapter/IThreeFWhitelist.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {BorrowAction} from "../../../src/contracts/merkle_adapter/BorrowAction.sol";
import {IBorrowAction} from "../../../src/interfaces/merkle_adapter/IBorrowAction.sol";
import {BorrowActionPoolMock} from "./mocks/BorrowActionMocks.sol";
import {
    ThreeFActionRequestMock,
    ThreeFActionWhitelistMock,
    ThreeFActionFacilityMock,
    ThreeFActionPositionManagerMock,
    ThreeFActionCollateralMock
} from "../../mocks/ThreeFActionPushMocks.sol";

contract ExecutorTest is Test {
    Executor internal executor;
    MerkleAdapter internal adapter;
    MerkleAdapterOracleMock internal oracle;
    MerkleAdapterVaultMock internal vault;
    MerkleAdapterDelegatorMock internal delegator;
    RootRegistry internal roots;
    Token internal asset;
    Token internal rwa;
    LiquidLaneAction internal lane;
    OracleRegistry internal registry;
    ExecutorLiquiditySource internal source;
    address internal recipient = makeAddr("recipient");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        executor = new Executor();
        asset = new Token("Funding");
        rwa = new Token("RWA");
        vault = new MerkleAdapterVaultMock(address(asset));
        delegator = new MerkleAdapterDelegatorMock(address(vault));
        vault.setDelegator(address(delegator));
        MerkleAdapterVaultRegistry vaults = new MerkleAdapterVaultRegistry();
        vaults.add(address(vault));
        AdapterFactory adapters = new AdapterFactory(address(this));
        MigratablesFactory oracles = new MigratablesFactory(address(this));
        oracles.whitelist(address(new MerkleAdapterOracleMock(address(oracles))));
        roots = new RootRegistry(address(this));
        adapters.whitelist(
            address(
                new MerkleAdapter(
                    address(vaults),
                    address(adapters),
                    address(oracles),
                    address(roots),
                    address(
                        new CapabilitiesRegistry(
                            address(this), address(new CapabilitiesRegistryProposer(address(this)))
                        )
                    )
                )
            )
        );
        adapter = MerkleAdapter(
            payable(adapters.create(
                    1, address(this), abi.encode(address(vault), abi.encode(IMerkleAdapter.InitParams(address(this))))
                ))
        );
        oracle = MerkleAdapterOracleMock(adapter.oracle());

        registry = new OracleRegistry(address(this));
        MigratablesFactory prices = new MigratablesFactory(address(this));
        prices.whitelist(address(new ActionOracleMock(address(prices), 1e18)));
        MigratablesFactory lanes = new MigratablesFactory(address(this));
        lanes.whitelist(address(new LiquidLaneAction(address(lanes), address(registry))));
        lane = LiquidLaneAction(
            lanes.create(1, address(this), abi.encode(address(adapter), address(asset), new address[](0)))
        );
        address priceOracle = prices.create(1, address(this), abi.encode(address(asset), address(lane)));
        registry.setOracle(address(lane), address(rwa), priceOracle);
        IMerkleAdapter.Action[] memory configuration = new IMerkleAdapter.Action[](2);
        configuration[0] = _action(address(lane), abi.encodeCall(ILiquidLaneAction.addTokenToRedeem, (address(rwa))));
        configuration[1] = _action(
            address(lane),
            abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (address(rwa), type(uint256).max, 1 days))
        );
        _publish(new IExecutor.LiquidityStep[](0), configuration);
        adapter.manage(configuration);
        rwa.transfer(address(lane), 1_000_000);
        source = new ExecutorLiquiditySource(asset, address(adapter));
        asset.transfer(address(source), 1_000_000);
        source.setLiquidity(1_000_000);
    }

    function test_IdleFirstAndExactRemainingWithdrawal() public {
        asset.transfer(address(adapter), 40);
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);

        executor.execute(address(adapter), steps, actions);

        assertEq(source.withdrawn(), 60);
        assertEq(source.calls(), 1);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(recipient), 100);
        assertEq(rwa.balanceOf(address(adapter)), 100);
    }

    function test_OracleRefreshInSingleMerkleBatchRequiresBothLeafRoles() public {
        address savedOracle = lane.oracles(address(rwa));
        address replacement = address(new ActionOracleMock(address(0), 2e18));
        registry.setOracle(address(lane), address(rwa), replacement);
        IMerkleAdapter.Action[] memory actions = _oracleRefresh();
        _publish(new IExecutor.LiquidityStep[](0), actions);
        adapter.grantRole(_leaf(actions[0]), stranger);
        bytes32 addRole = _leaf(actions[1]);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, addRole)
        );
        adapter.manage(actions);
        assertEq(lane.oracles(address(rwa)), savedOracle);

        adapter.manage(actions);
        assertEq(lane.oracles(address(rwa)), replacement);
        assertEq(lane.getAmountOut(address(rwa), 100), 200);
        assertEq(lane.getTokensToRedeemLength(), 1);
        assertEq(lane.tokensToRedeem(0), address(rwa));
    }

    function test_OracleRefreshRollsBackRemovalWhenApprovalMissing() public {
        address savedOracle = lane.oracles(address(rwa));
        uint256 remaining = lane.remainingAssets(address(rwa));
        registry.setOracle(address(lane), address(rwa), address(0));
        IMerkleAdapter.Action[] memory actions = _oracleRefresh();
        _publish(new IExecutor.LiquidityStep[](0), actions);

        vm.expectRevert(ILiquidLaneAction.InvalidOracle.selector);
        adapter.manage(actions);

        assertEq(lane.oracles(address(rwa)), savedOracle);
        assertEq(lane.getTokensToRedeemLength(), 1);
        assertEq(lane.tokensToRedeem(0), address(rwa));
        assertEq(lane.remainingAssets(address(rwa)), remaining);
        assertEq(lane.getAmountOut(address(rwa), 100), 100);
    }

    function test_CuratorConfigurationLeavesRequireTheirOwnRoles() public {
        (ThreeFAction threeF,) = _newThreeF(100);
        IMerkleAdapter.Action[] memory configuration = new IMerkleAdapter.Action[](3);
        configuration[0] = _action(
            address(lane), abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (address(rwa), 100, 1 days))
        );
        configuration[1] = _action(
            address(threeF), abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (address(rwa), 200, 2 days))
        );
        configuration[2] =
            _action(address(threeF), abi.encodeCall(IThreeFAction.setMinYieldPerRequest, (address(rwa), 10_000)));
        _publish(new IExecutor.LiquidityStep[](0), configuration);
        for (uint256 i; i < configuration.length; ++i) {
            adapter.revokeRole(_leaf(configuration[i]), address(executor));
        }
        bytes32 role = _leaf(configuration[0]);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        adapter.manage(configuration);
        adapter.manage(configuration);
        assertEq(lane.remainingAssets(address(rwa)), 100);
        assertEq(threeF.remainingAssets(address(rwa)), 200);
        assertEq(threeF.minYieldPerRequest(address(rwa)), 10_000);
    }

    function test_LiquidLaneBudgetFailureRollsBackExecutorLiquidity() public {
        vm.prank(address(adapter));
        lane.setMaxAssetsPerDuration(address(rwa), 99, 1 days);
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        executor.execute(address(adapter), steps, actions);
        assertEq(source.withdrawn(), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(recipient), 0);
        assertEq(asset.allowance(address(adapter), address(lane)), 0);
        assertEq(lane.remainingAssets(address(rwa)), 99);
    }

    function test_ThreeFBudgetFailureRollsBackExecutorLiquidity() public {
        (ThreeFAction threeF, ThreeFActionRequestMock request) = _newThreeF(100);
        vm.prank(address(adapter));
        threeF.setMaxAssetsPerDuration(address(rwa), 99, 1 days);
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) =
            _threeFPlan(threeF, request, 100);
        _publish(steps, actions);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        executor.execute(address(adapter), steps, actions);
        assertEq(source.withdrawn(), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(address(request)), 0);
        assertEq(asset.allowance(address(adapter), address(threeF)), 0);
        assertEq(threeF.requestsLength(), 0);
        assertEq(threeF.remainingAssets(address(rwa)), 99);
    }

    function test_InsufficientLiquidityRollsBackWithdrawalsAndApproval() public {
        source.setLiquidity(30);
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        vm.expectRevert(IExecutor.InsufficientLiquidity.selector);
        executor.execute(address(adapter), steps, actions);
        assertEq(source.calls(), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.allowance(address(adapter), address(lane)), 0);
    }

    function test_ReceivedAmountMismatchRevertsEverything() public {
        source.setAdjustment(-1);
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        vm.expectRevert(abi.encodeWithSelector(IExecutor.LiquidityMismatch.selector));
        executor.execute(address(adapter), steps, actions);
        assertEq(source.calls(), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(recipient), 0);
    }

    function test_PublicCallerCannotUseExecutorRoles() public {
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, _leaf(steps[0].action)
            )
        );
        executor.execute(address(adapter), steps, actions);
        assertEq(source.calls(), 0);
    }

    function test_ExecutorNeedsItsOwnLeafRoles() public {
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        bytes32 leaf = _leaf(actions[1]);
        adapter.revokeRole(leaf, address(executor));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(executor), leaf)
        );
        executor.execute(address(adapter), steps, actions);
    }

    function test_AllFinalRolesAreCheckedBeforeWithdrawing() public {
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        bytes32 leaf = _leaf(actions[1]);
        adapter.revokeRole(leaf, address(this));
        vm.expectCall(address(source), abi.encodeCall(source.withdraw, (address(adapter), 100)), uint64(0));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), leaf)
        );
        executor.execute(address(adapter), steps, actions);
    }

    function test_ProofsAreCheckedBeforeWithdrawing() public {
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        actions[1].proof[0] = bytes32(uint256(123));
        vm.expectCall(address(source), abi.encodeCall(source.withdraw, (address(adapter), 100)), uint64(0));
        vm.expectRevert(IExecutor.InvalidActionProof.selector);
        executor.execute(address(adapter), steps, actions);
    }

    function test_SkipsLiquidityQueriesWhenIdleSuffices() public {
        asset.transfer(address(adapter), 110);
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        steps[0].liquidityData = abi.encodeCall(source.failQuery, ());
        _publish(steps, actions);
        executor.execute(address(adapter), steps, actions);
        assertEq(source.calls(), 0);
        assertEq(asset.balanceOf(address(adapter)), 10);
    }

    function test_EmptySourcesUseExistingIdle() public {
        asset.transfer(address(adapter), 100);
        (, IMerkleAdapter.Action[] memory actions) = _plan(100);
        IExecutor.LiquidityStep[] memory steps = new IExecutor.LiquidityStep[](0);
        _publish(steps, actions);
        executor.execute(address(adapter), steps, actions);
        assertEq(asset.balanceOf(recipient), 100);
    }

    function test_QueriesEachSourceJustBeforeUsingIt() public {
        ExecutorLiquiditySource second = new ExecutorLiquiditySource(asset, address(adapter));
        asset.transfer(address(second), 1000);
        second.setLiquidity(1);
        source.setLiquidity(30);
        source.setCallback(address(second), abi.encodeCall(second.setLiquidity, (70)));
        (, IMerkleAdapter.Action[] memory actions) = _plan(100);
        IExecutor.LiquidityStep[] memory steps = new IExecutor.LiquidityStep[](2);
        steps[0] = _step(source);
        steps[1] = _step(second);
        _publish(steps, actions);
        executor.execute(address(adapter), steps, actions);
        assertEq(source.withdrawn(), 30);
        assertEq(second.withdrawn(), 70);
    }

    function test_ZeroCapacityIsSkipped() public {
        source.setLiquidity(0);
        ExecutorLiquiditySource second = new ExecutorLiquiditySource(asset, address(adapter));
        asset.transfer(address(second), 1000);
        second.setLiquidity(1000);
        (, IMerkleAdapter.Action[] memory actions) = _plan(100);
        IExecutor.LiquidityStep[] memory steps = new IExecutor.LiquidityStep[](2);
        steps[0] = _step(source);
        steps[1] = _step(second);
        _publish(steps, actions);
        executor.execute(address(adapter), steps, actions);
        assertEq(source.calls(), 0);
        assertEq(second.withdrawn(), 100);
    }

    function test_ExcessReceivedAmountAlsoReverts() public {
        source.setAdjustment(1);
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        vm.expectRevert(abi.encodeWithSelector(IExecutor.LiquidityMismatch.selector));
        executor.execute(address(adapter), steps, actions);
    }

    function test_DecreasingBalanceIsNotLiquidity() public {
        asset.transfer(address(adapter), 100);
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(200);
        steps[0].action = _action(address(asset), abi.encodeCall(IERC20.transfer, (address(source), 0)));
        for (uint256 i = 36; i < 68; ++i) {
            steps[0].action.dataMask[i] = 0;
        }
        _publish(steps, actions);
        vm.expectRevert(abi.encodeWithSelector(IExecutor.LiquidityMismatch.selector));
        executor.execute(address(adapter), steps, actions);
        assertEq(asset.balanceOf(address(adapter)), 100);
    }

    function test_FinalBatchMustSpendExactlyOperationAmount() public {
        asset.transfer(address(adapter), 10);
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory original) = _plan(100);
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](3);
        actions[0] = _action(address(source), abi.encodeCall(source.give, (address(adapter), 1)));
        actions[1] = original[0];
        actions[2] = original[1];
        _publish(steps, actions);
        vm.expectRevert(abi.encodeWithSelector(IExecutor.OperationBalanceMismatch.selector));
        executor.execute(address(adapter), steps, actions);
        assertEq(source.calls(), 0);
        assertEq(asset.balanceOf(address(adapter)), 10);
        assertEq(asset.balanceOf(recipient), 0);
    }

    function test_PendingAllocationRemainsReserved() public {
        asset.transfer(address(vault), 50);
        delegator.allocate(address(adapter), 50);
        assertEq(executor.availableBalance(address(adapter), address(asset)), 0);
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        executor.execute(address(adapter), steps, actions);
        assertEq(source.withdrawn(), 100);
        assertEq(asset.balanceOf(address(adapter)), 50);
        assertEq(adapter.pendingAllocation(1), 50);
    }

    function test_UnSyncedDeallocationRemainsReserved() public {
        asset.transfer(address(adapter), 60);
        delegator.requestDeallocate(address(adapter), 50);
        oracle.setNonce(2);
        assertEq(executor.availableBalance(address(adapter), address(asset)), 10);
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        executor.execute(address(adapter), steps, actions);
        assertEq(source.withdrawn(), 90);
        assertEq(asset.balanceOf(address(adapter)), 50);
        assertEq(adapter.deallocatable(), 50);
        assertEq(executor.availableBalance(address(adapter), address(asset)), 0);
    }

    function test_ReserveDeficitIsIncludedInWithdrawal() public {
        delegator.requestDeallocate(address(adapter), 150);
        oracle.setNonce(2);
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        executor.execute(address(adapter), steps, actions);
        assertEq(source.withdrawn(), 250);
        assertEq(asset.balanceOf(address(adapter)), 150);
    }

    function test_OtherTokenBalanceHasNoVaultAssetReserve() public {
        asset.transfer(address(vault), 100);
        delegator.allocate(address(adapter), 100);
        rwa.transfer(address(adapter), 45);
        assertEq(executor.availableBalance(address(adapter), address(rwa)), 45);
    }

    function test_AmountWordMustBeCompletelyWildcard() public {
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        steps[0].action.dataMask[67] = 0x01;
        _publish(steps, actions);
        vm.expectRevert(IExecutor.InvalidAmountOffset.selector);
        executor.execute(address(adapter), steps, actions);
    }

    function testFuzz_AmountOffsetBounds(uint256 offset) public {
        vm.assume(offset < 4 || offset > 36);
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        steps[0].amountOffset = offset;
        _publish(steps, actions);
        vm.expectRevert(IExecutor.InvalidAmountOffset.selector);
        executor.execute(address(adapter), steps, actions);
    }

    function test_LiquidityQueryMustReturnSingleWord() public {
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        steps[0].liquidityData = abi.encodeCall(source.malformedQuery, ());
        _publish(steps, actions);
        vm.expectRevert(IExecutor.InvalidLiquidityResult.selector);
        executor.execute(address(adapter), steps, actions);
    }

    function test_LiquidityQueryCannotWriteState() public {
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        steps[0].liquidityData = abi.encodeCall(source.mutatingQuery, ());
        _publish(steps, actions);
        vm.expectRevert();
        executor.execute(address(adapter), steps, actions);
        assertEq(source.calls(), 0);
    }

    function test_LiquidityQueryRevertBubbles() public {
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        steps[0].liquidityData = abi.encodeCall(source.failQuery, ());
        _publish(steps, actions);
        vm.expectRevert(ExecutorLiquiditySource.QueryFailed.selector);
        executor.execute(address(adapter), steps, actions);
    }

    function test_ReentrantExecutorCallRevertsAtomically() public {
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        source.setCallback(address(executor), abi.encodeCall(executor.execute, (address(adapter), steps, actions)));
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        executor.execute(address(adapter), steps, actions);
        assertEq(source.calls(), 0);
    }

    function test_FinalOperationMustBeSupportedAndBound() public {
        (, IMerkleAdapter.Action[] memory actions) = _plan(100);
        vm.expectRevert(IExecutor.InvalidOperation.selector);
        executor.getRequiredLiquidity(address(adapter), actions[0]);
        vm.expectRevert(IExecutor.InvalidAdapter.selector);
        executor.getRequiredLiquidity(stranger, actions[1]);
    }

    function test_UnknownSelectorWithOperationLengthRejected() public {
        (, IMerkleAdapter.Action[] memory actions) = _plan(100);
        actions[1].data[0] ^= 0xff;
        vm.expectRevert(IExecutor.InvalidOperation.selector);
        executor.getRequiredLiquidity(address(adapter), actions[1]);
    }

    function test_ThreeFRequestMustUseVaultFundingAsset() public {
        (ThreeFAction actionContract,) = _newThreeF(100);
        ThreeFActionRequestMock wrongAssetRequest = new ThreeFActionRequestMock(address(rwa), "request-2");
        wrongAssetRequest.authorizeMinting(address(actionContract), 100, 10);
        (, IMerkleAdapter.Action[] memory actions) = _threeFPlan(actionContract, wrongAssetRequest, 200);
        vm.expectRevert(IExecutor.InvalidOperation.selector);
        executor.getRequiredLiquidity(address(adapter), actions[1]);
    }

    function test_ZeroFundingOperationRejected() public {
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(0);
        _publish(steps, actions);
        vm.expectRevert(IExecutor.InvalidOperation.selector);
        executor.execute(address(adapter), steps, actions);
    }

    function test_EmptyFinalBatchRejected() public {
        vm.expectRevert(IExecutor.InvalidOperation.selector);
        executor.execute(address(adapter), new IExecutor.LiquidityStep[](0), new IMerkleAdapter.Action[](0));
    }

    function test_ThreeFUsesLivePrincipalRatherThanMaximum() public {
        (ThreeFAction actionContract, ThreeFActionRequestMock request) = _newThreeF(100);
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) =
            _threeFPlan(actionContract, request, 200);
        _publish(steps, actions);
        executor.execute(address(adapter), steps, actions);
        assertEq(source.withdrawn(), 100);
        assertEq(asset.balanceOf(address(request)), 100);
        assertEq(actionContract.pendingAssets(address(request)), 100);
        assertEq(asset.allowance(address(actionContract), address(request)), 0);
        (uint128 principal, uint128 yieldAmount) = request.mintAuthorization(address(actionContract));
        assertEq(principal, 0);
        assertEq(yieldAmount, 0);
    }

    function test_ThreeFAuthorizationChangeRollsBackLiquidity() public {
        (ThreeFAction actionContract, ThreeFActionRequestMock request) = _newThreeF(100);
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) =
            _threeFPlan(actionContract, request, 200);
        source.setCallback(
            address(request),
            abi.encodeCall(request.authorizeMinting, (address(actionContract), uint128(60), uint128(10)))
        );
        _publish(steps, actions);
        vm.expectRevert(IExecutor.OperationChanged.selector);
        executor.execute(address(adapter), steps, actions);
        assertEq(source.calls(), 0);
        (uint128 principal,) = request.mintAuthorization(address(actionContract));
        assertEq(principal, 100);
    }

    function test_ThreeFBoundsCheckedBeforeWithdrawing() public {
        (ThreeFAction actionContract, ThreeFActionRequestMock request) = _newThreeF(100);
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) =
            _threeFPlan(actionContract, request, 99);
        _publish(steps, actions);
        vm.expectCall(address(source), abi.encodeCall(source.withdraw, (address(adapter), 100)), uint64(0));
        vm.expectRevert(IExecutor.InvalidOperation.selector);
        executor.execute(address(adapter), steps, actions);
    }

    function test_WithdrawalThenHealthCheckedBorrowFundsLiquidLane() public {
        (BorrowAction borrowCapability, BorrowActionPoolMock pool) = _newBorrow(2e18);
        (, IMerkleAdapter.Action[] memory actions) = _plan(100);
        source.setLiquidity(30);
        IExecutor.LiquidityStep[] memory steps = new IExecutor.LiquidityStep[](2);
        steps[0] = _step(source);
        steps[1] = _borrowStep(borrowCapability, pool);
        _publish(steps, actions);
        executor.execute(address(adapter), steps, actions);
        assertEq(source.withdrawn(), 30);
        assertEq(pool.debt(address(adapter)), 70);
        assertEq(borrowCapability.getHealthFactor(), uint256(200e18) / 70);
        assertEq(asset.balanceOf(address(borrowCapability)), 0);
        assertEq(asset.balanceOf(recipient), 100);
    }

    function test_HealthFailureRollsBackEarlierWithdrawalAndDebt() public {
        (BorrowAction borrowCapability, BorrowActionPoolMock pool) = _newBorrow(3e18);
        (, IMerkleAdapter.Action[] memory actions) = _plan(100);
        source.setLiquidity(30);
        IExecutor.LiquidityStep[] memory steps = new IExecutor.LiquidityStep[](2);
        steps[0] = _step(source);
        steps[1] = _borrowStep(borrowCapability, pool);
        _publish(steps, actions);
        vm.expectRevert(abi.encodeWithSelector(IBorrowAction.HealthFactorTooLow.selector));
        executor.execute(address(adapter), steps, actions);
        assertEq(source.withdrawn(), 0);
        assertEq(pool.debt(address(adapter)), 0);
        assertEq(asset.balanceOf(recipient), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(address(borrowCapability)), 0);
    }

    function _oracleRefresh() internal view returns (IMerkleAdapter.Action[] memory actions) {
        actions = new IMerkleAdapter.Action[](2);
        actions[0] = _action(address(lane), abi.encodeCall(ILiquidLaneAction.removeTokenToRedeem, (address(rwa))));
        actions[1] = _action(address(lane), abi.encodeCall(ILiquidLaneAction.addTokenToRedeem, (address(rwa))));
    }

    function _newBorrow(uint256 minimum) internal returns (BorrowAction actionContract, BorrowActionPoolMock pool) {
        pool = new BorrowActionPoolMock(address(asset));
        pool.setCollateral(address(adapter), 200);
        asset.transfer(address(pool), 1000);
        MigratablesFactory factory = new MigratablesFactory(address(this));
        factory.whitelist(address(new BorrowAction(address(factory))));
        IBorrowAction.InitParams memory params = IBorrowAction.InitParams({
            adapter: address(adapter),
            borrowTarget: address(pool),
            borrowSelector: pool.borrow.selector,
            borrowAsset: address(asset),
            healthFactorTarget: address(pool),
            healthFactorData: abi.encodeCall(pool.getUserAccountData, (address(adapter))),
            healthFactorOffset: 160,
            minHealthFactor: minimum
        });
        actionContract = BorrowAction(factory.create(1, address(this), abi.encode(params)));
        vm.prank(address(adapter));
        pool.approveDelegation(address(actionContract), type(uint256).max);
    }

    function _borrowStep(BorrowAction actionContract, BorrowActionPoolMock pool)
        internal
        view
        returns (IExecutor.LiquidityStep memory step)
    {
        step.liquidityTarget = address(asset);
        step.liquidityData = abi.encodeCall(IERC20.balanceOf, (address(pool)));
        bytes memory borrowData = abi.encodeCall(pool.borrow, (address(asset), 0, 2, 0, address(adapter)));
        step.action = _action(address(actionContract), abi.encodeCall(actionContract.borrow, (borrowData)));
        // Selector + bytes offset + bytes length + nested selector + nested asset argument.
        step.amountOffset = 104;
        for (uint256 i = 104; i < 136; ++i) {
            step.action.dataMask[i] = 0;
        }
    }

    function testFuzz_OnlyMissingAmountWithdrawn(uint256 idle, uint256 needed) public {
        needed = bound(needed, 1, 1_000_000);
        idle = bound(idle, 0, needed * 2);
        asset.transfer(address(adapter), idle);
        (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(needed);
        _publish(steps, actions);
        executor.execute(address(adapter), steps, actions);
        assertEq(source.withdrawn(), idle < needed ? needed - idle : 0);
        assertEq(asset.balanceOf(address(adapter)), idle > needed ? idle - needed : 0);
    }

    function _newThreeF(uint128 principal)
        internal
        returns (ThreeFAction actionContract, ThreeFActionRequestMock request)
    {
        ThreeFActionWhitelistMock whitelist = new ThreeFActionWhitelistMock();
        ThreeFActionFacilityMock facility = new ThreeFActionFacilityMock();
        MigratablesFactory factory = new MigratablesFactory(address(this));
        factory.whitelist(address(new ThreeFAction(address(factory), address(whitelist), address(facility))));
        actionContract = ThreeFAction(factory.create(1, address(this), abi.encode(address(adapter))));
        request = new ThreeFActionRequestMock(address(asset), "request-1");
        whitelist.set(address(request), IThreeFWhitelist.WhitelistStatus.Whitelisted);
        address collateral = address(new ThreeFActionCollateralMock(address(rwa)));
        facility.setIntent(1, address(request), address(new ThreeFActionPositionManagerMock(collateral)), true);
        vm.prank(address(adapter));
        actionContract.setMaxAssetsPerDuration(address(rwa), type(uint256).max, 1 days);
        request.authorizeMinting(address(actionContract), principal, 10);
    }

    function _threeFPlan(ThreeFAction actionContract, ThreeFActionRequestMock request, uint128 maxPrincipal)
        internal
        view
        returns (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions)
    {
        steps = new IExecutor.LiquidityStep[](1);
        steps[0] = _step(source);
        actions = new IMerkleAdapter.Action[](2);
        actions[0] = _action(address(asset), abi.encodeCall(IERC20.approve, (address(actionContract), 100)));
        actions[1] = _action(
            address(actionContract),
            abi.encodeCall(IThreeFAction.mintRequest, (address(request), maxPrincipal, uint128(1), block.timestamp))
        );
    }

    function _plan(uint256 amount)
        internal
        view
        returns (IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions)
    {
        steps = new IExecutor.LiquidityStep[](1);
        steps[0] = _step(source);
        actions = new IMerkleAdapter.Action[](2);
        actions[0] = _action(address(asset), abi.encodeCall(IERC20.approve, (address(lane), amount)));
        actions[1] = _action(
            address(lane),
            abi.encodeCall(ILiquidLaneAction.swap, (ILiquidLaneAction.Swap(recipient, address(rwa), amount, amount)))
        );
    }

    function _step(ExecutorLiquiditySource target) internal view returns (IExecutor.LiquidityStep memory step) {
        step.liquidityTarget = address(target);
        step.liquidityData = abi.encodeCall(target.getLiquidity, ());
        step.action = _action(address(target), abi.encodeCall(target.withdraw, (address(adapter), uint256(0))));
        step.amountOffset = 36;
        for (uint256 i = 36; i < 68; ++i) {
            step.action.dataMask[i] = 0;
        }
    }

    function _action(address target, bytes memory data) internal pure returns (IMerkleAdapter.Action memory action) {
        bytes memory mask = new bytes(data.length);
        for (uint256 i; i < mask.length; ++i) {
            mask[i] = 0xff;
        }
        return IMerkleAdapter.Action(target, 0, data, mask, new bytes32[](0));
    }

    function _publish(IExecutor.LiquidityStep[] memory steps, IMerkleAdapter.Action[] memory actions) internal {
        uint256 count = steps.length + actions.length;
        uint256 width = 1;
        uint256 depth;
        while (width < count) {
            width *= 2;
            ++depth;
        }
        bytes32[] memory tree = new bytes32[](width * 2);
        for (uint256 i; i < count; ++i) {
            IMerkleAdapter.Action memory action = i < steps.length ? steps[i].action : actions[i - steps.length];
            bytes32 leaf = _leaf(action);
            tree[width + i] = leaf;
            adapter.grantRole(leaf, address(this));
            adapter.grantRole(leaf, address(executor));
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
            if (i < steps.length) steps[i].action.proof = proof;
            else actions[i - steps.length].proof = proof;
        }
        roots.setRoot(address(adapter), tree[1]);
        adapter.acceptRoot(tree[1]);
    }

    function _leaf(IMerkleAdapter.Action memory action) internal pure returns (bytes32) {
        bytes memory masked = new bytes(action.data.length);
        for (uint256 i; i < masked.length; ++i) {
            masked[i] = action.data[i] & action.dataMask[i];
        }
        uint96 value = action.flagsAndValue & ANY_VALUE_FLAG == 0 ? action.flagsAndValue & ANY_VALUE : ANY_VALUE;
        return keccak256(
            bytes.concat(keccak256(abi.encode(action.target, value, keccak256(action.dataMask), keccak256(masked))))
        );
    }
}

contract ExecutorLiquiditySource {
    error QueryFailed();
    IERC20 public immutable asset;
    address public immutable adapter;
    uint256 public liquidity;
    uint256 public withdrawn;
    uint256 public calls;
    int256 public adjustment;
    address public callbackTarget;
    bytes public callbackData;

    constructor(IERC20 asset_, address adapter_) {
        asset = asset_;
        adapter = adapter_;
    }

    function setLiquidity(uint256 amount) external {
        liquidity = amount;
    }

    function setAdjustment(int256 amount) external {
        adjustment = amount;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function getLiquidity() external view returns (uint256) {
        return liquidity;
    }

    function failQuery() external pure returns (uint256) {
        revert QueryFailed();
    }

    function malformedQuery() external pure returns (uint256) {
        assembly ("memory-safe") { return(0, 1) }
    }

    function mutatingQuery() external returns (uint256) {
        ++calls;
        return liquidity;
    }

    function give(address receiver, uint256 amount) external {
        require(msg.sender == adapter);
        asset.transfer(receiver, amount);
    }

    function withdraw(address receiver, uint256 amount) external {
        require(msg.sender == adapter && receiver == adapter);
        require(amount <= liquidity);
        liquidity -= amount;
        withdrawn += amount;
        ++calls;
        uint256 sent = adjustment < 0 ? amount - uint256(-adjustment) : amount + uint256(adjustment);
        asset.transfer(receiver, sent);
        if (callbackTarget != address(0)) {
            (bool ok, bytes memory result) = callbackTarget.call(callbackData);
            if (!ok) {
                assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
            }
        }
    }
}
