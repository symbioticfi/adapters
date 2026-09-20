// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {LiquidLaneConnector} from "../../../src/contracts/merkle-adapter/connectors/LiquidLaneConnector.sol";
import {OracleRegistry} from "../../../src/contracts/merkle-adapter/oracle/OracleRegistry.sol";

import {IAssetRateLimits} from "../../../src/interfaces/merkle-adapter/IAssetRateLimits.sol";
import {ILiquidLaneConnector} from "../../../src/interfaces/merkle-adapter/connectors/ILiquidLaneConnector.sol";
import {IOracleRegistry} from "../../../src/interfaces/merkle-adapter/oracle/IOracleRegistry.sol";
import {IOracle} from "../../../src/interfaces/ll-adapter/IOracle.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {MigratableEntityProxy} from "@symbioticfi/core/src/contracts/common/MigratableEntityProxy.sol";
import {MigratableEntity} from "@symbioticfi/core/src/contracts/common/MigratableEntity.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

contract OracleRegistryTest is Test {
    OracleRegistry internal registry;
    address internal owner = makeAddr("owner");

    function setUp() public {
        registry = new OracleRegistry(owner);
    }

    function testFuzz_SetOracleStoresOnlyExactPairAndEmits(address adapter, address token, address oracle) public {
        vm.expectEmit(true, true, true, true, address(registry));
        emit IOracleRegistry.SetOracle(adapter, token, oracle);
        vm.prank(owner);
        registry.setOracle(adapter, token, oracle);

        assertEq(registry.oracles(adapter, token), oracle);
        assertEq(registry.oracles(address(uint160(adapter) ^ 1), token), address(0));
        assertEq(registry.oracles(adapter, address(uint160(token) ^ 1)), address(0));
    }

    function test_SetOracleRejectsNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.setOracle(makeAddr("action"), makeAddr("rwa"), makeAddr("oracle"));
    }

    function test_SetOracleAllowsReplacementAndRevocation() public {
        address action = makeAddr("action");
        address token = makeAddr("rwa");
        address first = makeAddr("firstOracle");
        address second = makeAddr("secondOracle");
        vm.startPrank(owner);
        registry.setOracle(action, token, first);
        registry.setOracle(action, token, second);
        assertEq(registry.oracles(action, token), second);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IOracleRegistry.SetOracle(action, token, address(0));
        registry.setOracle(action, token, address(0));
        vm.stopPrank();
        assertEq(registry.oracles(action, token), address(0));
    }
}

contract LiquidLaneConnectorTest is Test {
    ActionTokenMock internal asset;
    ActionTokenMock internal vaultAsset;
    ActionTokenMock internal tokenToRedeem;
    ActionVaultMock internal vault;
    ActionAdapterMock internal adapter;
    OracleRegistry internal registry;
    MigratablesFactory internal actionFactory;
    MigratablesFactory internal oracleFactory;
    ActionOracleMock internal latestOracleImplementation;
    LiquidLaneConnector internal actionContract;

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

        actionFactory.whitelist(address(new LiquidLaneConnector(address(actionFactory), address(registry))));
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
        address[] memory outputs = new address[](2);
        outputs[0] = address(tokenToRedeem);
        outputs[1] = address(secondOutput);

        LiquidLaneConnector secondAction = _createAction(address(adapter), address(asset), outputs);

        assertEq(secondAction.getTokensToRedeemLength(), 2);
        assertEq(secondAction.tokensToRedeem(0), address(tokenToRedeem));
        assertEq(secondAction.tokensToRedeem(1), address(secondOutput));
        assertNotEq(secondAction.oracles(address(tokenToRedeem)), address(0));
        assertNotEq(secondAction.oracles(address(secondOutput)), address(0));
    }

    function test_InitializationRejectsZeroAdapterAtomically() public {
        _expectCreateRevert(
            ILiquidLaneConnector.InvalidAdapter.selector, address(0), address(asset), _outputs(address(tokenToRedeem))
        );
    }

    function test_InitializationRejectsZeroInputAssetAtomically() public {
        _expectCreateRevert(
            ILiquidLaneConnector.InvalidInputAsset.selector,
            address(adapter),
            address(0),
            _outputs(address(tokenToRedeem))
        );
    }

    function test_InitializationAllowsEmptyOutputsForLaterConfiguration() public {
        LiquidLaneConnector empty = _createAction(address(adapter), address(asset), new address[](0));
        assertEq(empty.getTokensToRedeemLength(), 0);
        assertEq(empty.inputAsset(), address(asset));
        registry.setOracle(address(empty), address(tokenToRedeem), address(latestOracleImplementation));
        adapter.execute(address(empty), abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (address(tokenToRedeem))));
        assertEq(empty.getTokensToRedeemLength(), 1);
        assertEq(empty.oracles(address(tokenToRedeem)), address(latestOracleImplementation));
    }

    function test_InitializationRejectsZeroOutputAtomically() public {
        _expectCreateRevert(
            ILiquidLaneConnector.InvalidTokenToRedeem.selector, address(adapter), address(asset), _outputs(address(0))
        );
    }

    function test_InitializationRejectsInputAsOutputAtomically() public {
        _expectCreateRevert(
            ILiquidLaneConnector.InvalidTokenToRedeem.selector,
            address(adapter),
            address(asset),
            _outputs(address(asset))
        );
    }

    function test_InitializationRejectsDuplicateOutputAtomically() public {
        address[] memory outputs = new address[](2);
        outputs[0] = address(tokenToRedeem);
        outputs[1] = address(tokenToRedeem);

        _expectCreateRevert(
            ILiquidLaneConnector.InvalidTokenToRedeem.selector, address(adapter), address(asset), outputs
        );
    }

    function test_InitializationRejectsMissingOracleAtomically() public {
        ActionTokenMock unknownToken = new ActionTokenMock("Unknown", "UNKNOWN", 18);
        _expectCreateRevert(
            ILiquidLaneConnector.InvalidOracle.selector,
            address(adapter),
            address(asset),
            _outputs(address(unknownToken))
        );
    }

    function test_InitializationAllowsMoreThanFiftyOutputs() public {
        address[] memory outputs = new address[](51);
        for (uint256 i; i < outputs.length; ++i) {
            outputs[i] = address(uint160(1000 + i));
        }

        LiquidLaneConnector largeCapability = _createAction(address(adapter), address(asset), outputs);

        assertEq(largeCapability.getTokensToRedeemLength(), outputs.length);
        assertEq(largeCapability.tokensToRedeem(outputs.length - 1), outputs[outputs.length - 1]);
    }

    function test_MigratePreservesConfiguration() public {
        uint256 periodStart = vm.getBlockTimestamp();
        _setLimit(actionContract, address(tokenToRedeem), 200e6, 1 days);
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(adapter), 200e6);
        adapter.approve(address(asset), address(actionContract), 200e6);
        adapter.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(50e18, 100e6))
        );
        vm.warp(block.timestamp + 10 minutes);
        address oracle = actionContract.oracles(address(tokenToRedeem));
        actionFactory.whitelist(address(new LiquidLaneConnector(address(actionFactory), address(registry))));
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
        adapter.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(50e18, 100e6))
        );
        assertEq(actionContract.remainingAssets(address(tokenToRedeem)), 0);
    }

    function test_MigrateRejectsNonEmptyDataAndKeepsVersion() public {
        actionFactory.whitelist(address(new LiquidLaneConnector(address(actionFactory), address(registry))));
        uint64 newVersion = actionFactory.lastVersion();

        vm.prank(adapterOwner);
        vm.expectRevert(ILiquidLaneConnector.InvalidMigrationData.selector);
        actionFactory.migrate(address(actionContract), newVersion, hex"01");

        assertEq(actionContract.version(), 1);
    }

    function test_GetAmountOutUsesExplicitInputAssetAndTokenDecimals() public view {
        assertEq(actionContract.getAmountOut(address(tokenToRedeem), 100e18), 200e6);
    }

    function test_RemoveTokenDisablesSwap() public {
        vm.expectEmit(true, false, false, true, address(actionContract));
        emit ILiquidLaneConnector.RemoveTokenToRedeem(address(tokenToRedeem));
        adapter.execute(
            address(actionContract), abi.encodeCall(ILiquidLaneConnector.removeTokenToRedeem, (address(tokenToRedeem)))
        );

        assertEq(actionContract.oracles(address(tokenToRedeem)), address(0));
        assertEq(actionContract.getTokensToRedeemLength(), 0);
        vm.expectRevert(ILiquidLaneConnector.InvalidTokenToRedeem.selector);
        adapter.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(1e18, 1e6))
        );
        vm.expectRevert(ILiquidLaneConnector.InvalidTokenToRedeem.selector);
        actionContract.getAmountOut(address(tokenToRedeem), 1e18);
        vm.expectRevert(ILiquidLaneConnector.InvalidTokenToRedeem.selector);
        _setLimit(actionContract, address(tokenToRedeem), 100e6, 1 days);
    }

    function test_AddTokenUsesItsOwnRegistryKeyAndEmits() public {
        address token = address(new ActionTokenMock("Other RWA", "RWA2", 8));
        address oracle = address(latestOracleImplementation);
        registry.setOracle(address(adapter), token, oracle);
        vm.expectRevert(ILiquidLaneConnector.InvalidOracle.selector);
        adapter.execute(address(actionContract), abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (token)));
        assertEq(actionContract.getTokensToRedeemLength(), 1);
        assertEq(actionContract.oracles(token), address(0));

        registry.setOracle(address(actionContract), token, oracle);
        vm.expectEmit(true, true, false, true, address(actionContract));
        emit ILiquidLaneConnector.AddTokenToRedeem(token, oracle);
        adapter.execute(address(actionContract), abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (token)));
        assertEq(actionContract.oracles(token), oracle);
        assertEq(actionContract.tokensToRedeem(1), token);
        assertEq(actionContract.remainingAssets(token), 0);
        assertEq(actionContract.getAmountOut(token, 100e8), 200e6);
    }

    function test_TokenConfigurationRequiresAdapter() public {
        vm.startPrank(adapterOwner);
        vm.expectRevert(ILiquidLaneConnector.InvalidCaller.selector);
        actionContract.addTokenToRedeem(address(tokenToRedeem));
        vm.expectRevert(ILiquidLaneConnector.InvalidCaller.selector);
        actionContract.removeTokenToRedeem(address(tokenToRedeem));
        vm.stopPrank();
        vm.expectRevert(ILiquidLaneConnector.InvalidCaller.selector);
        actionContract.addTokenToRedeem(address(tokenToRedeem));
        vm.expectRevert(ILiquidLaneConnector.InvalidCaller.selector);
        actionContract.removeTokenToRedeem(address(tokenToRedeem));
    }

    function test_AddTokenRejectsZeroFundingAssetAndDuplicate() public {
        address[3] memory invalid = [address(0), address(asset), address(tokenToRedeem)];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(ILiquidLaneConnector.InvalidTokenToRedeem.selector);
            adapter.execute(
                address(actionContract), abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (invalid[i]))
            );
        }
    }

    function test_RemoveUnknownTokenRevertsWithExistingAndEmptyLists() public {
        vm.expectRevert(ILiquidLaneConnector.InvalidTokenToRedeem.selector);
        adapter.execute(
            address(actionContract), abi.encodeCall(ILiquidLaneConnector.removeTokenToRedeem, (address(asset)))
        );
        adapter.execute(
            address(actionContract), abi.encodeCall(ILiquidLaneConnector.removeTokenToRedeem, (address(tokenToRedeem)))
        );
        vm.expectRevert(ILiquidLaneConnector.InvalidTokenToRedeem.selector);
        adapter.execute(
            address(actionContract), abi.encodeCall(ILiquidLaneConnector.removeTokenToRedeem, (address(tokenToRedeem)))
        );
    }

    function test_RegistryReplacementRequiresRemoveAndAddToRefreshOracle() public {
        address savedOracle = actionContract.oracles(address(tokenToRedeem));
        address replacement = address(new ActionOracleMock(address(oracleFactory), 3e18));
        registry.setOracle(address(actionContract), address(tokenToRedeem), replacement);
        assertEq(actionContract.oracles(address(tokenToRedeem)), savedOracle);
        assertEq(actionContract.getAmountOut(address(tokenToRedeem), 100e18), 200e6);
        vm.expectRevert(ILiquidLaneConnector.InvalidTokenToRedeem.selector);
        adapter.execute(
            address(actionContract), abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (address(tokenToRedeem)))
        );

        adapter.execute(
            address(actionContract), abi.encodeCall(ILiquidLaneConnector.removeTokenToRedeem, (address(tokenToRedeem)))
        );
        adapter.execute(
            address(actionContract), abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (address(tokenToRedeem)))
        );
        assertEq(actionContract.oracles(address(tokenToRedeem)), replacement);
        assertEq(actionContract.getAmountOut(address(tokenToRedeem), 100e18), 300e6);
    }

    function test_RegistryRevocationLeavesSavedOracleActiveUntilRemoval() public {
        address savedOracle = actionContract.oracles(address(tokenToRedeem));
        registry.setOracle(address(actionContract), address(tokenToRedeem), address(0));
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(adapter), 200e6);
        adapter.approve(address(asset), address(actionContract), 200e6);
        adapter.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 200e6))
        );
        assertEq(asset.balanceOf(recipient), 200e6);
        assertEq(actionContract.oracles(address(tokenToRedeem)), savedOracle);

        adapter.execute(
            address(actionContract), abi.encodeCall(ILiquidLaneConnector.removeTokenToRedeem, (address(tokenToRedeem)))
        );
        vm.expectRevert(ILiquidLaneConnector.InvalidOracle.selector);
        adapter.execute(
            address(actionContract), abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (address(tokenToRedeem)))
        );
        assertEq(actionContract.oracles(address(tokenToRedeem)), address(0));
        assertEq(actionContract.getTokensToRedeemLength(), 0);
    }

    function test_OracleRefreshPreservesBudgetAndInventory() public {
        _setLimit(actionContract, address(tokenToRedeem), 200e6, 1 days);
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(adapter), 300e6);
        adapter.approve(address(asset), address(actionContract), 300e6);
        adapter.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(50e18, 100e6))
        );
        (uint256 maximum, uint256 duration, uint256 start, uint256 spent) =
            actionContract.assetLimits(address(tokenToRedeem));
        bytes32 budgetBefore = keccak256(abi.encode(maximum, duration, start, spent));
        registry.setOracle(
            address(actionContract), address(tokenToRedeem), address(new ActionOracleMock(address(oracleFactory), 3e18))
        );
        adapter.execute(
            address(actionContract), abi.encodeCall(ILiquidLaneConnector.removeTokenToRedeem, (address(tokenToRedeem)))
        );
        adapter.execute(
            address(actionContract), abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (address(tokenToRedeem)))
        );

        (maximum, duration, start, spent) = actionContract.assetLimits(address(tokenToRedeem));
        assertEq(keccak256(abi.encode(maximum, duration, start, spent)), budgetBefore);
        assertEq(actionContract.remainingAssets(address(tokenToRedeem)), 100e6);
        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 50e18);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        adapter.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(50e18, 150e6))
        );
    }

    function testFuzz_RemovalMaintainsEnumerationAndCanReAdd(uint8 countSeed, uint8 indexSeed) public {
        uint256 count = bound(countSeed, 1, 64);
        uint256 index = bound(indexSeed, 0, count - 1);
        address[] memory outputs = new address[](count);
        for (uint256 i; i < count; ++i) {
            outputs[i] = address(uint160(1000 + i));
        }
        LiquidLaneConnector target = _createAction(address(adapter), address(asset), outputs);
        address token = outputs[index];
        address savedOracle = target.oracles(token);
        adapter.execute(address(target), abi.encodeCall(ILiquidLaneConnector.removeTokenToRedeem, (token)));
        assertEq(target.getTokensToRedeemLength(), count - 1);
        assertEq(target.oracles(token), address(0));
        for (uint256 i; i < count - 1; ++i) {
            address expected = i == index ? outputs[count - 1] : outputs[i];
            assertEq(target.tokensToRedeem(i), expected);
            assertNotEq(target.oracles(expected), address(0));
        }
        adapter.execute(address(target), abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (token)));
        assertEq(target.getTokensToRedeemLength(), count);
        assertEq(target.tokensToRedeem(count - 1), token);
        assertEq(target.oracles(token), savedOracle);
    }

    function testFuzz_TokenCallbackCannotChangeTokenListDuringSwap(bool adding) public {
        address newToken = makeAddr("newToken");
        registry.setOracle(address(actionContract), newToken, address(latestOracleImplementation));
        bytes memory mutation = adding
            ? abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (newToken))
            : abi.encodeCall(ILiquidLaneConnector.removeTokenToRedeem, (address(tokenToRedeem)));
        tokenToRedeem.setCallback(
            address(adapter), abi.encodeCall(adapter.execute, (address(actionContract), mutation))
        );
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(adapter), 200e6);
        adapter.approve(address(asset), address(actionContract), 200e6);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        adapter.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 200e6))
        );
        assertEq(actionContract.getTokensToRedeemLength(), 1);
        assertEq(actionContract.oracles(newToken), address(0));
        assertNotEq(actionContract.oracles(address(tokenToRedeem)), address(0));
        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 100e18);
        assertEq(asset.balanceOf(recipient), 0);
    }

    function test_SwapPullsInputAssetToRecipientAndTransfersRwaToAdapter() public {
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(adapter), 200e6);
        adapter.approve(address(asset), address(actionContract), type(uint256).max);
        ILiquidLaneConnector.Swap memory swap_ = _swap(100e18, 190e6);

        vm.expectEmit(false, false, false, true, address(actionContract));
        emit ILiquidLaneConnector.DoSwap(swap_);
        adapter.execute(
            address(actionContract), abi.encodeWithSignature("swap((address,address,uint256,uint256))", swap_)
        );

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
        bytes memory data = abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 190e6));

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
        vm.expectRevert(ILiquidLaneConnector.InvalidCaller.selector);
        actionContract.setMaxAssetsPerDuration(address(tokenToRedeem), 100e6, 1 days);
        vm.expectRevert(ILiquidLaneConnector.InvalidCaller.selector);
        actionContract.setMaxAssetsPerDuration(address(tokenToRedeem), 100e6, 1 days);
        vm.expectRevert(ILiquidLaneConnector.InvalidTokenToRedeem.selector);
        _setLimit(actionContract, address(asset), 100e6, 1 days);
        vm.expectRevert(IAssetRateLimits.InvalidDuration.selector);
        _setLimit(actionContract, address(tokenToRedeem), 100e6, 0);
        vm.expectEmit(true, false, false, true, address(actionContract));
        emit IAssetRateLimits.SetMaxAssetsPerDuration(address(tokenToRedeem), 100e6, 1 days);
        _setLimit(actionContract, address(tokenToRedeem), 100e6, 1 days);
    }

    function test_UnconfiguredAssetCannotSwapDespiteInventoryAndApproval() public {
        LiquidLaneConnector fresh = _createAction(address(adapter), address(asset), _outputs(address(tokenToRedeem)));
        tokenToRedeem.mint(address(fresh), 100e18);
        asset.mint(address(adapter), 200e6);
        adapter.approve(address(asset), address(fresh), 200e6);
        assertEq(fresh.remainingAssets(address(tokenToRedeem)), 0);
        vm.expectRevert(IAssetRateLimits.UnconfiguredAsset.selector);
        adapter.execute(
            address(fresh), abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 190e6))
        );
        assertEq(asset.balanceOf(recipient), 0);
        assertEq(tokenToRedeem.balanceOf(address(fresh)), 100e18);
    }

    function test_TokenBudgetsAreIndependentAndUseFundingAssetUnits() public {
        ActionTokenMock second = new ActionTokenMock("Second", "RWA2", 8);
        address[] memory outputs = new address[](2);
        outputs[0] = address(tokenToRedeem);
        outputs[1] = address(second);
        LiquidLaneConnector target = _createAction(address(adapter), address(asset), outputs);
        _setLimit(target, address(tokenToRedeem), 100e6, 1 days);
        _setLimit(target, address(second), 60e6, 2 days);
        tokenToRedeem.mint(address(target), 51e18);
        second.mint(address(target), 31e8);
        asset.mint(address(adapter), 162e6);
        adapter.approve(address(asset), address(target), 162e6);
        adapter.execute(
            address(target), abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(50e18, 100e6))
        );
        assertEq(target.remainingAssets(address(second)), 60e6);
        adapter.execute(
            address(target),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(address(second), 30e8, 60e6))
        );
        assertEq(target.remainingAssets(address(tokenToRedeem)), 0);
        assertEq(target.remainingAssets(address(second)), 0);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        adapter.execute(
            address(target),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(address(second), 1e8, 1e6))
        );
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
        bytes memory data = abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 190e6));
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
        adapter.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 190e6))
        );
        assertEq(actionContract.remainingAssets(address(tokenToRedeem)), 190e6);
        assertEq(asset.balanceOf(recipient), 0);
    }

    function test_SwapTransfersOnlyAmountInRwaToAdapter() public {
        tokenToRedeem.mint(address(actionContract), 120e18);
        asset.mint(address(adapter), 200e6);
        adapter.approve(address(asset), address(actionContract), type(uint256).max);
        ILiquidLaneConnector.Swap memory swap_ = _swap(100e18, 190e6);

        adapter.execute(
            address(actionContract), abi.encodeWithSignature("swap((address,address,uint256,uint256))", swap_)
        );

        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 20e18);
        assertEq(tokenToRedeem.balanceOf(address(adapter)), 100e18);
    }

    function test_SwapPropagatesOutputAssetTransferFailure() public {
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(adapter), 200e6);
        adapter.approve(address(asset), address(actionContract), type(uint256).max);
        tokenToRedeem.setRevertTransfers(true);

        vm.expectRevert(ActionTokenMock.ForcedTransferRevert.selector);
        adapter.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 190e6))
        );

        assertEq(asset.balanceOf(recipient), 0);
        assertEq(asset.balanceOf(address(adapter)), 200e6);
        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 100e18);
        assertEq(tokenToRedeem.balanceOf(address(adapter)), 0);
    }

    function test_SwapRejectsNonAdapter() public {
        vm.expectRevert(ILiquidLaneConnector.InvalidCaller.selector);
        actionContract.swap(_swap(100e18, 190e6));
    }

    function test_SwapRejectsUnknownToken() public {
        ActionTokenMock unknownToken = new ActionTokenMock("Unknown", "UNKNOWN", 18);
        vm.expectRevert(ILiquidLaneConnector.InvalidTokenToRedeem.selector);
        adapter.execute(
            address(actionContract),
            abi.encodeWithSignature(
                "swap((address,address,uint256,uint256))", _swap(address(unknownToken), 100e18, 190e6)
            )
        );
    }

    function test_SwapRejectsAmountInAboveRwaBalance() public {
        tokenToRedeem.mint(address(actionContract), 99e18);

        asset.mint(address(adapter), 200e6);
        adapter.approve(address(asset), address(actionContract), type(uint256).max);
        uint256 remaining = actionContract.remainingAssets(address(tokenToRedeem));

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(actionContract), uint256(99e18), uint256(100e18)
            )
        );
        adapter.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 190e6))
        );

        assertEq(actionContract.remainingAssets(address(tokenToRedeem)), remaining);
        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 99e18);
        assertEq(tokenToRedeem.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(address(adapter)), 200e6);
        assertEq(asset.balanceOf(recipient), 0);
    }

    function test_SwapRejectsAmountOutAboveOracleQuote() public {
        tokenToRedeem.mint(address(actionContract), 100e18);

        vm.expectRevert(ILiquidLaneConnector.InvalidSwapRate.selector);
        adapter.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 201e6))
        );
    }

    function test_SwapPropagatesInputAssetAllowanceFailure() public {
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(adapter), 200e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(actionContract), uint256(0), uint256(190e6)
            )
        );
        adapter.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 190e6))
        );

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
        adapter.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 190e6))
        );

        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 100e18);
        assertEq(tokenToRedeem.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(recipient), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
    }

    function test_SwapPropagatesOracleFailure() public {
        tokenToRedeem.mint(address(actionContract), 100e18);
        ActionOracleMock(actionContract.oracles(address(tokenToRedeem))).setRevertGetPrice(true);

        vm.expectRevert(bytes("oracle failure"));
        adapter.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 190e6))
        );
    }

    function _setLimit(LiquidLaneConnector target, address token, uint256 maximum, uint256 duration) internal {
        adapter.execute(
            address(target), abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (token, maximum, duration))
        );
    }

    function _swap(uint256 amountIn, uint256 amountOut) internal view returns (ILiquidLaneConnector.Swap memory swap_) {
        swap_ = _swap(address(tokenToRedeem), amountIn, amountOut);
    }

    function _swap(address output, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (ILiquidLaneConnector.Swap memory swap_)
    {
        swap_ = ILiquidLaneConnector.Swap({
            recipient: recipient, tokenIn: output, amountIn: amountIn, amountOut: amountOut
        });
    }

    function _createAction(address adapter_, address inputAsset_, address[] memory outputs)
        internal
        returns (LiquidLaneConnector created)
    {
        address predicted = _predictAction(adapter_, inputAsset_, outputs);
        _registerOracles(predicted, inputAsset_, outputs);
        uint256 oracleCount = oracleFactory.totalEntities();
        created = LiquidLaneConnector(
            actionFactory.create(actionFactory.lastVersion(), adapterOwner, abi.encode(adapter_, inputAsset_, outputs))
        );
        assertEq(address(created), predicted);
        assertEq(oracleFactory.totalEntities(), oracleCount);
    }

    function _expectCreateRevert(bytes4 selector, address adapter_, address inputAsset_, address[] memory outputs)
        internal
    {
        if (selector != ILiquidLaneConnector.InvalidOracle.selector) {
            _registerOracles(_predictAction(adapter_, inputAsset_, outputs), inputAsset_, outputs);
        }
        uint256 capabilityEntities = actionFactory.totalEntities();
        uint256 oracleEntities = oracleFactory.totalEntities();
        uint64 version = actionFactory.lastVersion();
        vm.expectRevert(selector);
        actionFactory.create(version, adapterOwner, abi.encode(adapter_, inputAsset_, outputs));
        assertEq(actionFactory.totalEntities(), capabilityEntities);
        assertEq(oracleFactory.totalEntities(), oracleEntities);
    }

    function _predictAction(address adapter_, address inputAsset_, address[] memory outputs)
        internal
        view
        returns (address)
    {
        uint64 version = actionFactory.lastVersion();
        bytes32 salt = keccak256(
            abi.encode(actionFactory.totalEntities(), version, adapterOwner, abi.encode(adapter_, inputAsset_, outputs))
        );
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(MigratableEntityProxy).creationCode, abi.encode(actionFactory.implementation(version), bytes(""))
            )
        );
        return vm.computeCreate2Address(salt, initCodeHash, address(actionFactory));
    }

    function _registerOracles(address action, address inputAsset_, address[] memory outputs) internal {
        for (uint256 i; i < outputs.length; ++i) {
            address oracle =
                oracleFactory.create(oracleFactory.lastVersion(), adapterOwner, abi.encode(inputAsset_, action));
            registry.setOracle(action, outputs[i], oracle);
        }
    }

    function _outputs(address output) internal pure returns (address[] memory outputs) {
        outputs = new address[](1);
        outputs[0] = output;
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
