// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {LiquidLaneAction} from "../../../src/contracts/merkle_adapter/LiquidLaneAction.sol";
import {OracleRegistry} from "../../../src/contracts/merkle_adapter/OracleRegistry.sol";
import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {IAssetRateLimits} from "../../../src/interfaces/merkle_adapter/IAssetRateLimits.sol";
import {ILiquidLaneAction} from "../../../src/interfaces/merkle_adapter/ILiquidLaneAction.sol";
import {IOracleRegistry} from "../../../src/interfaces/merkle_adapter/IOracleRegistry.sol";
import {IOracle} from "../../../src/interfaces/ll-adapter/IOracle.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

contract OracleRegistryTest is Test {
    OracleRegistry internal registry;

    address internal owner = makeAddr("owner");
    address internal asset = makeAddr("asset");
    address internal tokenToRedeem = makeAddr("tokenToRedeem");
    address internal oracleFactory = makeAddr("oracleFactory");

    function setUp() public {
        registry = new OracleRegistry(owner);
    }

    function test_SetOracleFactoryStoresPairAndEmits() public {
        vm.expectEmit(true, true, true, true, address(registry));
        emit IOracleRegistry.SetOracleFactory(asset, tokenToRedeem, oracleFactory);

        vm.prank(owner);
        registry.setOracleFactory(asset, tokenToRedeem, oracleFactory);

        assertEq(registry.oracleFactories(asset, tokenToRedeem), oracleFactory);
    }

    function test_SetOracleFactoryRejectsNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.setOracleFactory(asset, tokenToRedeem, oracleFactory);
    }

    function test_SetOracleFactoryRejectsReplacement() public {
        vm.startPrank(owner);
        registry.setOracleFactory(asset, tokenToRedeem, oracleFactory);
        vm.expectRevert(IOracleRegistry.OracleFactoryAlreadySet.selector);
        registry.setOracleFactory(asset, tokenToRedeem, makeAddr("otherOracleFactory"));
        vm.stopPrank();
    }
}

contract LiquidLaneActionTest is Test {
    ActionTokenMock internal asset;
    ActionTokenMock internal vaultAsset;
    ActionTokenMock internal tokenToRedeem;
    ActionVaultMock internal vault;
    ActionAdapterMock internal adapter;
    OracleRegistry internal registry;
    MigratablesFactory internal actionFactory;
    MigratablesFactory internal oracleFactory;
    ActionOracleMock internal latestOracleImplementation;
    LiquidLaneAction internal actionContract;

    address internal adapterOwner = makeAddr("adapterOwner");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        asset = new ActionTokenMock("USD Coin", "USDC", 6);
        vaultAsset = new ActionTokenMock("Wrapped Ether", "WETH", 18);
        tokenToRedeem = new ActionTokenMock("RWA", "RWA", 18);
        vault = new ActionVaultMock(address(vaultAsset));
        adapter = new ActionAdapterMock(address(vault), adapterOwner);
        registry = new OracleRegistry(address(this));
        actionFactory = new MigratablesFactory(address(this));
        oracleFactory = new MigratablesFactory(address(this));

        oracleFactory.whitelist(address(new ActionOracleMock(address(oracleFactory), 1e18)));
        latestOracleImplementation = new ActionOracleMock(address(oracleFactory), 2e18);
        oracleFactory.whitelist(address(latestOracleImplementation));
        registry.setOracleFactory(address(asset), address(tokenToRedeem), address(oracleFactory));

        actionFactory.whitelist(address(new LiquidLaneAction(address(actionFactory), address(registry))));
        actionContract = _createAction(address(adapter), address(asset), _outputs(address(tokenToRedeem)));
        _setLimit(actionContract, address(tokenToRedeem), type(uint256).max, 1 days);
    }

    function test_FactoryCreationInitializesAdapterOwnerFactoryAndVersion() public view {
        assertEq(actionContract.adapter(), address(adapter));
        assertEq(actionContract.inputAsset(), address(asset));
        assertEq(actionContract.ORACLE_REGISTRY(), address(registry));
        assertEq(actionContract.FACTORY(), address(actionFactory));
        assertEq(actionContract.version(), actionFactory.lastVersion());
        assertEq(actionContract.owner(), adapterOwner);

        ActionOracleMock oracle = ActionOracleMock(actionContract.oracles(address(tokenToRedeem)));
        assertEq(actionContract.getTokensToRedeemLength(), 1);
        assertEq(actionContract.tokensToRedeem(0), address(tokenToRedeem));
        assertEq(oracleFactory.lastVersion(), 2);
        assertEq(oracle.version(), oracleFactory.lastVersion());
        assertEq(oracle.owner(), actionContract.owner());
        assertEq(oracle.inputAsset(), address(asset));
        assertEq(oracle.actionContract(), address(actionContract));
        assertEq(oracle.price(), latestOracleImplementation.price());
    }

    function test_InitializationCreatesAllOutputsInOrder() public {
        ActionTokenMock secondOutput = new ActionTokenMock("Second RWA", "RWA2", 8);
        registry.setOracleFactory(address(asset), address(secondOutput), address(oracleFactory));
        address[] memory outputs = new address[](2);
        outputs[0] = address(tokenToRedeem);
        outputs[1] = address(secondOutput);

        LiquidLaneAction secondAction = _createAction(address(adapter), address(asset), outputs);

        assertEq(secondAction.getTokensToRedeemLength(), 2);
        assertEq(secondAction.tokensToRedeem(0), address(tokenToRedeem));
        assertEq(secondAction.tokensToRedeem(1), address(secondOutput));
        assertNotEq(secondAction.oracles(address(tokenToRedeem)), address(0));
        assertNotEq(secondAction.oracles(address(secondOutput)), address(0));
    }

    function test_InitializationRejectsZeroAdapterAtomically() public {
        _expectCreateRevert(
            ILiquidLaneAction.InvalidAdapter.selector, address(0), address(asset), _outputs(address(tokenToRedeem))
        );
    }

    function test_InitializationRejectsZeroInputAssetAtomically() public {
        _expectCreateRevert(
            ILiquidLaneAction.InvalidInputAsset.selector, address(adapter), address(0), _outputs(address(tokenToRedeem))
        );
    }

    function test_InitializationRejectsEmptyOutputsAtomically() public {
        _expectCreateRevert(
            ILiquidLaneAction.EmptyTokensToRedeem.selector, address(adapter), address(asset), new address[](0)
        );
    }

    function test_InitializationRejectsZeroOutputAtomically() public {
        _expectCreateRevert(
            ILiquidLaneAction.InvalidTokenToRedeem.selector, address(adapter), address(asset), _outputs(address(0))
        );
    }

    function test_InitializationRejectsInputAsOutputAtomically() public {
        _expectCreateRevert(
            ILiquidLaneAction.InvalidTokenToRedeem.selector, address(adapter), address(asset), _outputs(address(asset))
        );
    }

    function test_InitializationRejectsDuplicateOutputAtomically() public {
        address[] memory outputs = new address[](2);
        outputs[0] = address(tokenToRedeem);
        outputs[1] = address(tokenToRedeem);

        _expectCreateRevert(ILiquidLaneAction.InvalidTokenToRedeem.selector, address(adapter), address(asset), outputs);
    }

    function test_InitializationRejectsMissingOracleFactoryAtomically() public {
        ActionTokenMock unknownToken = new ActionTokenMock("Unknown", "UNKNOWN", 18);
        _expectCreateRevert(
            ILiquidLaneAction.InvalidOracleFactory.selector,
            address(adapter),
            address(asset),
            _outputs(address(unknownToken))
        );
    }

    function test_InitializationAllowsMoreThanFiftyOutputs() public {
        address[] memory outputs = new address[](51);
        for (uint256 i; i < outputs.length; ++i) {
            outputs[i] = address(uint160(1000 + i));
            registry.setOracleFactory(address(asset), outputs[i], address(oracleFactory));
        }

        LiquidLaneAction largeCapability = _createAction(address(adapter), address(asset), outputs);

        assertEq(largeCapability.getTokensToRedeemLength(), outputs.length);
        assertEq(largeCapability.tokensToRedeem(outputs.length - 1), outputs[outputs.length - 1]);
    }

    function test_MigratePreservesConfiguration() public {
        uint256 periodStart = vm.getBlockTimestamp();
        _setLimit(actionContract, address(tokenToRedeem), 200e6, 1 days);
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(adapter), 200e6);
        adapter.approve(address(asset), address(actionContract), 200e6);
        adapter.execute(address(actionContract), abi.encodeCall(ILiquidLaneAction.swap, (_swap(50e18, 100e6))));
        vm.warp(block.timestamp + 10 minutes);
        address oracle = actionContract.oracles(address(tokenToRedeem));
        actionFactory.whitelist(address(new LiquidLaneAction(address(actionFactory), address(registry))));
        uint64 newVersion = actionFactory.lastVersion();

        vm.prank(adapterOwner);
        actionFactory.migrate(address(actionContract), newVersion, bytes(""));

        assertEq(actionContract.version(), newVersion);
        assertEq(actionContract.owner(), adapterOwner);
        assertEq(actionContract.adapter(), address(adapter));
        assertEq(actionContract.inputAsset(), address(asset));
        assertEq(actionContract.getTokensToRedeemLength(), 1);
        assertEq(actionContract.tokensToRedeem(0), address(tokenToRedeem));
        assertEq(actionContract.oracles(address(tokenToRedeem)), oracle);
        (uint256 maximum, uint256 duration, uint256 start, uint256 spent) =
            actionContract.assetLimits(address(tokenToRedeem));
        assertEq(maximum, 200e6);
        assertEq(duration, 1 days);
        assertEq(start, periodStart);
        assertEq(spent, 100e6);
        assertEq(actionContract.remainingAssets(address(tokenToRedeem)), 100e6);
        adapter.execute(address(actionContract), abi.encodeCall(ILiquidLaneAction.swap, (_swap(50e18, 100e6))));
        assertEq(actionContract.remainingAssets(address(tokenToRedeem)), 0);
    }

    function test_MigrateLegacyCapabilityBackfillsInputAssetAndPreservesConfiguration() public {
        MigratablesFactory legacyFactory = new MigratablesFactory(address(this));
        legacyFactory.whitelist(address(new LegacyLiquidLaneCapability(address(legacyFactory), address(registry))));
        LegacyLiquidLaneCapability legacyAction = LegacyLiquidLaneCapability(
            legacyFactory.create(legacyFactory.lastVersion(), adapterOwner, abi.encode(address(adapter)))
        );
        registry.setOracleFactory(address(vaultAsset), address(tokenToRedeem), address(oracleFactory));
        adapter.execute(
            address(legacyAction), abi.encodeCall(LegacyLiquidLaneCapability.addTokenToRedeem, (address(tokenToRedeem)))
        );
        address oracle = legacyAction.oracles(address(tokenToRedeem));
        legacyFactory.whitelist(address(new LiquidLaneAction(address(legacyFactory), address(registry))));
        uint64 newVersion = legacyFactory.lastVersion();

        vm.prank(adapterOwner);
        legacyFactory.migrate(address(legacyAction), newVersion, bytes(""));

        LiquidLaneAction migrated = LiquidLaneAction(address(legacyAction));
        assertEq(migrated.inputAsset(), address(vaultAsset));
        assertEq(migrated.adapter(), address(adapter));
        assertEq(migrated.getTokensToRedeemLength(), 1);
        assertEq(migrated.tokensToRedeem(0), address(tokenToRedeem));
        assertEq(migrated.oracles(address(tokenToRedeem)), oracle);
        assertEq(migrated.getAmountOut(address(tokenToRedeem), 100e18), 200e18);

        tokenToRedeem.mint(address(migrated), 100e18);
        vaultAsset.mint(address(adapter), 200e18);
        adapter.approve(address(vaultAsset), address(migrated), type(uint256).max);
        vm.expectRevert(IAssetRateLimits.UnconfiguredAsset.selector);
        adapter.execute(address(migrated), abi.encodeCall(ILiquidLaneAction.swap, (_swap(100e18, 190e18))));
        _setLimit(migrated, address(tokenToRedeem), 190e18, 1 days);
        adapter.execute(address(migrated), abi.encodeCall(ILiquidLaneAction.swap, (_swap(100e18, 190e18))));

        assertEq(vaultAsset.balanceOf(recipient), 190e18);
        assertEq(tokenToRedeem.balanceOf(address(adapter)), 100e18);
    }

    function test_MigrateRejectsNonEmptyDataAndKeepsVersion() public {
        actionFactory.whitelist(address(new LiquidLaneAction(address(actionFactory), address(registry))));
        uint64 newVersion = actionFactory.lastVersion();

        vm.prank(adapterOwner);
        vm.expectRevert(ILiquidLaneAction.InvalidMigrationData.selector);
        actionFactory.migrate(address(actionContract), newVersion, hex"01");

        assertEq(actionContract.version(), 1);
    }

    function test_AddTokenToRedeemSelectorIsUnavailable() public {
        vm.expectRevert();
        adapter.execute(
            address(actionContract),
            abi.encodeWithSelector(bytes4(keccak256("addTokenToRedeem(address)")), address(asset))
        );
    }

    function test_GetAmountOutUsesExplicitInputAssetAndTokenDecimals() public view {
        assertEq(actionContract.getAmountOut(address(tokenToRedeem), 100e18), 200e6);
    }

    function test_SwapPullsInputAssetToRecipientAndTransfersRwaToAdapter() public {
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(adapter), 200e6);
        adapter.approve(address(asset), address(actionContract), type(uint256).max);
        ILiquidLaneAction.Swap memory swap_ = _swap(100e18, 190e6);

        vm.expectEmit(false, false, false, true, address(actionContract));
        emit ILiquidLaneAction.DoSwap(swap_);
        adapter.execute(address(actionContract), abi.encodeCall(ILiquidLaneAction.swap, (swap_)));

        assertEq(asset.balanceOf(recipient), 190e6);
        assertEq(asset.balanceOf(address(adapter)), 10e6);
        assertEq(asset.balanceOf(address(actionContract)), 0);
        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 0);
        assertEq(tokenToRedeem.balanceOf(address(adapter)), 100e18);
    }

    function test_SwapsShareAssetBudgetUntilDurationEnds() public {
        _setLimit(actionContract, address(tokenToRedeem), 190e6, 1 days);
        tokenToRedeem.mint(address(actionContract), 200e18);
        asset.mint(address(adapter), 380e6);
        adapter.approve(address(asset), address(actionContract), type(uint256).max);
        bytes memory data = abi.encodeCall(ILiquidLaneAction.swap, (_swap(100e18, 190e6)));

        adapter.execute(address(actionContract), data);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        adapter.execute(address(actionContract), data);
        assertEq(asset.balanceOf(recipient), 190e6);
        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 100e18);

        vm.warp(block.timestamp + 1 days);
        adapter.execute(address(actionContract), data);
        assertEq(asset.balanceOf(recipient), 380e6);
        assertEq(tokenToRedeem.balanceOf(address(adapter)), 200e18);
    }

    function test_LimitConfigurationRequiresAdapterAndKnownToken() public {
        vm.prank(adapterOwner);
        vm.expectRevert(ILiquidLaneAction.InvalidCaller.selector);
        actionContract.setMaxAssetsPerDuration(address(tokenToRedeem), 100e6, 1 days);
        vm.expectRevert(ILiquidLaneAction.InvalidCaller.selector);
        actionContract.setMaxAssetsPerDuration(address(tokenToRedeem), 100e6, 1 days);
        vm.expectRevert(ILiquidLaneAction.InvalidTokenToRedeem.selector);
        _setLimit(actionContract, address(asset), 100e6, 1 days);
        vm.expectRevert(IAssetRateLimits.InvalidDuration.selector);
        _setLimit(actionContract, address(tokenToRedeem), 100e6, 0);
        vm.expectEmit(true, false, false, true, address(actionContract));
        emit IAssetRateLimits.SetMaxAssetsPerDuration(address(tokenToRedeem), 100e6, 1 days);
        _setLimit(actionContract, address(tokenToRedeem), 100e6, 1 days);
    }

    function test_UnconfiguredAssetCannotSwapDespiteInventoryAndApproval() public {
        LiquidLaneAction fresh = _createAction(address(adapter), address(asset), _outputs(address(tokenToRedeem)));
        tokenToRedeem.mint(address(fresh), 100e18);
        asset.mint(address(adapter), 200e6);
        adapter.approve(address(asset), address(fresh), 200e6);
        assertEq(fresh.remainingAssets(address(tokenToRedeem)), 0);
        vm.expectRevert(IAssetRateLimits.UnconfiguredAsset.selector);
        adapter.execute(address(fresh), abi.encodeCall(ILiquidLaneAction.swap, (_swap(100e18, 190e6))));
        assertEq(asset.balanceOf(recipient), 0);
        assertEq(tokenToRedeem.balanceOf(address(fresh)), 100e18);
    }

    function test_TokenBudgetsAreIndependentAndUseFundingAssetUnits() public {
        ActionTokenMock second = new ActionTokenMock("Second", "RWA2", 8);
        registry.setOracleFactory(address(asset), address(second), address(oracleFactory));
        address[] memory outputs = new address[](2);
        outputs[0] = address(tokenToRedeem);
        outputs[1] = address(second);
        LiquidLaneAction target = _createAction(address(adapter), address(asset), outputs);
        _setLimit(target, address(tokenToRedeem), 100e6, 1 days);
        _setLimit(target, address(second), 60e6, 2 days);
        tokenToRedeem.mint(address(target), 51e18);
        second.mint(address(target), 31e8);
        asset.mint(address(adapter), 162e6);
        adapter.approve(address(asset), address(target), 162e6);
        adapter.execute(address(target), abi.encodeCall(ILiquidLaneAction.swap, (_swap(50e18, 100e6))));
        assertEq(target.remainingAssets(address(second)), 60e6);
        adapter.execute(address(target), abi.encodeCall(ILiquidLaneAction.swap, (_swap(address(second), 30e8, 60e6))));
        assertEq(target.remainingAssets(address(tokenToRedeem)), 0);
        assertEq(target.remainingAssets(address(second)), 0);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        adapter.execute(address(target), abi.encodeCall(ILiquidLaneAction.swap, (_swap(address(second), 1e8, 1e6))));
        vm.warp(block.timestamp + 1 days);
        assertEq(target.remainingAssets(address(tokenToRedeem)), 100e6);
        assertEq(target.remainingAssets(address(second)), 0);
    }

    function test_FailedTransferRestoresBudgetForRetry() public {
        _setLimit(actionContract, address(tokenToRedeem), 190e6, 1 days);
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(adapter), 190e6);
        adapter.approve(address(asset), address(actionContract), 190e6);
        asset.setRevertTransfers(true);
        bytes memory data = abi.encodeCall(ILiquidLaneAction.swap, (_swap(100e18, 190e6)));
        vm.expectRevert(ActionTokenMock.ForcedTransferRevert.selector);
        adapter.execute(address(actionContract), data);
        assertEq(actionContract.remainingAssets(address(tokenToRedeem)), 190e6);
        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 100e18);
        asset.setRevertTransfers(false);
        adapter.execute(address(actionContract), data);
        assertEq(actionContract.remainingAssets(address(tokenToRedeem)), 0);
        assertEq(asset.balanceOf(recipient), 190e6);
    }

    function test_TokenCallbackCannotReconfigureBudgetDuringSwap() public {
        _setLimit(actionContract, address(tokenToRedeem), 190e6, 1 days);
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(adapter), 190e6);
        adapter.approve(address(asset), address(actionContract), 190e6);
        tokenToRedeem.setCallback(
            address(adapter),
            abi.encodeCall(
                adapter.execute,
                (
                    address(actionContract),
                    abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (address(tokenToRedeem), 380e6, 1 days))
                )
            )
        );
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        adapter.execute(address(actionContract), abi.encodeCall(ILiquidLaneAction.swap, (_swap(100e18, 190e6))));
        assertEq(actionContract.remainingAssets(address(tokenToRedeem)), 190e6);
        assertEq(asset.balanceOf(recipient), 0);
    }

    function test_SwapTransfersOnlyAmountInRwaToAdapter() public {
        tokenToRedeem.mint(address(actionContract), 120e18);
        asset.mint(address(adapter), 200e6);
        adapter.approve(address(asset), address(actionContract), type(uint256).max);
        ILiquidLaneAction.Swap memory swap_ = _swap(100e18, 190e6);

        adapter.execute(address(actionContract), abi.encodeCall(ILiquidLaneAction.swap, (swap_)));

        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 20e18);
        assertEq(tokenToRedeem.balanceOf(address(adapter)), 100e18);
    }

    function test_SwapPropagatesOutputAssetTransferFailure() public {
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(adapter), 200e6);
        adapter.approve(address(asset), address(actionContract), type(uint256).max);
        tokenToRedeem.setRevertTransfers(true);

        vm.expectRevert(ActionTokenMock.ForcedTransferRevert.selector);
        adapter.execute(address(actionContract), abi.encodeCall(ILiquidLaneAction.swap, (_swap(100e18, 190e6))));

        assertEq(asset.balanceOf(recipient), 0);
        assertEq(asset.balanceOf(address(adapter)), 200e6);
        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 100e18);
        assertEq(tokenToRedeem.balanceOf(address(adapter)), 0);
    }

    function test_SwapRejectsNonAdapter() public {
        vm.expectRevert(ILiquidLaneAction.InvalidCaller.selector);
        actionContract.swap(_swap(100e18, 190e6));
    }

    function test_SwapRejectsUnknownToken() public {
        ActionTokenMock unknownToken = new ActionTokenMock("Unknown", "UNKNOWN", 18);
        vm.expectRevert(ILiquidLaneAction.InvalidTokenToRedeem.selector);
        adapter.execute(
            address(actionContract),
            abi.encodeCall(ILiquidLaneAction.swap, (_swap(address(unknownToken), 100e18, 190e6)))
        );
    }

    function test_SwapRejectsAmountInAboveRwaBalance() public {
        tokenToRedeem.mint(address(actionContract), 99e18);

        vm.expectRevert(ILiquidLaneAction.InsufficientRwaBalance.selector);
        adapter.execute(address(actionContract), abi.encodeCall(ILiquidLaneAction.swap, (_swap(100e18, 190e6))));
    }

    function test_SwapRejectsAmountOutAboveOracleQuote() public {
        tokenToRedeem.mint(address(actionContract), 100e18);

        vm.expectRevert(ILiquidLaneAction.InvalidSwapRate.selector);
        adapter.execute(address(actionContract), abi.encodeCall(ILiquidLaneAction.swap, (_swap(100e18, 201e6))));
    }

    function test_SwapPropagatesInputAssetAllowanceFailure() public {
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(adapter), 200e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(actionContract), uint256(0), uint256(190e6)
            )
        );
        adapter.execute(address(actionContract), abi.encodeCall(ILiquidLaneAction.swap, (_swap(100e18, 190e6))));

        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 100e18);
        assertEq(tokenToRedeem.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(recipient), 0);
        assertEq(asset.balanceOf(address(adapter)), 200e6);
    }

    function test_SwapPropagatesInputAssetBalanceFailure() public {
        tokenToRedeem.mint(address(actionContract), 100e18);
        adapter.approve(address(asset), address(actionContract), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(adapter), uint256(0), uint256(190e6)
            )
        );
        adapter.execute(address(actionContract), abi.encodeCall(ILiquidLaneAction.swap, (_swap(100e18, 190e6))));

        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 100e18);
        assertEq(tokenToRedeem.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(recipient), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
    }

    function test_SwapPropagatesOracleFailure() public {
        tokenToRedeem.mint(address(actionContract), 100e18);
        ActionOracleMock(actionContract.oracles(address(tokenToRedeem))).setRevertGetPrice(true);

        vm.expectRevert(bytes("oracle failure"));
        adapter.execute(address(actionContract), abi.encodeCall(ILiquidLaneAction.swap, (_swap(100e18, 190e6))));
    }

    function _setLimit(LiquidLaneAction target, address token, uint256 maximum, uint256 duration) internal {
        adapter.execute(
            address(target), abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (token, maximum, duration))
        );
    }

    function _swap(uint256 amountIn, uint256 amountOut) internal view returns (ILiquidLaneAction.Swap memory swap_) {
        swap_ = _swap(address(tokenToRedeem), amountIn, amountOut);
    }

    function _swap(address output, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (ILiquidLaneAction.Swap memory swap_)
    {
        swap_ = ILiquidLaneAction.Swap({
            recipient: recipient, tokenIn: output, amountIn: amountIn, amountOut: amountOut
        });
    }

    function _createAction(address adapter_, address inputAsset_, address[] memory outputs)
        internal
        returns (LiquidLaneAction created)
    {
        created = LiquidLaneAction(
            actionFactory.create(actionFactory.lastVersion(), adapterOwner, abi.encode(adapter_, inputAsset_, outputs))
        );
    }

    function _expectCreateRevert(bytes4 selector, address adapter_, address inputAsset_, address[] memory outputs)
        internal
    {
        uint256 capabilityEntities = actionFactory.totalEntities();
        uint256 oracleEntities = oracleFactory.totalEntities();
        uint64 version = actionFactory.lastVersion();
        vm.expectRevert(selector);
        actionFactory.create(version, adapterOwner, abi.encode(adapter_, inputAsset_, outputs));
        assertEq(actionFactory.totalEntities(), capabilityEntities);
        assertEq(oracleFactory.totalEntities(), oracleEntities);
    }

    function _outputs(address output) internal pure returns (address[] memory outputs) {
        outputs = new address[](1);
        outputs[0] = output;
    }
}

contract LegacyLiquidLaneCapability is MigratableEntity {
    address public adapter;
    address public immutable ORACLE_REGISTRY;
    address[] public tokensToRedeem;
    mapping(address tokenToRedeem => address oracle) public oracles;
    mapping(address tokenToRedeem => bool exists) internal _isTokenToRedeem;

    constructor(address factory, address oracleRegistry) MigratableEntity(factory) {
        ORACLE_REGISTRY = oracleRegistry;
    }

    function addTokenToRedeem(address tokenToRedeem) external {
        require(msg.sender == adapter);
        address vault_ = ActionAdapterMock(adapter).vault();
        address asset_ = ActionVaultMock(vault_).asset();
        address oracleFactory_ = IOracleRegistry(ORACLE_REGISTRY).oracleFactories(asset_, tokenToRedeem);
        address oracle = MigratablesFactory(oracleFactory_)
            .create(MigratablesFactory(oracleFactory_).lastVersion(), owner(), abi.encode(vault_, address(this)));
        oracles[tokenToRedeem] = oracle;
        _isTokenToRedeem[tokenToRedeem] = true;
        tokensToRedeem.push(tokenToRedeem);
    }

    function _initialize(uint64, address, bytes memory data) internal override {
        adapter = abi.decode(data, (address));
    }
}

contract ActionAdapterMock {
    using Address for address;

    address public immutable vault;
    address public immutable owner;

    constructor(address vault_, address owner_) {
        vault = vault_;
        owner = owner_;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        result = target.functionCall(data);
    }

    function approve(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }
}

contract ActionVaultMock {
    address public immutable asset;

    constructor(address asset_) {
        asset = asset_;
    }
}

contract ActionTokenMock is ERC20 {
    error ForcedTransferRevert();

    uint8 internal immutable _tokenDecimals;
    bool internal _revertTransfers;
    address internal _callbackTarget;
    bytes internal _callbackData;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function setRevertTransfers(bool status) external {
        _revertTransfers = status;
    }

    function setCallback(address target, bytes calldata data) external {
        _callbackTarget = target;
        _callbackData = data;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (_revertTransfers && from != address(0)) {
            revert ForcedTransferRevert();
        }
        super._update(from, to, amount);
        if (from != address(0) && _callbackTarget != address(0)) {
            address target = _callbackTarget;
            _callbackTarget = address(0);
            Address.functionCall(target, _callbackData);
        }
    }
}

contract ActionOracleMock is MigratableEntity, IOracle {
    uint256 public immutable price;
    address public inputAsset;
    address public actionContract;
    bool public revertGetPrice;

    constructor(address factory, uint256 price_) MigratableEntity(factory) {
        price = price_;
    }

    function getPrice() external view returns (uint256) {
        if (revertGetPrice) {
            revert("oracle failure");
        }
        return price;
    }

    function setRevertGetPrice(bool status) external {
        revertGetPrice = status;
    }

    function _initialize(uint64, address, bytes memory data) internal override {
        (inputAsset, actionContract) = abi.decode(data, (address, address));
    }
}
