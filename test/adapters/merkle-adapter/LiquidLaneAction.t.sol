// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {LiquidLaneAction} from "src/contracts/merkle_adapter/LiquidLaneAction.sol";
import {ERC4626Oracle} from "src/contracts/ll-adapter/oracles/ERC4626Oracle.sol";
import {IAssetRateLimits} from "src/interfaces/merkle_adapter/IAssetRateLimits.sol";
import {ILiquidLaneAction} from "src/interfaces/merkle_adapter/ILiquidLaneAction.sol";
import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {
    FixedOracleLiquidLaneAction,
    TwoAssetLiquidLaneAction,
    ActionOracleMock
} from "../../mocks/liquid-lane/LiquidLaneActionMocks.sol";

contract LiquidLaneActionTest is Test {
    ActionTokenMock internal asset;
    ActionTokenMock internal vaultAsset;
    ActionTokenMock internal tokenToRedeem;
    ActionVaultMock internal vault;
    ActionAdapterMock internal adapter;
    MigratablesFactory internal actionFactory;
    ActionOracleMock internal priceOracle;
    LiquidLaneAction internal actionContract;
    FixedOracleLiquidLaneAction internal implementation;

    address internal adapterOwner = makeAddr("adapterOwner");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        asset = new ActionTokenMock("USD Coin", "USDC", 6);
        vaultAsset = new ActionTokenMock("Wrapped Ether", "WETH", 18);
        tokenToRedeem = new ActionTokenMock("RWA", "RWA", 18);
        vault = new ActionVaultMock(address(vaultAsset));
        adapter = new ActionAdapterMock(address(vault), adapterOwner);
        actionFactory = new MigratablesFactory(address(this));
        priceOracle = new ActionOracleMock(2e18);
        implementation = new FixedOracleLiquidLaneAction(
            address(actionFactory), address(asset), address(tokenToRedeem), address(priceOracle)
        );
        actionFactory.whitelist(address(implementation));
        actionContract = _createAction(address(adapter));
        _setLimit(actionContract, address(tokenToRedeem), type(uint256).max, 1 days);
    }

    function test_FactoryCreationBindsAdapterAndImplementationConfiguration() public view {
        assertEq(actionContract.adapter(), address(adapter));
        assertEq(actionContract.inputAsset(), address(asset));
        assertEq(implementation.inputAsset(), address(asset));
        assertEq(actionContract.FACTORY(), address(actionFactory));
        assertEq(actionContract.version(), 1);
        assertEq(actionContract.owner(), adapterOwner);
        assertEq(actionContract.oracle(address(tokenToRedeem)), address(priceOracle));
        assertEq(implementation.oracle(address(tokenToRedeem)), address(priceOracle));
    }

    function test_ProxiesShareFixedOracleButHaveIndependentBudgets() public {
        LiquidLaneAction secondAction = _createAction(address(adapter));
        assertEq(secondAction.oracle(address(tokenToRedeem)), address(priceOracle));
        assertEq(secondAction.inputAsset(), address(asset));
        assertEq(secondAction.remainingAssets(address(tokenToRedeem)), 0);
        _setLimit(secondAction, address(tokenToRedeem), 50e6, 1 days);
        assertEq(secondAction.remainingAssets(address(tokenToRedeem)), 50e6);
        assertEq(actionContract.remainingAssets(address(tokenToRedeem)), type(uint256).max);
    }

    function test_ImplementationOracleControlsPricing() public {
        ActionOracleMock fixedOracle = new ActionOracleMock(3e18);
        _whitelist(address(asset), address(tokenToRedeem), address(fixedOracle));
        LiquidLaneAction fixedAction = _createAction(address(adapter));
        assertEq(fixedAction.getAmountOut(address(tokenToRedeem), 100e18), 300e6);
        assertEq(actionContract.getAmountOut(address(tokenToRedeem), 100e18), 200e6);
    }

    function test_AssetSpecificOraclesControlQuotesAndSwapCeilings() public {
        ActionTokenMock second = new ActionTokenMock("Second RWA", "RWA2", 8);
        ActionOracleMock secondOracle = new ActionOracleMock(3e18);
        actionFactory.whitelist(
            address(
                new TwoAssetLiquidLaneAction(
                    address(actionFactory),
                    address(asset),
                    address(tokenToRedeem),
                    address(priceOracle),
                    address(second),
                    address(secondOracle)
                )
            )
        );
        LiquidLaneAction target = _createAction(address(adapter));
        assertEq(target.getAmountOut(address(tokenToRedeem), 100e18), 200e6);
        assertEq(target.getAmountOut(address(second), 100e8), 300e6);
        _setLimit(target, address(second), 300e6, 1 days);
        second.mint(address(target), 100e8);
        asset.mint(address(adapter), 300e6);
        adapter.approve(address(asset), address(target), 300e6);
        vm.expectRevert(ILiquidLaneAction.InvalidSwapRate.selector);
        adapter.execute(
            address(target), abi.encodeCall(ILiquidLaneAction.swap, (_swap(address(second), 100e8, 300e6 + 1)))
        );
        adapter.execute(address(target), abi.encodeCall(ILiquidLaneAction.swap, (_swap(address(second), 100e8, 300e6))));
        assertEq(asset.balanceOf(recipient), 300e6);
        assertEq(second.balanceOf(address(adapter)), 100e8);
    }

    function test_ExistingConstructorOraclePricesAndSettlesWithoutFactoryWrapper() public {
        ActionERC4626Vault shares = new ActionERC4626Vault(asset);
        asset.mint(address(this), 100e6);
        asset.approve(address(shares), 100e6);
        shares.deposit(100e6, address(this));
        // The donation includes the virtual asset, giving exactly two asset units per share unit.
        asset.mint(address(shares), 100e6 + 1);
        ERC4626Oracle fixedOracle = new ERC4626Oracle(1e18, 3e18, address(shares));
        _whitelist(address(asset), address(shares), address(fixedOracle));
        LiquidLaneAction target = _createAction(address(adapter));
        assertEq(target.getAmountOut(address(shares), 100e6), 200e6);
        _setLimit(target, address(shares), 200e6, 1 days);
        shares.transfer(address(target), 100e6);
        asset.mint(address(adapter), 200e6);
        adapter.approve(address(asset), address(target), 200e6);
        adapter.execute(address(target), abi.encodeCall(ILiquidLaneAction.swap, (_swap(address(shares), 100e6, 200e6))));
        assertEq(asset.balanceOf(recipient), 200e6);
        assertEq(shares.balanceOf(address(adapter)), 100e6);
        assertEq(target.remainingAssets(address(shares)), 0);
    }

    function test_ConstructorRejectsZeroFundingAsset() public {
        vm.expectRevert(ILiquidLaneAction.InvalidInputAsset.selector);
        new FixedOracleLiquidLaneAction(
            address(actionFactory), address(0), address(tokenToRedeem), address(priceOracle)
        );
    }

    function test_InitializationRejectsZeroAdapterAtomically() public {
        uint256 entities = actionFactory.totalEntities();
        vm.expectRevert(ILiquidLaneAction.InvalidAdapter.selector);
        actionFactory.create(1, adapterOwner, abi.encode(address(0)));
        assertEq(actionFactory.totalEntities(), entities);
    }

    function test_InitializerCannotSupplyAssetOrOracleConfiguration() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(vaultAsset);
        vm.expectRevert(ILiquidLaneAction.InvalidInitializationData.selector);
        actionFactory.create(1, adapterOwner, abi.encode(address(adapter), address(vaultAsset), tokens));
        vm.expectRevert(ILiquidLaneAction.InvalidInitializationData.selector);
        actionFactory.create(1, adapterOwner, bytes(""));
        assertEq(actionFactory.totalEntities(), 1);
    }

    function testFuzz_ZeroOracleRejectsQuotesConfigurationAndSwaps(address token) public {
        vm.assume(token != address(tokenToRedeem));
        assertEq(actionContract.oracle(token), address(0));
        vm.expectRevert(ILiquidLaneAction.InvalidTokenToRedeem.selector);
        actionContract.getAmountOut(token, 1);
        vm.expectRevert(ILiquidLaneAction.InvalidTokenToRedeem.selector);
        _setLimit(actionContract, token, 1, 1 days);
        vm.expectRevert(ILiquidLaneAction.InvalidTokenToRedeem.selector);
        adapter.execute(address(actionContract), abi.encodeCall(ILiquidLaneAction.swap, (_swap(token, 1, 1))));
    }

    function test_ZeroAndFundingTokenRejectedEvenIfOverrideReturnsOracle() public {
        _assertInvalidConfiguredToken(address(0));
        _assertInvalidConfiguredToken(address(asset));
    }

    function test_MigratePreservesBudgetsAndUsesNewImplementationOracle() public {
        uint256 periodStart = vm.getBlockTimestamp();
        _setLimit(actionContract, address(tokenToRedeem), 200e6, 1 days);
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(adapter), 200e6);
        adapter.approve(address(asset), address(actionContract), 200e6);
        adapter.execute(address(actionContract), abi.encodeCall(ILiquidLaneAction.swap, (_swap(50e18, 100e6))));
        vm.warp(block.timestamp + 10 minutes);
        ActionOracleMock newOracle = new ActionOracleMock(3e18);
        _whitelist(address(asset), address(tokenToRedeem), address(newOracle));
        assertEq(actionContract.getAmountOut(address(tokenToRedeem), 100e18), 200e6);
        _migrate(actionContract);
        assertEq(actionContract.version(), 2);
        assertEq(actionContract.owner(), adapterOwner);
        assertEq(actionContract.adapter(), address(adapter));
        assertEq(actionContract.inputAsset(), address(asset));
        assertEq(actionContract.oracle(address(tokenToRedeem)), address(newOracle));
        assertEq(actionContract.getAmountOut(address(tokenToRedeem), 100e18), 300e6);
        _assertBudget(actionContract, periodStart);
        adapter.execute(address(actionContract), abi.encodeCall(ILiquidLaneAction.swap, (_swap(50e18, 100e6))));
        assertEq(actionContract.remainingAssets(address(tokenToRedeem)), 0);
    }

    function test_MigrationCannotChangeFundingDenomination() public {
        _whitelist(address(vaultAsset), address(tokenToRedeem), address(priceOracle));
        vm.prank(adapterOwner);
        vm.expectRevert(ILiquidLaneAction.InvalidInputAsset.selector);
        actionFactory.migrate(address(actionContract), 2, bytes(""));
        assertEq(actionContract.version(), 1);
        assertEq(actionContract.inputAsset(), address(asset));
        assertEq(actionContract.remainingAssets(address(tokenToRedeem)), type(uint256).max);
    }

    function test_RegistryConfiguredMigrationIgnoresStoredAssetListAndOracles() public {
        MigratablesFactory legacyFactory = new MigratablesFactory(address(this));
        legacyFactory.whitelist(address(new LegacyConfiguredLiquidLaneAction(address(legacyFactory))));
        LegacyConfiguredLiquidLaneAction previous =
            LegacyConfiguredLiquidLaneAction(legacyFactory.create(1, adapterOwner, abi.encode(address(adapter))));
        previous.seed(address(asset), address(tokenToRedeem), address(priceOracle));
        ActionOracleMock fixedOracle = new ActionOracleMock(3e18);
        legacyFactory.whitelist(
            address(
                new FixedOracleLiquidLaneAction(
                    address(legacyFactory), address(asset), address(tokenToRedeem), address(fixedOracle)
                )
            )
        );
        vm.prank(adapterOwner);
        legacyFactory.migrate(address(previous), 2, bytes(""));
        LiquidLaneAction migrated = LiquidLaneAction(address(previous));
        assertEq(migrated.oracle(address(tokenToRedeem)), address(fixedOracle));
        assertEq(migrated.getAmountOut(address(tokenToRedeem), 100e18), 300e6);
        _assertBudget(migrated, vm.getBlockTimestamp());
        // Old per-instance registry data is preserved but has no authority in the new implementation.
        assertEq(
            address(
                uint160(uint256(vm.load(address(previous), keccak256(abi.encode(address(tokenToRedeem), uint256(12))))))
            ),
            address(priceOracle)
        );
    }

    function test_LegacyMigrationBackfillsFundingAssetAndIgnoresOldOracle() public {
        MigratablesFactory legacyFactory = new MigratablesFactory(address(this));
        legacyFactory.whitelist(address(new LegacyLiquidLaneCapability(address(legacyFactory))));
        LegacyLiquidLaneCapability previous =
            LegacyLiquidLaneCapability(legacyFactory.create(1, adapterOwner, abi.encode(address(adapter))));
        previous.seed(address(tokenToRedeem), address(priceOracle));
        ActionOracleMock fixedOracle = new ActionOracleMock(3e18);
        legacyFactory.whitelist(
            address(
                new FixedOracleLiquidLaneAction(
                    address(legacyFactory), address(vaultAsset), address(tokenToRedeem), address(fixedOracle)
                )
            )
        );
        vm.prank(adapterOwner);
        legacyFactory.migrate(address(previous), 2, bytes(""));
        LiquidLaneAction migrated = LiquidLaneAction(address(previous));
        assertEq(migrated.inputAsset(), address(vaultAsset));
        assertEq(migrated.adapter(), address(adapter));
        assertEq(migrated.getAmountOut(address(tokenToRedeem), 100e18), 300e18);
        assertEq(migrated.remainingAssets(address(tokenToRedeem)), 0);
        tokenToRedeem.mint(address(migrated), 100e18);
        vaultAsset.mint(address(adapter), 300e18);
        adapter.approve(address(vaultAsset), address(migrated), 300e18);
        vm.expectRevert(IAssetRateLimits.UnconfiguredAsset.selector);
        adapter.execute(address(migrated), abi.encodeCall(ILiquidLaneAction.swap, (_swap(100e18, 300e18))));
        _setLimit(migrated, address(tokenToRedeem), 300e18, 1 days);
        adapter.execute(address(migrated), abi.encodeCall(ILiquidLaneAction.swap, (_swap(100e18, 300e18))));
        assertEq(vaultAsset.balanceOf(recipient), 300e18);
        assertEq(tokenToRedeem.balanceOf(address(adapter)), 100e18);
    }

    function test_RegistryConfiguredMigrationRejectsOmittedAssetDespiteStoredBudget() public {
        MigratablesFactory legacyFactory = new MigratablesFactory(address(this));
        legacyFactory.whitelist(address(new LegacyConfiguredLiquidLaneAction(address(legacyFactory))));
        LegacyConfiguredLiquidLaneAction previous =
            LegacyConfiguredLiquidLaneAction(legacyFactory.create(1, adapterOwner, abi.encode(address(adapter))));
        previous.seed(address(asset), address(tokenToRedeem), address(priceOracle));
        legacyFactory.whitelist(
            address(
                new FixedOracleLiquidLaneAction(
                    address(legacyFactory), address(asset), address(tokenToRedeem), address(0)
                )
            )
        );
        vm.prank(adapterOwner);
        legacyFactory.migrate(address(previous), 2, bytes(""));
        LiquidLaneAction migrated = LiquidLaneAction(address(previous));
        assertEq(migrated.oracle(address(tokenToRedeem)), address(0));
        _assertBudget(migrated, vm.getBlockTimestamp());
        vm.expectRevert(ILiquidLaneAction.InvalidTokenToRedeem.selector);
        migrated.getAmountOut(address(tokenToRedeem), 100e18);
        vm.expectRevert(ILiquidLaneAction.InvalidTokenToRedeem.selector);
        _setLimit(migrated, address(tokenToRedeem), 1e6, 1 days);
        vm.expectRevert(ILiquidLaneAction.InvalidTokenToRedeem.selector);
        adapter.execute(address(migrated), abi.encodeCall(ILiquidLaneAction.swap, (_swap(100e18, 100e6))));
    }

    function test_LegacyFundingMismatchRollsBackBackfillAndImplementation() public {
        MigratablesFactory legacyFactory = new MigratablesFactory(address(this));
        legacyFactory.whitelist(address(new LegacyLiquidLaneCapability(address(legacyFactory))));
        LegacyLiquidLaneCapability previous =
            LegacyLiquidLaneCapability(legacyFactory.create(1, adapterOwner, abi.encode(address(adapter))));
        previous.seed(address(tokenToRedeem), address(priceOracle));
        legacyFactory.whitelist(
            address(
                new FixedOracleLiquidLaneAction(
                    address(legacyFactory), address(asset), address(tokenToRedeem), address(priceOracle)
                )
            )
        );
        vm.prank(adapterOwner);
        vm.expectRevert(ILiquidLaneAction.InvalidInputAsset.selector);
        legacyFactory.migrate(address(previous), 2, bytes(""));
        assertEq(previous.version(), 1);
        assertEq(previous.oracles(address(tokenToRedeem)), address(priceOracle));
        assertEq(previous.owner(), adapterOwner);
        assertEq(vm.load(address(previous), bytes32(uint256(14))), bytes32(0));
    }

    function test_RemovingAndReaddingAssetByMigrationPreservesUsage() public {
        uint256 periodStart = vm.getBlockTimestamp();
        _setLimit(actionContract, address(tokenToRedeem), 200e6, 1 days);
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(adapter), 200e6);
        adapter.approve(address(asset), address(actionContract), 200e6);
        adapter.execute(address(actionContract), abi.encodeCall(ILiquidLaneAction.swap, (_swap(50e18, 100e6))));
        _whitelist(address(asset), address(tokenToRedeem), address(0));
        _migrate(actionContract);
        assertEq(actionContract.oracle(address(tokenToRedeem)), address(0));
        vm.expectRevert(ILiquidLaneAction.InvalidTokenToRedeem.selector);
        adapter.execute(address(actionContract), abi.encodeCall(ILiquidLaneAction.swap, (_swap(50e18, 100e6))));
        vm.expectRevert(ILiquidLaneAction.InvalidTokenToRedeem.selector);
        _setLimit(actionContract, address(tokenToRedeem), 1e6, 1 days);
        _whitelist(address(asset), address(tokenToRedeem), address(priceOracle));
        _migrate(actionContract);
        _assertBudget(actionContract, periodStart);
    }

    function test_MigrateRejectsNonEmptyDataAndKeepsVersion() public {
        _whitelist(address(asset), address(tokenToRedeem), address(priceOracle));
        vm.prank(adapterOwner);
        vm.expectRevert(ILiquidLaneAction.InvalidMigrationData.selector);
        actionFactory.migrate(address(actionContract), 2, hex"01");
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
        LiquidLaneAction fresh = _createAction(address(adapter));
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
        actionFactory.whitelist(
            address(
                new TwoAssetLiquidLaneAction(
                    address(actionFactory),
                    address(asset),
                    address(tokenToRedeem),
                    address(priceOracle),
                    address(second),
                    address(priceOracle)
                )
            )
        );
        LiquidLaneAction target = _createAction(address(adapter));
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
        ActionOracleMock(actionContract.oracle(address(tokenToRedeem))).setRevertGetPrice(true);

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

    function _createAction(address adapter_) internal returns (LiquidLaneAction created) {
        created =
            LiquidLaneAction(actionFactory.create(actionFactory.lastVersion(), adapterOwner, abi.encode(adapter_)));
    }

    function _whitelist(address inputAsset_, address token, address oracle_) internal {
        actionFactory.whitelist(
            address(new FixedOracleLiquidLaneAction(address(actionFactory), inputAsset_, token, oracle_))
        );
    }

    function _migrate(LiquidLaneAction target) internal {
        uint64 version = actionFactory.lastVersion();
        vm.prank(adapterOwner);
        actionFactory.migrate(address(target), version, bytes(""));
    }

    function _assertBudget(LiquidLaneAction target, uint256 periodStart) internal view {
        (uint256 maximum, uint256 duration, uint256 start, uint256 spent) = target.assetLimits(address(tokenToRedeem));
        assertEq(maximum, 200e6);
        assertEq(duration, 1 days);
        assertEq(start, periodStart);
        assertEq(spent, 100e6);
        assertEq(target.remainingAssets(address(tokenToRedeem)), 100e6);
    }

    function _assertInvalidConfiguredToken(address token) internal {
        _whitelist(address(asset), token, address(priceOracle));
        LiquidLaneAction target = _createAction(address(adapter));
        vm.expectRevert(ILiquidLaneAction.InvalidTokenToRedeem.selector);
        target.getAmountOut(token, 1);
        vm.expectRevert(ILiquidLaneAction.InvalidTokenToRedeem.selector);
        _setLimit(target, token, 1, 1 days);
    }
}

// Storage fixtures preserve the original pre-inputAsset and registry-configured layouts.
contract LegacyLiquidLaneCapability is MigratableEntity {
    address public adapter;
    address[] public tokensToRedeem;
    mapping(address tokenToRedeem => address oracle) public oracles;
    mapping(address tokenToRedeem => bool exists) internal _isTokenToRedeem;

    constructor(address factory) MigratableEntity(factory) {}

    function seed(address token, address oracle_) public {
        tokensToRedeem.push(token);
        oracles[token] = oracle_;
        _isTokenToRedeem[token] = true;
    }

    function _initialize(uint64, address, bytes memory data) internal override {
        adapter = abi.decode(data, (address));
    }
}

contract LegacyConfiguredLiquidLaneAction is LegacyLiquidLaneCapability {
    address public inputAsset;
    mapping(address token => IAssetRateLimits.AssetLimit) public assetLimits;

    constructor(address factory) LegacyLiquidLaneCapability(factory) {}

    function seed(address asset, address token, address oracle_) external {
        super.seed(token, oracle_);
        inputAsset = asset;
        assetLimits[token] = IAssetRateLimits.AssetLimit(200e6, 1 days, block.timestamp, 100e6);
    }
}

contract ActionERC4626Vault is ERC4626 {
    constructor(IERC20 asset_) ERC20("RWA shares", "RWA") ERC4626(asset_) {}
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
