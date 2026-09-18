// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;
import {
    AaveHealthFactor
} from "../../../src/contracts/merkle-adapter/capabilities/borrow-capability/AaveHealthFactor.sol";
import {ActionOracleMock} from "./LiquidLaneConnector.t.sol";
import {AdapterFactory} from "../../../src/contracts/AdapterFactory.sol";
import {BorrowCapabilityPoolMock} from "./mocks/BorrowCapabilityMocks.sol";
import {BorrowCapability} from "../../../src/contracts/merkle-adapter/capabilities/BorrowCapability.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {CapabilityManifestTestHelper} from "./CapabilityTestBase.sol";
import {ExecutorTestHelper} from "./ExecutorTestHelper.sol";
import {Executor} from "../../../src/contracts/periphery/Executor.sol";
import {ImmutableFactory} from "src/contracts/common/ImmutableFactory.sol";
import {LiquidLaneConnector} from "../../../src/contracts/merkle-adapter/LiquidLaneConnector.sol";
import {LiquidLaneExecutor} from "src/contracts/periphery/LiquidLaneExecutor.sol";
import {
    MerkleAdapterVaultRegistry,
    MerkleAdapterVaultMock,
    MerkleAdapterDelegatorMock,
    MerkleAdapterOracleMock
} from "../MerkleAdapter.t.sol";
import {MerkleAdapter} from "../../../src/contracts/MerkleAdapter.sol";
import {OracleRegistry} from "../../../src/contracts/merkle-adapter/OracleRegistry.sol";
import {RootRegistry} from "../../../src/contracts/merkle-adapter/RootRegistry.sol";
import {
    ThreeFCapabilityRequestMock,
    ThreeFCapabilityWhitelistMock,
    ThreeFCapabilityFacilityMock,
    ThreeFCapabilityPositionManagerMock,
    ThreeFCapabilityCollateralMock
} from "../../mocks/ThreeFCapabilityPushMocks.sol";
import {ThreeFCapability} from "../../../src/contracts/merkle-adapter/capabilities/ThreeFCapability.sol";
import {ThreeFExecutor} from "src/contracts/periphery/ThreeFExecutor.sol";
import {Token} from "../../mocks/Token.sol";

import {IAssetRateLimits} from "../../../src/interfaces/merkle-adapter/IAssetRateLimits.sol";
import {IBorrowCapability} from "../../../src/interfaces/merkle-adapter/capabilities/IBorrowCapability.sol";
import {IExecutor} from "../../../src/interfaces/periphery/IExecutor.sol";
import {IImmutableFactory} from "src/interfaces/common/IImmutableFactory.sol";
import {ILiquidLaneConnector} from "../../../src/interfaces/merkle-adapter/ILiquidLaneConnector.sol";
import {IMerkleAdapter} from "../../../src/interfaces/IMerkleAdapter.sol";
import {IThreeFCapability} from "../../../src/interfaces/merkle-adapter/capabilities/IThreeFCapability.sol";
import {IThreeFWhitelist} from "../../../src/interfaces/3f-adapter/IThreeFWhitelist.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

import {BorrowTestCall} from "test/adapters/merkle-adapter/mocks/BorrowCapabilityMocks.sol";

contract ExecutorTest is Test, CapabilityManifestTestHelper, ExecutorTestHelper {
    struct LiquidityPlan {
        address liquidityTarget;
        bytes liquidityData;
        IMerkleAdapter.Action action;
    }

    address internal executorFactory;
    address internal aaveHealthFactor;
    Executor internal executor;
    MerkleAdapter internal adapter;
    MerkleAdapterOracleMock internal oracle;
    MerkleAdapterVaultMock internal vault;
    MerkleAdapterDelegatorMock internal delegator;
    RootRegistry internal roots;
    Token internal asset;
    Token internal rwa;
    LiquidLaneConnector internal lane;
    OracleRegistry internal registry;
    ExecutorLiquiditySource internal source;
    address internal recipient = makeAddr("recipient");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        asset = new ExecutorApprovalToken();
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
                    address(new CapabilitiesRegistry(address(this)))
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
        lanes.whitelist(address(new LiquidLaneConnector(address(lanes), address(registry))));
        lane = LiquidLaneConnector(
            lanes.create(1, address(this), abi.encode(address(adapter), address(asset), new address[](0)))
        );
        executorFactory = address(new ImmutableFactory(type(LiquidLaneExecutor).creationCode));
        executor = Executor(
            IImmutableFactory(executorFactory).create(abi.encode(address(this), address(adapter), address(lane)))
        );
        executor.setCaller(address(this));
        LiquidLaneExecutor(address(executor)).setSigner(address(this));
        address priceOracle = prices.create(1, address(this), abi.encode(address(asset), address(lane)));
        registry.setOracle(address(lane), address(rwa), priceOracle);
        IMerkleAdapter.Action[] memory configuration = new IMerkleAdapter.Action[](2);
        configuration[0] = _action(address(lane), abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (address(rwa))));
        configuration[1] = _action(
            address(lane),
            abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (address(rwa), type(uint256).max, 1 days))
        );
        _publish(new LiquidityPlan[](0), configuration);
        adapter.manage(configuration);
        rwa.transfer(address(lane), 1_000_000);
        source = new ExecutorLiquiditySource(asset, address(adapter));
        asset.transfer(address(source), 1_000_000);
        source.setLiquidity(1_000_000);
    }

    function test_IdleFirstAndExactRemainingWithdrawal() public {
        asset.transfer(address(adapter), 40);
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        steps[0] = _step(source, 60);
        _publish(steps, actions);

        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));

        assertEq(source.withdrawn(), 60);
        assertEq(source.calls(), 1);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(recipient), 100);
        assertEq(rwa.balanceOf(address(adapter)), 100);
    }

    function test_ExecutesLiquidityActionWithFull96BitValue() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        steps[0].action.value = 1;
        _publish(steps, actions);
        steps[0].action.value = type(uint96).max;
        vm.deal(address(adapter), type(uint96).max);

        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));

        assertEq(address(source).balance, type(uint96).max);
        assertEq(address(adapter).balance, 0);
        assertEq(source.withdrawn(), 100);
        assertEq(asset.balanceOf(recipient), 100);
    }

    function test_OwnerCanConfigureCaller() public {
        vm.expectEmit(address(executor));
        emit IExecutor.SetCaller(stranger);
        executor.setCaller(stranger);
        assertEq(executor.caller(), stranger);
        assertEq(executor.owner(), address(this));
    }

    function test_OwnerConfiguresLiquidityQueriesAndLeaves() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        executor.setActions(_config(steps), _leaf(actions[0]), _leaf(actions[1]));

        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));

        assertEq(source.withdrawn(), 100);
        assertEq(asset.balanceOf(recipient), 100);
        assertEq(abi.encode(_storedActions()), abi.encode(_config(steps)));
    }

    function test_DefaultCallerDisablesExecutionUntilConfigured() public {
        executor = Executor(
            IImmutableFactory(executorFactory).create(abi.encode(address(this), address(adapter), address(lane)))
        );
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        assertEq(executor.caller(), address(0));
        vm.expectRevert(IExecutor.InvalidCaller.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));

        executor.setCaller(stranger);
        assertFalse(adapter.hasRole(_leaf(steps[0].action), stranger));
        vm.prank(stranger);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(asset.balanceOf(recipient), 100);
    }

    function testFuzz_OnlyOwnerMayChangeCallerOrActions(address account) public {
        vm.assume(account != address(this));
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        executor.setCaller(account);
        IExecutor.Action[] memory configured = _config(steps);
        configured[0].liquidityCalldata = abi.encodeCall(source.failQuery, ());
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        executor.setActions(configured, _leaf(actions[0]), _leaf(actions[1]));
        assertEq(executor.caller(), address(this));
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(asset.balanceOf(recipient), 100);
    }

    function test_RotatingCallerRevokesTheOwnerExecutionPermission() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        executor.setCaller(stranger);
        vm.expectRevert(IExecutor.InvalidCaller.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        vm.prank(stranger);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(asset.balanceOf(recipient), 100);

        executor.setCaller(address(this));
        vm.prank(stranger);
        vm.expectRevert(IExecutor.InvalidCaller.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
    }

    function test_ZeroCallerDisablesWithoutDeletingPlan() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        executor.setCaller(address(0));
        vm.expectRevert(IExecutor.InvalidCaller.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(abi.encode(_storedActions()), abi.encode(_config(steps)));
        executor.setCaller(stranger);
        vm.prank(stranger);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 100);
    }

    function test_TransferOwnershipChangesConfigurationAuthority() public {
        executor.transferOwnership(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        executor.setCaller(address(this));
        vm.prank(stranger);
        executor.setCaller(recipient);
        assertEq(executor.caller(), recipient);
    }

    function test_ActionsRoundTripAndReplacementRemovesOldLiquidity() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        vm.expectEmit(address(executor));
        emit IExecutor.SetActions(_config(steps), _leaf(actions[0]), _leaf(actions[1]));
        executor.setActions(_config(steps), _leaf(actions[0]), _leaf(actions[1]));
        assertEq(abi.encode(_storedActions()), abi.encode(_config(steps)));

        steps = new LiquidityPlan[](0);
        (, actions) = _plan(25);
        _publish(steps, actions);
        asset.transfer(address(adapter), 25);
        assertEq(abi.encode(_storedActions()), abi.encode(_config(steps)));
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.calls(), 0);
        assertEq(asset.balanceOf(recipient), 25);
    }

    function test_RepeatedExecutionDoesNotChangeConfiguredQueryOrLeaf() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        asset.transfer(address(adapter), 40);
        steps[0].action.data = abi.encodeCall(source.withdraw, (address(adapter), 60));
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 60);
        asset.transfer(address(adapter), 70);
        steps[0].action.data = abi.encodeCall(source.withdraw, (address(adapter), 30));
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 90);
        assertEq(asset.balanceOf(recipient), 200);
        assertEq(abi.encode(_storedActions()), abi.encode(_config(steps)));
    }

    function testFuzz_CallerCannotChangeConfiguredLeaf(uint8 field) public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        field = uint8(bound(field, 0, 3));
        if (field == 0) {
            steps[0].action.target = stranger;
        } else if (field == 1) {
            steps[0].action.dataMask[4] = 0xff;
        } else if (field == 2) {
            steps[0].action.data = abi.encodeCall(source.withdraw, (stranger, 100));
        } else {
            actions[1].data = abi.encodeCall(
                ILiquidLaneConnector.swap, (ILiquidLaneConnector.Swap(stranger, address(rwa), 100, 100))
            );
        }
        if (field < 3) vm.expectCall(address(source), abi.encodeCall(source.getLiquidity, ()), uint64(0));
        vm.expectRevert(IExecutor.InvalidAction.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 0);
        assertEq(asset.balanceOf(recipient), 0);
    }

    function testFuzz_CallerCannotChangeConfiguredValueClass(uint96 nonzeroValue, bool startsWithZero) public {
        nonzeroValue = uint96(bound(nonzeroValue, 1, type(uint96).max));
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        steps[0].action.value = startsWithZero ? 0 : nonzeroValue;
        _publish(steps, actions);
        steps[0].action.value = startsWithZero ? nonzeroValue : 0;
        vm.deal(address(adapter), nonzeroValue);

        vm.expectCall(address(source), abi.encodeCall(source.getLiquidity, ()), uint64(0));
        vm.expectRevert(IExecutor.InvalidAction.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));

        assertEq(source.calls(), 0);
        assertEq(asset.balanceOf(recipient), 0);
        assertEq(address(adapter).balance, nonzeroValue);
    }

    function test_ConfiguredLiquidityOrderCannotBeReversed() public {
        ExecutorLiquiditySource second = new ExecutorLiquiditySource(asset, address(adapter));
        asset.transfer(address(second), 100);
        second.setLiquidity(100);
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        steps = new LiquidityPlan[](2);
        steps[0] = _step(source, 100);
        steps[1] = _step(second, 100);
        _publish(steps, actions);
        IMerkleAdapter.Action[] memory calls = _calls(steps, actions);
        (calls[0], calls[1]) = (calls[1], calls[0]);
        vm.expectRevert(IExecutor.InvalidAction.selector);
        _execute(calls, new IMerkleAdapter.Action[](0));
        assertEq(source.calls(), 0);
        assertEq(second.calls(), 0);
    }

    function test_RemovedSourceCannotBeUsedWithOldMerklePermissions() public {
        ExecutorLiquiditySource second = new ExecutorLiquiditySource(asset, address(adapter));
        asset.transfer(address(second), 100);
        second.setLiquidity(100);
        (, IMerkleAdapter.Action[] memory actions) = _plan(100);
        LiquidityPlan[] memory steps = new LiquidityPlan[](2);
        steps[0] = _step(source, 100);
        steps[1] = _step(second, 100);
        _publish(steps, actions);
        LiquidityPlan[] memory replacement = new LiquidityPlan[](1);
        replacement[0] = steps[1];
        executor.setActions(_config(replacement), _leaf(actions[0]), _leaf(actions[1]));
        LiquidityPlan[] memory obsolete = new LiquidityPlan[](1);
        obsolete[0] = steps[0];
        vm.expectRevert(IExecutor.InvalidAction.selector);
        _execute(_calls(obsolete, actions), new IMerkleAdapter.Action[](0));

        _execute(_calls(replacement, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.calls(), 0);
        assertEq(second.withdrawn(), 100);
        assertEq(asset.balanceOf(recipient), 100);
    }

    function test_EarlierSourceMustBeFullyUsedBeforeMovingOn() public {
        ExecutorLiquiditySource second = new ExecutorLiquiditySource(asset, address(adapter));
        asset.transfer(address(second), 100);
        second.setLiquidity(100);
        source.setLiquidity(70);
        (, IMerkleAdapter.Action[] memory actions) = _plan(100);
        LiquidityPlan[] memory steps = new LiquidityPlan[](2);
        steps[0] = _step(source, 30);
        steps[1] = _step(second, 70);
        _publish(steps, actions);
        vm.expectCall(address(second), abi.encodeCall(second.getLiquidity, ()), uint64(0));
        vm.expectRevert(IExecutor.LiquidityMismatch.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(recipient), 0);
        assertEq(source.withdrawn(), 0);
    }

    function test_QueryCapacityCannotBeExceededEvenWhenMoreCanBeWithdrawn() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        steps[0].liquidityTarget = address(asset);
        steps[0].liquidityData = abi.encodeCall(IERC20.balanceOf, (stranger));
        asset.transfer(stranger, 30);
        _publish(steps, actions);
        vm.expectRevert(IExecutor.LiquidityMismatch.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 0);
        assertEq(asset.balanceOf(recipient), 0);
    }

    function testFuzz_SuppliedAmountsMustMatchTheExactShortfall(uint256 amount) public {
        amount = bound(amount, 0, 200);
        vm.assume(amount != 100);
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        steps[0].action.data = abi.encodeCall(source.withdraw, (address(adapter), amount));
        vm.expectRevert(IExecutor.LiquidityMismatch.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 0);
        assertEq(asset.balanceOf(recipient), 0);
    }

    function test_ExactSourceCapacityThenOnlyRemainingNeed() public {
        ExecutorLiquiditySource second = new ExecutorLiquiditySource(asset, address(adapter));
        asset.transfer(address(second), 100);
        second.setLiquidity(100);
        source.setLiquidity(70);
        (, IMerkleAdapter.Action[] memory actions) = _plan(100);
        LiquidityPlan[] memory steps = new LiquidityPlan[](2);
        steps[0] = _step(source, 70);
        steps[1] = _step(second, 30);
        _publish(steps, actions);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 70);
        assertEq(second.withdrawn(), 30);
        assertEq(asset.balanceOf(recipient), 100);
    }

    function test_ClearingActionsDisablesExecutionEvenWithIdleFunds() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        asset.transfer(address(adapter), 100);
        executor.setActions(new IExecutor.Action[](0), bytes32(0), bytes32(0));
        vm.expectRevert(IExecutor.InvalidActionsLength.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(_storedActions().length, 0);
        assertEq(asset.balanceOf(address(adapter)), 100);
    }

    function testFuzz_OwnerCallbackCannotReconfigureDuringExecution(bool changeCaller) public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        source.setCallback(
            address(executor),
            changeCaller
                ? abi.encodeCall(executor.setCaller, (stranger))
                : abi.encodeCall(executor.setActions, (new IExecutor.Action[](0), bytes32(0), bytes32(0)))
        );
        executor.transferOwnership(address(source));
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.calls(), 0);
        assertEq(executor.caller(), address(this));
        assertEq(abi.encode(_storedActions()), abi.encode(_config(steps)));
    }

    function test_CurrentMerkleRootStillRequiredForConfiguredLeaf() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        roots.setRoot(address(adapter), bytes32(uint256(1)));
        adapter.acceptRoot(bytes32(uint256(1)));
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.calls(), 0);
    }

    function test_MalformedLiquidityMaskRevertsBeforeQuerying() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        steps[0].action.dataMask = new bytes(0);
        vm.expectRevert(IMerkleAdapter.InvalidDataMaskLength.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.calls(), 0);
    }

    function test_OracleRefreshInSingleMerkleBatchRequiresBothLeafRoles() public {
        address savedOracle = lane.oracles(address(rwa));
        address replacement = address(new ActionOracleMock(address(0), 2e18));
        registry.setOracle(address(lane), address(rwa), replacement);
        IMerkleAdapter.Action[] memory actions = _oracleRefresh();
        _publish(new LiquidityPlan[](0), actions);
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
        _publish(new LiquidityPlan[](0), actions);

        vm.expectRevert(ILiquidLaneConnector.InvalidOracle.selector);
        adapter.manage(actions);

        assertEq(lane.oracles(address(rwa)), savedOracle);
        assertEq(lane.getTokensToRedeemLength(), 1);
        assertEq(lane.tokensToRedeem(0), address(rwa));
        assertEq(lane.remainingAssets(address(rwa)), remaining);
        assertEq(lane.getAmountOut(address(rwa), 100), 100);
    }

    function test_CuratorConfigurationLeavesRequireTheirOwnRoles() public {
        (ThreeFCapability threeF,) = _newThreeF(100);
        IMerkleAdapter.Action[] memory configuration = new IMerkleAdapter.Action[](3);
        configuration[0] = _action(
            address(lane), abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (address(rwa), 100, 1 days))
        );
        configuration[1] = _action(
            address(threeF), abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (address(rwa), 200, 2 days))
        );
        configuration[2] =
            _action(address(threeF), abi.encodeCall(IThreeFCapability.setMinYieldPerRequest, (address(rwa), 10_000)));
        _publish(new LiquidityPlan[](0), configuration);
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
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(recipient), 0);
        assertEq(asset.allowance(address(adapter), address(lane)), 0);
        assertEq(lane.remainingAssets(address(rwa)), 99);
    }

    function test_ThreeFBudgetFailureRollsBackExecutorLiquidity() public {
        (ThreeFCapability threeF, ThreeFCapabilityRequestMock request) = _newThreeF(100);
        vm.prank(address(adapter));
        threeF.setMaxAssetsPerDuration(address(rwa), 99, 1 days);
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _threeFPlan(threeF, request, 100);
        _publish(steps, actions);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(address(request)), 0);
        assertEq(asset.allowance(address(adapter), address(threeF)), 0);
        assertEq(threeF.requestsLength(), 0);
        assertEq(threeF.remainingAssets(address(rwa)), 99);
    }

    function test_InsufficientLiquidityRollsBackWithdrawalsAndApproval() public {
        source.setLiquidity(30);
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        steps[0] = _step(source, 30);
        _publish(steps, actions);
        vm.expectRevert(IExecutor.InsufficientLiquidity.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.calls(), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.allowance(address(adapter), address(lane)), 0);
    }

    function test_ReceivedAmountMismatchRevertsEverything() public {
        source.setAdjustment(-1);
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        vm.expectRevert(abi.encodeWithSelector(IExecutor.LiquidityMismatch.selector));
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.calls(), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(recipient), 0);
    }

    function test_LeafRolesDoNotLetAnUnselectedCallerExecute() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        adapter.grantRole(_leaf(steps[0].action), stranger);
        for (uint256 i; i < actions.length; ++i) {
            adapter.grantRole(_leaf(actions[i]), stranger);
        }
        vm.prank(stranger);
        vm.expectRevert(IExecutor.InvalidCaller.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.calls(), 0);
    }

    function test_ExecutorNeedsItsOwnLeafRoles() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        bytes32 leaf = _leaf(actions[1]);
        adapter.revokeRole(leaf, address(executor));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(executor), leaf)
        );
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.calls(), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(recipient), 0);
    }

    function test_SkippedLiquidityDoesNotRequireExecutorRole() public {
        asset.transfer(address(adapter), 100);
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        adapter.revokeRole(_leaf(steps[0].action), address(executor));

        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));

        assertEq(source.calls(), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(recipient), 100);
    }

    function test_ConfiguredCallerDoesNotNeedAnyLeafRoles() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        adapter.revokeRole(_leaf(steps[0].action), address(this));
        for (uint256 i; i < actions.length; ++i) {
            adapter.revokeRole(_leaf(actions[i]), address(this));
        }
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 100);
        assertEq(asset.balanceOf(recipient), 100);
    }

    function test_InvalidSuppliedProofRollsBackEarlierWithdrawal() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        actions[1].proof[0] = bytes32(uint256(123));
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.calls(), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(recipient), 0);
    }

    function test_SkipsLiquidityQueriesWhenIdleSuffices() public {
        asset.transfer(address(adapter), 110);
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        steps[0].liquidityData = abi.encodeCall(source.failQuery, ());
        _publish(steps, actions);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.calls(), 0);
        assertEq(asset.balanceOf(address(adapter)), 10);
    }

    function test_EmptySourcesUseExistingIdle() public {
        asset.transfer(address(adapter), 100);
        (, IMerkleAdapter.Action[] memory actions) = _plan(100);
        LiquidityPlan[] memory steps = new LiquidityPlan[](0);
        _publish(steps, actions);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(asset.balanceOf(recipient), 100);
    }

    function test_QueriesEachSourceJustBeforeUsingIt() public {
        ExecutorLiquiditySource second = new ExecutorLiquiditySource(asset, address(adapter));
        asset.transfer(address(second), 1000);
        second.setLiquidity(1);
        source.setLiquidity(30);
        source.setCallback(address(second), abi.encodeCall(second.setLiquidity, (70)));
        (, IMerkleAdapter.Action[] memory actions) = _plan(100);
        LiquidityPlan[] memory steps = new LiquidityPlan[](2);
        steps[0] = _step(source, 30);
        steps[1] = _step(second, 70);
        _publish(steps, actions);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 30);
        assertEq(second.withdrawn(), 70);
    }

    function test_ZeroCapacityIsSkipped() public {
        source.setLiquidity(0);
        ExecutorLiquiditySource second = new ExecutorLiquiditySource(asset, address(adapter));
        asset.transfer(address(second), 1000);
        second.setLiquidity(1000);
        (, IMerkleAdapter.Action[] memory actions) = _plan(100);
        LiquidityPlan[] memory steps = new LiquidityPlan[](2);
        steps[0] = _step(source, 100);
        steps[1] = _step(second, 100);
        _publish(steps, actions);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.calls(), 0);
        assertEq(second.withdrawn(), 100);
    }

    function test_ExcessReceivedAmountAlsoReverts() public {
        source.setAdjustment(1);
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        vm.expectRevert(abi.encodeWithSelector(IExecutor.LiquidityMismatch.selector));
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
    }

    function test_DecreasingBalanceIsNotLiquidity() public {
        asset.transfer(address(adapter), 100);
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(200);
        steps[0].action = _action(address(asset), abi.encodeCall(IERC20.transfer, (address(source), 100)));
        for (uint256 i = 36; i < 68; ++i) {
            steps[0].action.dataMask[i] = 0xff;
        }
        _publish(steps, actions);
        vm.expectRevert(abi.encodeWithSelector(IExecutor.LiquidityMismatch.selector));
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(asset.balanceOf(address(adapter)), 100);
    }

    function test_PendingAllocationRemainsReserved() public {
        asset.transfer(address(vault), 50);
        delegator.allocate(address(adapter), 50);
        assertEq(adapter.reservedAssets(), 50);
        assertEq(executor.availableBalance(address(asset)), 0);
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 100);
        assertEq(asset.balanceOf(address(adapter)), 50);
        assertEq(adapter.pendingAllocation(1), 50);
    }

    function test_UnSyncedDeallocationRemainsReserved() public {
        asset.transfer(address(adapter), 60);
        delegator.requestDeallocate(address(adapter), 50);
        oracle.setNonce(2);
        assertEq(executor.availableBalance(address(asset)), 10);
        assertEq(adapter.reservedAssets(), 50);
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        steps[0] = _step(source, 90);
        _publish(steps, actions);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 90);
        assertEq(asset.balanceOf(address(adapter)), 50);
        assertEq(adapter.deallocatable(), 50);
        assertEq(adapter.reservedAssets(), 50);
        assertEq(executor.availableBalance(address(asset)), 0);
    }

    function test_ReserveDeficitIsIncludedInWithdrawal() public {
        delegator.requestDeallocate(address(adapter), 150);
        oracle.setNonce(2);
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        steps[0] = _step(source, 250);
        _publish(steps, actions);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 250);
        assertEq(asset.balanceOf(address(adapter)), 150);
    }

    function test_OtherTokenBalanceHasNoVaultAssetReserve() public {
        asset.transfer(address(vault), 100);
        delegator.allocate(address(adapter), 100);
        rwa.transfer(address(adapter), 45);
        assertEq(executor.availableBalance(address(rwa)), 45);
    }

    function test_ExactAmountLeafExecutesWithoutAWildcard() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        steps[0].action = _action(address(source), abi.encodeCall(source.withdraw, (address(adapter), 100)));
        _publish(steps, actions);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 100);
        assertEq(asset.balanceOf(recipient), 100);
    }

    function test_LiquidityQueryMustReturnSingleWord() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        steps[0].liquidityData = abi.encodeCall(source.malformedQuery, ());
        _publish(steps, actions);
        vm.expectRevert(IExecutor.InvalidLiquidityResult.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
    }

    function test_LiquidityQueryCannotWriteState() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        steps[0].liquidityData = abi.encodeCall(source.mutatingQuery, ());
        _publish(steps, actions);
        vm.expectRevert();
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.calls(), 0);
    }

    function test_LiquidityQueryRevertBubbles() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        steps[0].liquidityData = abi.encodeCall(source.failQuery, ());
        _publish(steps, actions);
        vm.expectRevert(ExecutorLiquiditySource.QueryFailed.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
    }

    function test_ReentrantExecutorCallRevertsAtomically() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        source.setCallback(
            address(executor),
            _liquidLaneCall(address(executor), _calls(steps, actions), new IMerkleAdapter.Action[](0), 0)
        );
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.calls(), 0);
    }

    function test_ThreeFUsesExactPrincipal() public {
        (ThreeFCapability actionContract, ThreeFCapabilityRequestMock request) = _newThreeF(100);
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) =
            _threeFPlan(actionContract, request, 100);
        _publish(steps, actions);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 100);
        assertEq(asset.balanceOf(address(request)), 100);
        assertEq(actionContract.pendingAssets(address(request)), 100);
        assertEq(asset.allowance(address(actionContract), address(request)), 0);
        (uint128 principal, uint128 yieldAmount) = request.mintAuthorization(address(actionContract));
        assertEq(principal, 0);
        assertEq(yieldAmount, 0);
    }

    function test_ThreeFAuthorizationChangeRollsBackLiquidity() public {
        (ThreeFCapability actionContract, ThreeFCapabilityRequestMock request) = _newThreeF(100);
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) =
            _threeFPlan(actionContract, request, 100);
        source.setCallback(
            address(request),
            abi.encodeCall(request.authorizeMinting, (address(actionContract), uint128(60), uint128(10)))
        );
        _publish(steps, actions);
        vm.expectRevert(IExecutor.OperationBalanceMismatch.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.calls(), 0);
        (uint128 principal,) = request.mintAuthorization(address(actionContract));
        assertEq(principal, 100);
    }

    function test_ThreeFPrincipalAboveExactAmountRollsBackFunding() public {
        (ThreeFCapability actionContract, ThreeFCapabilityRequestMock request) = _newThreeF(100);
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) =
            _threeFPlan(actionContract, request, 99);
        _publish(steps, actions);
        vm.expectRevert(IThreeFCapability.SlippageExceeded.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
    }

    function test_WithdrawalThenHealthCheckedBorrowFundsLiquidLane() public {
        (BorrowCapability borrowCapability, BorrowCapabilityPoolMock pool) = _newBorrow(2e18);
        (, IMerkleAdapter.Action[] memory actions) = _plan(100);
        source.setLiquidity(30);
        LiquidityPlan[] memory steps = new LiquidityPlan[](2);
        steps[0] = _step(source, 30);
        steps[1] = _borrowStep(borrowCapability, pool);
        _publish(steps, actions);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 30);
        assertEq(pool.debt(address(adapter)), 70);
        assertEq(
            borrowCapability.getHealthFactor(_borrowHealthFactor(pool).target, _borrowHealthFactor(pool).data),
            uint256(200e18) / 70
        );
        assertEq(asset.balanceOf(address(borrowCapability)), 0);
        assertEq(asset.balanceOf(recipient), 100);
    }

    function test_HealthFailureRollsBackEarlierWithdrawalAndDebt() public {
        (BorrowCapability borrowCapability, BorrowCapabilityPoolMock pool) = _newBorrow(3e18);
        (, IMerkleAdapter.Action[] memory actions) = _plan(100);
        source.setLiquidity(30);
        LiquidityPlan[] memory steps = new LiquidityPlan[](2);
        steps[0] = _step(source, 30);
        steps[1] = _borrowStep(borrowCapability, pool);
        _publish(steps, actions);
        vm.expectRevert(abi.encodeWithSelector(IBorrowCapability.HealthFactorTooLow.selector));
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 0);
        assertEq(pool.debt(address(adapter)), 0);
        assertEq(asset.balanceOf(recipient), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(address(borrowCapability)), 0);
    }

    function test_ApprovalBelongsToAdapterAndMatchesExactSpend() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(ExecutorApprovalToken(address(asset)).lastApprovalOwner(), address(adapter));
        assertEq(ExecutorApprovalToken(address(asset)).allowanceBeforeSpend(), 100);
        assertEq(asset.allowance(address(executor), address(lane)), 0);
        assertEq(asset.balanceOf(address(executor)), 0);
        assertEq(asset.allowance(address(adapter), address(lane)), 0);
    }

    function test_ApprovalResetsExistingAllowanceForUSDTLikeToken() public {
        vm.prank(address(adapter));
        asset.approve(address(lane), 55);
        ExecutorApprovalToken(address(asset)).setApprovalBehavior(0, true);
        uint256 approvalsBefore = ExecutorApprovalToken(address(asset)).approvalCalls();
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(ExecutorApprovalToken(address(asset)).approvalCalls(), approvalsBefore + 2);
        assertEq(ExecutorApprovalToken(address(asset)).allowanceBeforeSpend(), 100);
        assertEq(asset.balanceOf(recipient), 100);
    }

    function test_ApprovalWithNoReturnDataSucceeds() public {
        ExecutorApprovalToken(address(asset)).setApprovalBehavior(1, false);
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(asset.balanceOf(recipient), 100);
    }

    function test_FalseApprovalRollsBackLiquidityAndAllowance() public {
        ExecutorApprovalToken(address(asset)).setApprovalBehavior(2, false);
        uint256 approvalsBefore = ExecutorApprovalToken(address(asset)).approvalCalls();
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        vm.expectRevert(IExecutor.ApprovalFailed.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 0);
        assertEq(asset.allowance(address(adapter), address(lane)), 0);
        assertEq(ExecutorApprovalToken(address(asset)).approvalCalls(), approvalsBefore);
    }

    function test_MalformedApprovalRollsBackLiquidityAndAllowance() public {
        ExecutorApprovalToken(address(asset)).setApprovalBehavior(3, false);
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        vm.expectRevert();
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 0);
        assertEq(asset.allowance(address(adapter), address(lane)), 0);
    }

    function test_ApprovalLeafCannotPinAnotherSpender() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        actions[0].data = abi.encodeCall(IERC20.approve, (stranger, 100));
        _publish(steps, actions);
        vm.expectRevert(IExecutor.InvalidAction.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 0);
        assertEq(asset.allowance(address(adapter), stranger), 0);
    }

    function test_ApprovalMaskCannotBeChanged() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        actions[0].dataMask[4] = 0xff;
        vm.expectRevert(IExecutor.InvalidAction.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 0);
    }

    function test_ApprovalProofCannotBeChanged() public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        actions[0].proof[0] ^= bytes32(uint256(1));
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), 0);
        assertEq(asset.allowance(address(adapter), address(lane)), 0);
    }

    function testFuzz_CallerCannotOmitOrAppendLiquiditySources(bool append) public {
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(100);
        _publish(steps, actions);
        IExecutor.Execution memory execution = _execution(_calls(steps, actions));
        execution.actions = new IMerkleAdapter.Action[](append ? 2 : 0);
        if (append) {
            execution.actions[0] = steps[0].action;
            execution.actions[1] = steps[0].action;
        }
        vm.expectRevert(IExecutor.InvalidActionsLength.selector);
        LiquidLaneExecutor(address(executor))
            .swap(
                _discountSwap(address(executor), address(rwa), 0),
                "",
                recipient,
                100,
                execution,
                new IMerkleAdapter.Action[](0)
            );
        assertEq(source.calls(), 0);
    }

    function _execute(IMerkleAdapter.Action[] memory calls, IMerkleAdapter.Action[] memory posts) internal {
        if (bytes4(calls[calls.length - 1].data) == IThreeFCapability.mintRequest.selector) {
            (address request, uint128 amount, uint128 minYield, uint256 deadline) =
                abi.decode(_arguments(calls[calls.length - 1].data), (address, uint128, uint128, uint256));
            ThreeFExecutor(address(executor)).mint(request, amount, minYield, deadline, _execution(calls));
        } else {
            _runLiquidLane(address(executor), calls, posts, 0);
        }
    }

    function _storedActions() internal view returns (IExecutor.Action[] memory stored) {
        stored = new IExecutor.Action[](executor.actionsLength());
        for (uint256 i; i < stored.length; ++i) {
            (stored[i].liquidityTarget, stored[i].liquidityCalldata, stored[i].leaf) = executor.actions(i);
        }
    }

    function _oracleRefresh() internal view returns (IMerkleAdapter.Action[] memory actions) {
        actions = new IMerkleAdapter.Action[](2);
        actions[0] = _action(address(lane), abi.encodeCall(ILiquidLaneConnector.removeTokenToRedeem, (address(rwa))));
        actions[1] = _action(address(lane), abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (address(rwa))));
    }

    function _newBorrow(uint256 minimum)
        internal
        returns (BorrowCapability actionContract, BorrowCapabilityPoolMock pool)
    {
        pool = new BorrowCapabilityPoolMock(address(asset));
        pool.setCollateral(address(adapter), 200);
        asset.transfer(address(pool), 1000);
        _installCapability(adapter, address(new BorrowCapability()), _borrowSelectors());
        actionContract = BorrowCapability(address(adapter));
        aaveHealthFactor = address(new AaveHealthFactor());
        IMerkleAdapter.Action[] memory calls = new IMerkleAdapter.Action[](1);
        calls[0] = _action(
            address(adapter),
            abi.encodeCall(
                IBorrowCapability.setHealthFactor,
                (keccak256(abi.encode(_borrowHealthFactor(pool).target, _borrowHealthFactor(pool).data)), minimum)
            )
        );
        bytes32 leaf = _leaf(calls[0]);
        roots.setRoot(address(adapter), leaf);
        adapter.acceptRoot(leaf);
        adapter.grantRole(leaf, address(this));
        adapter.manage(calls);
    }

    function _borrowStep(BorrowCapability actionContract, BorrowCapabilityPoolMock pool)
        internal
        view
        returns (LiquidityPlan memory step)
    {
        step.liquidityTarget = address(asset);
        step.liquidityData = abi.encodeCall(IERC20.balanceOf, (address(pool)));
        bytes memory borrowData = abi.encodeCall(pool.borrow, (address(asset), uint256(70), 2, 0, address(adapter)));
        step.action = _action(
            address(actionContract),
            abi.encodeCall(
                actionContract.borrow,
                (address(pool), _borrowHealthFactor(pool).target, borrowData, _borrowHealthFactor(pool).data)
            )
        );
        for (uint256 i = 200; i < 232; ++i) {
            step.action.dataMask[i] = 0xff;
        }
    }

    function _borrowHealthFactor(BorrowCapabilityPoolMock pool) internal view returns (BorrowTestCall memory) {
        return BorrowTestCall(
            aaveHealthFactor, abi.encodeCall(AaveHealthFactor.getHealthFactor, (address(pool), address(adapter)))
        );
    }

    function testFuzz_OnlyMissingAmountWithdrawn(uint256 idle, uint256 needed) public {
        needed = bound(needed, 1, 1_000_000);
        idle = bound(idle, 0, needed * 2);
        asset.transfer(address(adapter), idle);
        (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) = _plan(needed);
        steps[0] = _step(source, idle < needed ? needed - idle : 0);
        _publish(steps, actions);
        _execute(_calls(steps, actions), new IMerkleAdapter.Action[](0));
        assertEq(source.withdrawn(), idle < needed ? needed - idle : 0);
        assertEq(asset.balanceOf(address(adapter)), idle > needed ? idle - needed : 0);
    }

    function _newThreeF(uint128 principal)
        internal
        returns (ThreeFCapability actionContract, ThreeFCapabilityRequestMock request)
    {
        executor = new ThreeFExecutor(address(this), address(adapter));
        executor.setCaller(address(this));
        ThreeFCapabilityWhitelistMock whitelist = new ThreeFCapabilityWhitelistMock();
        ThreeFCapabilityFacilityMock facility = new ThreeFCapabilityFacilityMock();
        _installCapability(
            adapter, address(new ThreeFCapability(address(whitelist), address(facility))), _threeFSelectors()
        );
        actionContract = ThreeFCapability(address(adapter));
        request = new ThreeFCapabilityRequestMock(address(asset), "request-1");
        whitelist.set(address(request), IThreeFWhitelist.WhitelistStatus.Whitelisted);
        address collateral = address(new ThreeFCapabilityCollateralMock(address(rwa)));
        facility.setIntent(1, address(request), address(new ThreeFCapabilityPositionManagerMock(collateral)), true);
        vm.prank(address(adapter));
        actionContract.setMaxAssetsPerDuration(address(rwa), type(uint256).max, 1 days);
        request.authorizeMinting(address(actionContract), principal, 10);
    }

    function _threeFPlan(ThreeFCapability actionContract, ThreeFCapabilityRequestMock request, uint128 maxPrincipal)
        internal
        view
        returns (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions)
    {
        steps = new LiquidityPlan[](1);
        steps[0] = _step(source, maxPrincipal);
        actions = new IMerkleAdapter.Action[](2);
        actions[0] = _action(address(asset), abi.encodeCall(IERC20.approve, (address(request), maxPrincipal)));
        actions[1] = _action(
            address(actionContract),
            abi.encodeCall(IThreeFCapability.mintRequest, (address(request), maxPrincipal, uint128(1), block.timestamp))
        );
    }

    function _plan(uint256 amount)
        internal
        view
        returns (LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions)
    {
        steps = new LiquidityPlan[](1);
        steps[0] = _step(source, amount);
        actions = new IMerkleAdapter.Action[](2);
        actions[0] = _action(address(asset), abi.encodeCall(IERC20.approve, (address(lane), amount)));
        actions[1] = _action(
            address(lane),
            abi.encodeCall(
                ILiquidLaneConnector.swap, (ILiquidLaneConnector.Swap(recipient, address(rwa), amount, amount))
            )
        );
    }

    function _step(ExecutorLiquiditySource target, uint256 amount) internal view returns (LiquidityPlan memory step) {
        step.liquidityTarget = address(target);
        step.liquidityData = abi.encodeCall(target.getLiquidity, ());
        step.action = _action(address(target), abi.encodeCall(target.withdraw, (address(adapter), amount)));
        for (uint256 i = 36; i < 68; ++i) {
            step.action.dataMask[i] = 0xff;
        }
    }

    function _action(address target, bytes memory data) internal pure returns (IMerkleAdapter.Action memory action) {
        bytes memory mask = new bytes(data.length);
        return IMerkleAdapter.Action(target, 0, data, mask, new bytes32[](0));
    }

    function _publish(LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory actions) internal {
        if (actions.length == 2 && bytes4(actions[0].data) == IERC20.approve.selector) {
            for (uint256 i = 36; i < 68; ++i) {
                actions[0].dataMask[i] = 0xff;
            }
        }
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
        executor.setActions(_config(steps), _leaf(actions[0]), _leaf(actions[1]));
    }

    function _config(LiquidityPlan[] memory steps) internal pure returns (IExecutor.Action[] memory actions) {
        actions = new IExecutor.Action[](steps.length);
        for (uint256 i; i < steps.length; ++i) {
            actions[i] = IExecutor.Action(steps[i].liquidityTarget, steps[i].liquidityData, _leaf(steps[i].action));
        }
    }

    function _calls(LiquidityPlan[] memory steps, IMerkleAdapter.Action[] memory finalActions)
        internal
        pure
        returns (IMerkleAdapter.Action[] memory calls)
    {
        calls = new IMerkleAdapter.Action[](steps.length + finalActions.length);
        for (uint256 i; i < steps.length; ++i) {
            calls[i] = steps[i].action;
        }
        for (uint256 i; i < finalActions.length; ++i) {
            calls[steps.length + i] = finalActions[i];
        }
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

    function withdraw(address receiver, uint256 amount) external payable {
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

contract ExecutorApprovalToken is Token {
    uint8 public approvalMode;
    bool public requiresReset;
    uint256 public approvalCalls;
    uint256 public allowanceBeforeSpend;
    address public lastApprovalOwner;

    constructor() Token("Funding") {}

    function setApprovalBehavior(uint8 mode, bool reset) public {
        approvalMode = mode;
        requiresReset = reset;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        require(!requiresReset || amount == 0 || allowance(msg.sender, spender) == 0, "reset required");
        ++approvalCalls;
        lastApprovalOwner = msg.sender;
        super.approve(spender, amount);
        if (approvalMode == 1) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (approvalMode == 2) return false;
        if (approvalMode == 3) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(31, 1)
            }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        allowanceBeforeSpend = allowance(from, msg.sender);
        return super.transferFrom(from, to, value);
    }
}
