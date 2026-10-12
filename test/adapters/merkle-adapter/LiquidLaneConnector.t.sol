// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {AssetRateLimits} from "src/contracts/merkle-adapter/libraries/AssetRateLimits.sol";

import {LiquidLaneConnector} from "../../../src/contracts/merkle-adapter/connectors/LiquidLaneConnector.sol";
import {ImmutableFactory} from "../../../src/contracts/common/ImmutableFactory.sol";
import {OracleRegistry} from "../../../src/contracts/merkle-adapter/connectors/OracleRegistry.sol";

import {ILiquidLaneConnector} from "../../../src/interfaces/merkle-adapter/connectors/ILiquidLaneConnector.sol";
import {IOracleRegistry} from "../../../src/interfaces/merkle-adapter/connectors/IOracleRegistry.sol";
import {IOracle} from "../../../src/interfaces/ll-adapter/IOracle.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

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

    function testFuzz_SetOracleStoresOnlyExactPairAndEmits(address account, address token, address oracle) public {
        vm.expectEmit(true, true, true, true, address(registry));
        emit IOracleRegistry.SetOracle(account, token, oracle);
        vm.prank(owner);
        registry.setOracle(account, token, oracle);

        assertEq(registry.oracles(account, token), oracle);
        assertEq(registry.oracles(address(uint160(account) ^ 1), token), address(0));
        assertEq(registry.oracles(account, address(uint160(token) ^ 1)), address(0));
    }

    function test_SetOracleRejectsNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.setOracle(makeAddr("action"), makeAddr("rwa"), makeAddr("oracle"));
    }

    /// forge-config: default.isolate = true
    function test_SetOracleAllowsReplacementAndRevocation() public {
        address action = makeAddr("action");
        address token = makeAddr("rwa");
        address first = makeAddr("firstOracle");
        address second = makeAddr("secondOracle");
        vm.startPrank(owner);
        registry.setOracle(action, token, first);
        vm.snapshotGasLastCall("OracleRegistry", "setOracle");
        registry.setOracle(action, token, second);
        vm.snapshotGasLastCall("OracleRegistry", "replaceOracle");
        address savedOracle = registry.oracles(action, token);
        vm.snapshotGasLastCall("OracleRegistry", "oracles");
        assertEq(savedOracle, second);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IOracleRegistry.SetOracle(action, token, address(0));
        registry.setOracle(action, token, address(0));
        vm.snapshotGasLastCall("OracleRegistry", "clearOracle");
        vm.stopPrank();
        assertEq(registry.oracles(action, token), address(0));
    }
}

contract LiquidLaneConnectorTest is Test {
    ActionTokenMock internal asset;
    ActionTokenMock internal vaultAsset;
    ActionTokenMock internal tokenToRedeem;
    ActionVaultMock internal vault;
    ActionAccountMock internal account;
    OracleRegistry internal registry;
    MigratablesFactory internal actionFactory;
    ImmutableFactory internal merkleAccountFactory;
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
        merkleAccountFactory = new ImmutableFactory(type(ActionAccountMock).creationCode);
        account = ActionAccountMock(merkleAccountFactory.create(abi.encode(address(vault), adapterOwner)));
        registry = new OracleRegistry(address(this));
        actionFactory = new MigratablesFactory(address(this));
        oracleFactory = new MigratablesFactory(address(this));

        oracleFactory.whitelist(address(new ActionOracleMock(address(oracleFactory), 1e18)));
        latestOracleImplementation = new ActionOracleMock(address(oracleFactory), 2e18);
        oracleFactory.whitelist(address(latestOracleImplementation));

        actionFactory.whitelist(
            address(new LiquidLaneConnector(address(actionFactory), address(merkleAccountFactory), address(registry)))
        );
        actionContract = _createAction(address(account), address(asset), _outputs(address(tokenToRedeem)));
        _setLimit(actionContract, address(tokenToRedeem), type(uint256).max, 1 days);
    }

    function test_FactoryCreationInitializesAdapterOwnerFactoryAndVersion() public view {
        assertEq(actionContract.account(), address(account));
        assertEq(actionContract.outputAsset(), address(asset));
        assertEq(actionContract.ORACLE_REGISTRY(), address(registry));
        assertEq(actionContract.MERKLE_ACCOUNT_FACTORY(), address(merkleAccountFactory));
        assertTrue(merkleAccountFactory.isEntity(address(account)));
        assertEq(actionContract.FACTORY(), address(actionFactory));
        assertEq(actionContract.version(), actionFactory.lastVersion());
        assertEq(actionContract.owner(), adapterOwner);

        ActionOracleMock oracle = ActionOracleMock(actionContract.oracles(address(tokenToRedeem)));
        assertEq(oracleFactory.lastVersion(), 2);
        assertEq(oracle.version(), oracleFactory.lastVersion());
        assertEq(oracle.owner(), actionContract.owner());
        assertEq(oracle.outputAsset(), address(asset));
        assertEq(oracle.actionContract(), address(actionContract));
        assertEq(oracle.price(), latestOracleImplementation.price());
    }

    function test_AccountConfiguresAllOutputsAfterCreation() public {
        ActionTokenMock secondOutput = new ActionTokenMock("Second RWA", "RWA2", 8);
        address[] memory outputs = new address[](2);
        outputs[0] = address(tokenToRedeem);
        outputs[1] = address(secondOutput);

        LiquidLaneConnector secondAction = _createAction(address(account), address(asset), outputs);

        assertNotEq(secondAction.oracles(address(tokenToRedeem)), address(0));
        assertNotEq(secondAction.oracles(address(secondOutput)), address(0));
    }

    function test_InitializationRejectsZeroAccountAtomically() public {
        _expectCreateRevert(ILiquidLaneConnector.InvalidAccount.selector, address(0), address(asset));
    }

    function testFuzz_InitializationRejectsUnregisteredAccountAtomically(address unregistered) public {
        vm.assume(!merkleAccountFactory.isEntity(unregistered));
        _expectCreateRevert(ILiquidLaneConnector.InvalidAccount.selector, unregistered, address(asset));
    }

    function test_InitializationRejectsUnregisteredContractAtomically() public {
        address unregistered = address(new ActionAccountMock(address(vault), adapterOwner));
        _expectCreateRevert(ILiquidLaneConnector.InvalidAccount.selector, unregistered, address(asset));
    }

    function test_InitializationAcceptsZeroOutputAsset() public {
        LiquidLaneConnector empty = _createAction(address(account), address(0), new address[](0));
        assertEq(empty.account(), address(account));
        assertEq(empty.outputAsset(), address(0));
    }

    function test_InitializationLeavesTokensForAccountConfiguration() public {
        LiquidLaneConnector empty = _createAction(address(account), address(asset), new address[](0));
        assertEq(empty.outputAsset(), address(asset));
        assertEq(empty.oracles(address(tokenToRedeem)), address(0));
        _setLimit(empty, address(tokenToRedeem), 100e6, 1 days);
        assertEq(empty.remainingAssets(address(tokenToRedeem)), 100e6);
        registry.setOracle(address(empty), address(tokenToRedeem), address(latestOracleImplementation));
        account.execute(address(empty), abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (address(tokenToRedeem))));
        assertEq(empty.oracles(address(tokenToRedeem)), address(latestOracleImplementation));
        assertEq(empty.remainingAssets(address(tokenToRedeem)), 100e6);
    }

    function test_AccountCanConfigureMoreThanFiftyOutputs() public {
        address[] memory outputs = new address[](51);
        for (uint256 i; i < outputs.length; ++i) {
            outputs[i] = address(uint160(1000 + i));
        }

        LiquidLaneConnector largeCapability = _createAction(address(account), address(asset), outputs);
        for (uint256 i; i < outputs.length; ++i) {
            assertNotEq(largeCapability.oracles(outputs[i]), address(0));
        }
    }

    function test_MigrateRevertsWithoutChangingConfiguration() public {
        uint256 periodStart = vm.getBlockTimestamp();
        _setLimit(actionContract, address(tokenToRedeem), 200e6, 1 days);
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(account), 200e6);
        account.approve(address(asset), address(actionContract), 200e6);
        account.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(50e18, 100e6))
        );
        vm.warp(block.timestamp + 10 minutes);
        address oracle = actionContract.oracles(address(tokenToRedeem));
        actionFactory.whitelist(
            address(new LiquidLaneConnector(address(actionFactory), address(merkleAccountFactory), address(registry)))
        );
        uint64 newVersion = actionFactory.lastVersion();

        vm.prank(adapterOwner);
        vm.expectRevert(Errors.FailedCall.selector);
        actionFactory.migrate(address(actionContract), newVersion, bytes(""));

        assertEq(actionContract.version(), 1);
        assertEq(actionContract.owner(), adapterOwner);
        assertEq(actionContract.account(), address(account));
        assertEq(actionContract.outputAsset(), address(asset));
        assertEq(actionContract.oracles(address(tokenToRedeem)), oracle);
        (uint256 maximum, uint256 duration, uint256 start, uint256 spent) =
            actionContract.assetLimits(address(tokenToRedeem));
        assertEq(maximum, 200e6);
        assertEq(duration, 1 days);
        assertEq(start, periodStart);
        assertEq(spent, 100e6);
        assertEq(actionContract.remainingAssets(address(tokenToRedeem)), 100e6);
        account.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(50e18, 100e6))
        );
        assertEq(actionContract.remainingAssets(address(tokenToRedeem)), 0);
    }

    function test_MigrateRejectsNonEmptyDataAndKeepsVersion() public {
        actionFactory.whitelist(
            address(new LiquidLaneConnector(address(actionFactory), address(merkleAccountFactory), address(registry)))
        );
        uint64 newVersion = actionFactory.lastVersion();

        vm.prank(adapterOwner);
        vm.expectRevert(Errors.FailedCall.selector);
        actionFactory.migrate(address(actionContract), newVersion, hex"01");

        assertEq(actionContract.version(), 1);
    }

    function testFuzz_GetAmountOutSupportsFullWidthProducts(uint256 amountIn) public view {
        // The configured 2e18 price and 6/18 token decimals reduce the ratio to 1 / 5e11.
        assertEq(actionContract.getAmountOut(address(tokenToRedeem), amountIn), amountIn / 5e11);
        assertEq(actionContract.getAmountOut(address(tokenToRedeem), type(uint256).max), type(uint256).max / 5e11);
    }

    /// forge-config: default.isolate = true
    function test_GetAmountOutUsesExplicitOutputAssetAndTokenDecimals() public {
        uint256 amountOut = actionContract.getAmountOut(address(tokenToRedeem), 100e18);
        vm.snapshotGasLastCall("LiquidLaneConnector", "getAmountOut");
        assertEq(amountOut, 200e6);
    }

    function test_RemoveTokenDisablesSwap() public {
        vm.expectEmit(true, false, false, true, address(actionContract));
        emit ILiquidLaneConnector.RemoveTokenToRedeem(address(tokenToRedeem));
        account.execute(
            address(actionContract), abi.encodeCall(ILiquidLaneConnector.removeTokenToRedeem, (address(tokenToRedeem)))
        );

        assertEq(actionContract.oracles(address(tokenToRedeem)), address(0));
        vm.expectRevert(ILiquidLaneConnector.InvalidTokenToRedeem.selector);
        account.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(1e18, 1e6))
        );
        vm.expectRevert(ILiquidLaneConnector.InvalidTokenToRedeem.selector);
        actionContract.getAmountOut(address(tokenToRedeem), 1e18);
        _setLimit(actionContract, address(tokenToRedeem), 100e6, 1 days);
        assertEq(actionContract.remainingAssets(address(tokenToRedeem)), 100e6);
    }

    function test_AddTokenUsesItsOwnRegistryKeyAndEmits() public {
        address token = address(new ActionTokenMock("Other RWA", "RWA2", 8));
        address oracle = address(latestOracleImplementation);
        registry.setOracle(address(account), token, oracle);
        vm.expectRevert(ILiquidLaneConnector.InvalidOracle.selector);
        account.execute(address(actionContract), abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (token)));
        assertEq(actionContract.oracles(token), address(0));

        registry.setOracle(address(actionContract), token, oracle);
        vm.expectEmit(true, true, false, true, address(actionContract));
        emit ILiquidLaneConnector.AddTokenToRedeem(token, oracle);
        account.execute(address(actionContract), abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (token)));
        assertEq(actionContract.oracles(token), oracle);
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
            account.execute(
                address(actionContract), abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (invalid[i]))
            );
        }
    }

    function test_RemoveUnknownTokenRevertsWithExistingAndEmptyLists() public {
        vm.expectRevert(ILiquidLaneConnector.InvalidTokenToRedeem.selector);
        account.execute(
            address(actionContract), abi.encodeCall(ILiquidLaneConnector.removeTokenToRedeem, (address(asset)))
        );
        account.execute(
            address(actionContract), abi.encodeCall(ILiquidLaneConnector.removeTokenToRedeem, (address(tokenToRedeem)))
        );
        vm.expectRevert(ILiquidLaneConnector.InvalidTokenToRedeem.selector);
        account.execute(
            address(actionContract), abi.encodeCall(ILiquidLaneConnector.removeTokenToRedeem, (address(tokenToRedeem)))
        );
    }

    /// forge-config: default.isolate = true
    function test_RegistryReplacementRequiresRemoveAndAddToRefreshOracle() public {
        address savedOracle = actionContract.oracles(address(tokenToRedeem));
        address replacement = address(new ActionOracleMock(address(oracleFactory), 3e18));
        registry.setOracle(address(actionContract), address(tokenToRedeem), replacement);
        assertEq(actionContract.oracles(address(tokenToRedeem)), savedOracle);
        assertEq(actionContract.getAmountOut(address(tokenToRedeem), 100e18), 200e6);
        vm.expectRevert(ILiquidLaneConnector.InvalidTokenToRedeem.selector);
        account.execute(
            address(actionContract), abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (address(tokenToRedeem)))
        );

        vm.prank(address(account));
        actionContract.removeTokenToRedeem(address(tokenToRedeem));
        vm.snapshotGasLastCall("LiquidLaneConnector", "removeTokenToRedeem");
        vm.prank(address(account));
        actionContract.addTokenToRedeem(address(tokenToRedeem));
        vm.snapshotGasLastCall("LiquidLaneConnector", "addTokenToRedeem");
        assertEq(actionContract.oracles(address(tokenToRedeem)), replacement);
        assertEq(actionContract.getAmountOut(address(tokenToRedeem), 100e18), 300e6);
    }

    function test_RegistryRevocationLeavesSavedOracleActiveUntilRemoval() public {
        address savedOracle = actionContract.oracles(address(tokenToRedeem));
        registry.setOracle(address(actionContract), address(tokenToRedeem), address(0));
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(account), 200e6);
        account.approve(address(asset), address(actionContract), 200e6);
        account.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 200e6))
        );
        assertEq(asset.balanceOf(recipient), 200e6);
        assertEq(actionContract.oracles(address(tokenToRedeem)), savedOracle);

        account.execute(
            address(actionContract), abi.encodeCall(ILiquidLaneConnector.removeTokenToRedeem, (address(tokenToRedeem)))
        );
        vm.expectRevert(ILiquidLaneConnector.InvalidOracle.selector);
        account.execute(
            address(actionContract), abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (address(tokenToRedeem)))
        );
        assertEq(actionContract.oracles(address(tokenToRedeem)), address(0));
    }

    function test_OracleRefreshPreservesBudgetAndInventory() public {
        _setLimit(actionContract, address(tokenToRedeem), 200e6, 1 days);
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(account), 300e6);
        account.approve(address(asset), address(actionContract), 300e6);
        account.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(50e18, 100e6))
        );
        (uint256 maximum, uint256 duration, uint256 start, uint256 spent) =
            actionContract.assetLimits(address(tokenToRedeem));
        bytes32 budgetBefore = keccak256(abi.encode(maximum, duration, start, spent));
        registry.setOracle(
            address(actionContract), address(tokenToRedeem), address(new ActionOracleMock(address(oracleFactory), 3e18))
        );
        account.execute(
            address(actionContract), abi.encodeCall(ILiquidLaneConnector.removeTokenToRedeem, (address(tokenToRedeem)))
        );
        account.execute(
            address(actionContract), abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (address(tokenToRedeem)))
        );

        (maximum, duration, start, spent) = actionContract.assetLimits(address(tokenToRedeem));
        assertEq(keccak256(abi.encode(maximum, duration, start, spent)), budgetBefore);
        assertEq(actionContract.remainingAssets(address(tokenToRedeem)), 100e6);
        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 50e18);
        vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
        account.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(50e18, 150e6))
        );
    }

    function testFuzz_RemovalPreservesOtherOraclesAndCanReAdd(uint8 countSeed, uint8 indexSeed) public {
        uint256 count = bound(countSeed, 1, 64);
        uint256 index = bound(indexSeed, 0, count - 1);
        address[] memory outputs = new address[](count);
        for (uint256 i; i < count; ++i) {
            outputs[i] = address(uint160(1000 + i));
        }
        LiquidLaneConnector target = _createAction(address(account), address(asset), outputs);
        address token = outputs[index];
        address savedOracle = target.oracles(token);
        account.execute(address(target), abi.encodeCall(ILiquidLaneConnector.removeTokenToRedeem, (token)));
        assertEq(target.oracles(token), address(0));
        for (uint256 i; i < count; ++i) {
            if (i != index) assertNotEq(target.oracles(outputs[i]), address(0));
        }
        account.execute(address(target), abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (token)));
        assertEq(target.oracles(token), savedOracle);
    }

    function testFuzz_AccountCallbackCanChangeMembershipDuringSwap(bool adding) public {
        address newToken = makeAddr("newToken");
        registry.setOracle(address(actionContract), newToken, address(latestOracleImplementation));
        bytes memory mutation = adding
            ? abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (newToken))
            : abi.encodeCall(ILiquidLaneConnector.removeTokenToRedeem, (address(tokenToRedeem)));
        tokenToRedeem.setCallback(
            address(account), abi.encodeCall(account.execute, (address(actionContract), mutation))
        );
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(account), 200e6);
        account.approve(address(asset), address(actionContract), 200e6);
        account.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 200e6))
        );
        if (adding) {
            assertEq(actionContract.oracles(newToken), address(latestOracleImplementation));
            assertNotEq(actionContract.oracles(address(tokenToRedeem)), address(0));
        } else {
            assertEq(actionContract.oracles(newToken), address(0));
            assertEq(actionContract.oracles(address(tokenToRedeem)), address(0));
        }
        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 0);
        assertEq(tokenToRedeem.balanceOf(address(account)), 100e18);
        assertEq(asset.balanceOf(recipient), 200e6);
    }

    function test_SwapPullsOutputAssetToRecipientAndTransfersRwaToAdapter() public {
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(account), 200e6);
        account.approve(address(asset), address(actionContract), type(uint256).max);
        ILiquidLaneConnector.Swap memory swap_ = _swap(100e18, 190e6);

        vm.expectEmit(false, false, false, true, address(actionContract));
        emit ILiquidLaneConnector.DoSwap(swap_);
        account.execute(
            address(actionContract), abi.encodeWithSignature("swap((address,address,uint256,uint256))", swap_)
        );

        assertEq(asset.balanceOf(recipient), 190e6);
        assertEq(asset.balanceOf(address(account)), 10e6);
        assertEq(asset.balanceOf(address(actionContract)), 0);
        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 0);
        assertEq(tokenToRedeem.balanceOf(address(account)), 100e18);
    }

    /// forge-config: default.isolate = true
    function test_SwapsShareAssetBudgetUntilDurationEnds() public {
        _setLimit(actionContract, address(tokenToRedeem), 190e6, 1 days);
        tokenToRedeem.mint(address(actionContract), 200e18);
        asset.mint(address(account), 380e6);
        account.approve(address(asset), address(actionContract), type(uint256).max);
        vm.prank(address(account));
        actionContract.swap(_swap(50e18, 95e6));
        vm.snapshotGasLastCall("LiquidLaneConnector", "swap");
        vm.prank(address(account));
        actionContract.swap(_swap(50e18, 95e6));
        vm.snapshotGasLastCall("LiquidLaneConnector", "swapSamePeriod");
        vm.prank(address(account));
        vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
        vm.startSnapshotGas("LiquidLaneConnector", "swapBudgetExceeded");
        actionContract.swap(_swap(100e18, 190e6));
        vm.stopSnapshotGas("LiquidLaneConnector", "swapBudgetExceeded");
        assertEq(asset.balanceOf(recipient), 190e6);
        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 100e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(address(account));
        actionContract.swap(_swap(100e18, 190e6));
        vm.snapshotGasLastCall("LiquidLaneConnector", "swapRollover");
        assertEq(asset.balanceOf(recipient), 380e6);
        assertEq(tokenToRedeem.balanceOf(address(account)), 200e18);
    }

    /// forge-config: default.isolate = true
    function test_ConfigurationAndBudgetReadsGas() public {
        uint256 remaining = actionContract.remainingAssets(address(asset));
        vm.snapshotGasLastCall("LiquidLaneConnector", "remainingAssetsUnconfigured");
        assertEq(remaining, 0);
        vm.prank(address(account));
        actionContract.setMaxAssetsPerDuration(address(asset), 100e6, 1 days);
        vm.snapshotGasLastCall("LiquidLaneConnector", "setMaxAssetsPerDuration");
        vm.prank(address(account));
        actionContract.setMaxAssetsPerDuration(address(asset), 200e6, 1 days);
        vm.snapshotGasLastCall("LiquidLaneConnector", "setMaxAssetsSameDuration");
        vm.prank(address(account));
        actionContract.setMaxAssetsPerDuration(address(asset), 200e6, 2 days);
        vm.snapshotGasLastCall("LiquidLaneConnector", "setMaxAssetsNewDuration");

        (uint256 maximum, uint48 duration, uint48 start, uint256 spent) = actionContract.assetLimits(address(asset));
        assertEq(maximum, 200e6);
        assertEq(duration, 2 days);
        assertEq(start, block.timestamp);
        assertEq(spent, 0);
        remaining = actionContract.remainingAssets(address(asset));
        vm.snapshotGasLastCall("LiquidLaneConnector", "remainingAssets");
        assertEq(remaining, 200e6);
        vm.warp(block.timestamp + 2 days);
        remaining = actionContract.remainingAssets(address(asset));
        vm.snapshotGasLastCall("LiquidLaneConnector", "remainingAssetsExpired");
        assertEq(remaining, 200e6);
        vm.prank(address(account));
        actionContract.setMaxAssetsPerDuration(address(asset), 0, 2 days);
        vm.snapshotGasLastCall("LiquidLaneConnector", "setMaxAssetsDisableAfterRollover");
        assertEq(actionContract.remainingAssets(address(asset)), 0);
    }

    function test_LimitConfigurationRequiresAccountAndAllowsUnknownToken() public {
        vm.prank(adapterOwner);
        vm.expectRevert(ILiquidLaneConnector.InvalidCaller.selector);
        actionContract.setMaxAssetsPerDuration(address(tokenToRedeem), 100e6, 1 days);
        vm.expectRevert(ILiquidLaneConnector.InvalidCaller.selector);
        actionContract.setMaxAssetsPerDuration(address(tokenToRedeem), 100e6, 1 days);
        _setLimit(actionContract, address(asset), 100e6, 1 days);
        assertEq(actionContract.remainingAssets(address(asset)), 100e6);
        vm.expectRevert(AssetRateLimits.InvalidDuration.selector);
        _setLimit(actionContract, address(tokenToRedeem), 100e6, 0);
        vm.expectEmit(true, false, false, true, address(actionContract));
        emit ILiquidLaneConnector.SetMaxAssetsPerDuration(address(tokenToRedeem), 100e6, 1 days);
        _setLimit(actionContract, address(tokenToRedeem), 100e6, 1 days);
    }

    function test_UnconfiguredAssetCannotSwapDespiteInventoryAndApproval() public {
        LiquidLaneConnector fresh = _createAction(address(account), address(asset), _outputs(address(tokenToRedeem)));
        tokenToRedeem.mint(address(fresh), 100e18);
        asset.mint(address(account), 200e6);
        account.approve(address(asset), address(fresh), 200e6);
        assertEq(fresh.remainingAssets(address(tokenToRedeem)), 0);
        vm.expectRevert(AssetRateLimits.UnconfiguredAsset.selector);
        account.execute(
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
        LiquidLaneConnector target = _createAction(address(account), address(asset), outputs);
        _setLimit(target, address(tokenToRedeem), 100e6, 1 days);
        _setLimit(target, address(second), 60e6, 2 days);
        tokenToRedeem.mint(address(target), 51e18);
        second.mint(address(target), 31e8);
        asset.mint(address(account), 162e6);
        account.approve(address(asset), address(target), 162e6);
        account.execute(
            address(target), abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(50e18, 100e6))
        );
        assertEq(target.remainingAssets(address(second)), 60e6);
        account.execute(
            address(target),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(address(second), 30e8, 60e6))
        );
        assertEq(target.remainingAssets(address(tokenToRedeem)), 0);
        assertEq(target.remainingAssets(address(second)), 0);
        vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
        account.execute(
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
        asset.mint(address(account), 190e6);
        account.approve(address(asset), address(actionContract), 190e6);
        asset.setRevertTransfers(true);
        bytes memory data = abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 190e6));
        vm.expectRevert(ActionTokenMock.ForcedTransferRevert.selector);
        account.execute(address(actionContract), data);
        assertEq(actionContract.remainingAssets(address(tokenToRedeem)), 190e6);
        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 100e18);
        asset.setRevertTransfers(false);
        account.execute(address(actionContract), data);
        assertEq(actionContract.remainingAssets(address(tokenToRedeem)), 0);
        assertEq(asset.balanceOf(recipient), 190e6);
    }

    function test_AccountCallbackReconfiguresBudgetWithoutResettingUsage() public {
        _setLimit(actionContract, address(tokenToRedeem), 190e6, 1 days);
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(account), 190e6);
        account.approve(address(asset), address(actionContract), 190e6);
        tokenToRedeem.setCallback(
            address(account),
            abi.encodeCall(
                account.execute,
                (
                    address(actionContract),
                    abi.encodeCall(
                        ILiquidLaneConnector.setMaxAssetsPerDuration, (address(tokenToRedeem), 380e6, 1 days)
                    )
                )
            )
        );
        account.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 190e6))
        );
        assertEq(actionContract.remainingAssets(address(tokenToRedeem)), 190e6);
        assertEq(asset.balanceOf(recipient), 190e6);
    }

    function test_SwapTransfersOnlyAmountInRwaToAdapter() public {
        tokenToRedeem.mint(address(actionContract), 120e18);
        asset.mint(address(account), 200e6);
        account.approve(address(asset), address(actionContract), type(uint256).max);
        ILiquidLaneConnector.Swap memory swap_ = _swap(100e18, 190e6);

        account.execute(
            address(actionContract), abi.encodeWithSignature("swap((address,address,uint256,uint256))", swap_)
        );

        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 20e18);
        assertEq(tokenToRedeem.balanceOf(address(account)), 100e18);
    }

    function test_SwapPropagatesRwaTransferFailure() public {
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(account), 200e6);
        account.approve(address(asset), address(actionContract), type(uint256).max);
        tokenToRedeem.setRevertTransfers(true);

        vm.expectRevert(ActionTokenMock.ForcedTransferRevert.selector);
        account.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 190e6))
        );

        assertEq(asset.balanceOf(recipient), 0);
        assertEq(asset.balanceOf(address(account)), 200e6);
        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 100e18);
        assertEq(tokenToRedeem.balanceOf(address(account)), 0);
    }

    function test_SwapRejectsNonAdapter() public {
        vm.expectRevert(ILiquidLaneConnector.InvalidCaller.selector);
        actionContract.swap(_swap(100e18, 190e6));
    }

    function test_SwapRejectsUnknownToken() public {
        ActionTokenMock unknownToken = new ActionTokenMock("Unknown", "UNKNOWN", 18);
        vm.expectRevert(ILiquidLaneConnector.InvalidTokenToRedeem.selector);
        account.execute(
            address(actionContract),
            abi.encodeWithSignature(
                "swap((address,address,uint256,uint256))", _swap(address(unknownToken), 100e18, 190e6)
            )
        );
    }

    function test_SwapRejectsAmountInAboveRwaBalance() public {
        tokenToRedeem.mint(address(actionContract), 99e18);

        asset.mint(address(account), 200e6);
        account.approve(address(asset), address(actionContract), type(uint256).max);
        uint256 remaining = actionContract.remainingAssets(address(tokenToRedeem));

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(actionContract), uint256(99e18), uint256(100e18)
            )
        );
        account.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 190e6))
        );

        assertEq(actionContract.remainingAssets(address(tokenToRedeem)), remaining);
        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 99e18);
        assertEq(tokenToRedeem.balanceOf(address(account)), 0);
        assertEq(asset.balanceOf(address(account)), 200e6);
        assertEq(asset.balanceOf(recipient), 0);
    }

    function test_SwapRejectsAmountOutAboveOracleQuote() public {
        tokenToRedeem.mint(address(actionContract), 100e18);

        vm.expectRevert(ILiquidLaneConnector.InvalidSwapRate.selector);
        account.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 201e6))
        );
    }

    function test_FixedSwapRejectsPayoutAboveMinimumDiscount() public {
        vm.prank(adapterOwner);
        actionContract.setMinDiscount(address(tokenToRedeem), 5_000_000);
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(account), 200e6);
        account.approve(address(asset), address(actionContract), 200e6);

        vm.expectRevert(ILiquidLaneConnector.InvalidSwapRate.selector);
        account.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 190e6 + 1))
        );
        assertEq(asset.balanceOf(recipient), 0);
        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 100e18);
    }

    function testFuzz_FixedSwapAcceptsMinimumDiscountBoundary(uint256 discount) public {
        discount = bound(discount, 0, 1e8);
        vm.prank(adapterOwner);
        actionContract.setMinDiscount(address(tokenToRedeem), discount);
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(account), 200e6);
        account.approve(address(asset), address(actionContract), 200e6);

        uint256 payout = 200e6 * (1e8 - discount) / 1e8;
        account.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, payout))
        );
        assertEq(asset.balanceOf(recipient), payout);
        assertEq(tokenToRedeem.balanceOf(address(account)), 100e18);
    }

    function test_SwapPropagatesOutputAssetAllowanceFailure() public {
        tokenToRedeem.mint(address(actionContract), 100e18);
        asset.mint(address(account), 200e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(actionContract), uint256(0), uint256(190e6)
            )
        );
        account.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 190e6))
        );

        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 100e18);
        assertEq(tokenToRedeem.balanceOf(address(account)), 0);
        assertEq(asset.balanceOf(recipient), 0);
        assertEq(asset.balanceOf(address(account)), 200e6);
    }

    function test_SwapPropagatesOutputAssetBalanceFailure() public {
        tokenToRedeem.mint(address(actionContract), 100e18);
        account.approve(address(asset), address(actionContract), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(account), uint256(0), uint256(190e6)
            )
        );
        account.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 190e6))
        );

        assertEq(tokenToRedeem.balanceOf(address(actionContract)), 100e18);
        assertEq(tokenToRedeem.balanceOf(address(account)), 0);
        assertEq(asset.balanceOf(recipient), 0);
        assertEq(asset.balanceOf(address(account)), 0);
    }

    function test_SwapPropagatesOracleFailure() public {
        tokenToRedeem.mint(address(actionContract), 100e18);
        ActionOracleMock(actionContract.oracles(address(tokenToRedeem))).setRevertGetPrice(true);

        vm.expectRevert(bytes("oracle failure"));
        account.execute(
            address(actionContract),
            abi.encodeWithSignature("swap((address,address,uint256,uint256))", _swap(100e18, 190e6))
        );
    }

    function _setLimit(LiquidLaneConnector target, address token, uint256 maximum, uint48 duration) internal {
        account.execute(
            address(target), abi.encodeCall(ILiquidLaneConnector.setMaxAssetsPerDuration, (token, maximum, duration))
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

    function _createAction(address adapter_, address newOutputAsset, address[] memory outputs)
        internal
        returns (LiquidLaneConnector created)
    {
        address predicted = _predictAction(adapter_, newOutputAsset);
        _registerOracles(predicted, newOutputAsset, outputs);
        uint256 oracleCount = oracleFactory.totalEntities();
        created = LiquidLaneConnector(
            actionFactory.create(actionFactory.lastVersion(), adapterOwner, abi.encode(adapter_, newOutputAsset))
        );
        assertEq(address(created), predicted);
        assertEq(oracleFactory.totalEntities(), oracleCount);
        for (uint256 i; i < outputs.length; ++i) {
            account.execute(address(created), abi.encodeCall(ILiquidLaneConnector.addTokenToRedeem, (outputs[i])));
        }
    }

    function _expectCreateRevert(bytes4 selector, address adapter_, address newOutputAsset) internal {
        uint256 capabilityEntities = actionFactory.totalEntities();
        uint256 oracleEntities = oracleFactory.totalEntities();
        uint64 version = actionFactory.lastVersion();
        vm.expectRevert(selector);
        actionFactory.create(version, adapterOwner, abi.encode(adapter_, newOutputAsset));
        assertEq(actionFactory.totalEntities(), capabilityEntities);
        assertEq(oracleFactory.totalEntities(), oracleEntities);
    }

    function _predictAction(address adapter_, address newOutputAsset) internal view returns (address) {
        uint64 version = actionFactory.lastVersion();
        bytes32 salt = keccak256(
            abi.encode(actionFactory.totalEntities(), version, adapterOwner, abi.encode(adapter_, newOutputAsset))
        );
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(MigratableEntityProxy).creationCode, abi.encode(actionFactory.implementation(version), bytes(""))
            )
        );
        return vm.computeCreate2Address(salt, initCodeHash, address(actionFactory));
    }

    function _registerOracles(address action, address newOutputAsset, address[] memory outputs) internal {
        for (uint256 i; i < outputs.length; ++i) {
            address oracle =
                oracleFactory.create(oracleFactory.lastVersion(), adapterOwner, abi.encode(newOutputAsset, action));
            registry.setOracle(action, outputs[i], oracle);
        }
    }

    function _outputs(address output) internal pure returns (address[] memory outputs) {
        outputs = new address[](1);
        outputs[0] = output;
    }
}

contract ActionAccountMock {
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
    address public outputAsset;
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
        (outputAsset, actionContract) = abi.decode(data, (address, address));
    }
}
