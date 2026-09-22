// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {AssetRateLimits} from "src/contracts/merkle-adapter/libraries/AssetRateLimits.sol";

import {ThreeFPolicy} from "src/contracts/merkle-adapter/automations/policies/ThreeFPolicy.sol";

import {IThreeFPolicy} from "src/interfaces/merkle-adapter/automations/policies/IThreeFPolicy.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";
import {IMigratablesFactory} from "@symbioticfi/core/src/interfaces/common/IMigratablesFactory.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

import {createThreeFPolicyFactory} from "test/helpers/ThreeFPolicyFactory.sol";

contract ThreeFPolicyTest is Test {
    MigratablesFactory internal _factory;
    address internal _policy;
    address internal _executor = makeAddr("executor");
    address internal _account = makeAddr("account");
    address internal _asset = makeAddr("asset");
    address internal _other = makeAddr("other");

    function setUp() public {
        _factory = MigratablesFactory(createThreeFPolicyFactory(address(this)));
        _policy = _factory.create(_factory.lastVersion(), address(this), abi.encode(_executor));
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_asset, 1000, 1 days);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_asset, 10_000);
    }

    function test_MulticallConfiguresPolicyAndPreservesOwner() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IThreeFPolicy.setMinYieldPerRequest, (_asset, 20_000));
        calls[1] = abi.encodeCall(IThreeFPolicy.setMaxAssetsPerDuration, (_asset, 2000, 2 days));
        ThreeFPolicy(_policy).multicall(calls);
        assertEq(ThreeFPolicy(_policy).minYieldPerRequest(_asset), 20_000);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 2000);
        vm.prank(_executor);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, _executor));
        ThreeFPolicy(_policy).multicall(calls);
    }

    function test_MulticallConsumesAsExecutorAndRollsBackExceededBudget() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IThreeFPolicy.consume, (_asset, 400, 4));
        calls[1] = abi.encodeCall(IThreeFPolicy.consume, (_asset, 700, 7));
        vm.prank(_executor);
        vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
        ThreeFPolicy(_policy).multicall(calls);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 1000);
        calls[1] = abi.encodeCall(IThreeFPolicy.consume, (_asset, 600, 6));
        vm.prank(_executor);
        ThreeFPolicy(_policy).multicall(calls);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 0);
    }

    function test_OnlyOwnerCanChangePolicy() public {
        vm.startPrank(_executor);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, _executor));
        ThreeFPolicy(_policy).setMinYieldPerRequest(_asset, 0);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, _executor));
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_asset, 10_000, 1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, _executor));
        ThreeFPolicy(_policy).setConsumer(_other);
        vm.stopPrank();
    }

    function test_OnlyTheCurrentConsumerCanConsume() public {
        assertEq(ThreeFPolicy(_policy).consumer(), _executor);
        vm.prank(_other);
        vm.expectRevert(IThreeFPolicy.InvalidCaller.selector);
        ThreeFPolicy(_policy).consume(_asset, 100, 1);
        vm.prank(_executor);
        ThreeFPolicy(_policy).consume(_asset, 100, 1);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 900);
    }

    /// @dev The curator's migration: meter one automation, then meter every path through the account.
    function test_RepointingConsumerCarriesUsageAndClosesTheOldPath() public {
        vm.prank(_executor);
        ThreeFPolicy(_policy).consume(_asset, 600, 6);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 400);

        ThreeFPolicy(_policy).setConsumer(_account);

        vm.prank(_executor);
        vm.expectRevert(IThreeFPolicy.InvalidCaller.selector);
        ThreeFPolicy(_policy).consume(_asset, 1, 1);
        // The new consumer inherits the period rather than receiving a fresh budget.
        vm.prank(_account);
        vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
        ThreeFPolicy(_policy).consume(_asset, 500, 5);
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(_asset, 400, 4);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 0);
    }

    function test_ZeroConsumerDisablesConsumption() public {
        ThreeFPolicy(_policy).setConsumer(address(0));
        vm.prank(_executor);
        vm.expectRevert(IThreeFPolicy.InvalidCaller.selector);
        ThreeFPolicy(_policy).consume(_asset, 1, 1);
    }

    function test_ZeroPrincipalRevertsInsteadOfDividing() public {
        vm.prank(_executor);
        vm.expectRevert(IThreeFPolicy.InvalidAssets.selector);
        ThreeFPolicy(_policy).consume(_asset, 0, 0);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_asset, 0);
        vm.prank(_executor);
        vm.expectRevert(IThreeFPolicy.InvalidAssets.selector);
        ThreeFPolicy(_policy).consume(_asset, 0, 1);
    }

    function test_ReconfigurationPreservesSpentAcrossDurationAndBudgetChanges() public {
        vm.prank(_executor);
        ThreeFPolicy(_policy).consume(_asset, 100, 1);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_asset, 200, 2 days);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 100);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_asset, 0, 2 days);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 0);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_asset, 200, 2 days);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 100);
    }

    function test_CurrentMinimumAppliesImmediatelyAndDoesNotResetUsage() public {
        vm.prank(_executor);
        ThreeFPolicy(_policy).consume(_asset, 100, 1);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_asset, 20_000);
        vm.prank(_executor);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        ThreeFPolicy(_policy).consume(_asset, 100, 1);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 900);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_asset, 0);
        vm.prank(_executor);
        ThreeFPolicy(_policy).consume(_asset, 100, 0);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 800);
    }

    function test_PeriodRollsWithoutAccumulatingUnusedCapacity() public {
        vm.prank(_executor);
        ThreeFPolicy(_policy).consume(_asset, 1000, 10);
        vm.prank(_executor);
        vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
        ThreeFPolicy(_policy).consume(_asset, 1, 1);
        vm.warp(block.timestamp + 3 days);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 1000);
        vm.prank(_executor);
        ThreeFPolicy(_policy).consume(_asset, 1000, 10);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 0);
    }

    function test_AssetsHaveIndependentBudgets() public {
        address second = makeAddr("secondAsset");
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(second, 1000, 1 days);
        vm.prank(_executor);
        ThreeFPolicy(_policy).consume(_asset, 1000, 10);
        assertEq(ThreeFPolicy(_policy).remainingAssets(second), 1000);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 0);
    }

    function test_UnconfiguredAssetCannotBeConsumed() public {
        vm.prank(_executor);
        vm.expectRevert(AssetRateLimits.UnconfiguredAsset.selector);
        ThreeFPolicy(_policy).consume(makeAddr("unconfigured"), 1, 1);
    }

    function testFuzz_MinimumRoundsConservatively(uint128 principal, uint64 minimum) public {
        principal = uint128(bound(principal, 1, type(uint128).max));
        minimum = uint64(bound(minimum, 1, 1_000_000));
        ThreeFPolicy(_policy).setMinYieldPerRequest(_asset, minimum);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_asset, principal, 1 days);
        uint256 yieldAssets = (uint256(principal) * minimum + 999_999) / 1_000_000;
        vm.prank(_executor);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        ThreeFPolicy(_policy).consume(_asset, principal, yieldAssets - 1);
        vm.prank(_executor);
        ThreeFPolicy(_policy).consume(_asset, principal, yieldAssets);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 0);
    }

    function test_FactoryCreationSetsOwnerFactoryVersionAndConsumer() public view {
        assertEq(ThreeFPolicy(_policy).owner(), address(this));
        assertEq(ThreeFPolicy(_policy).FACTORY(), address(_factory));
        assertEq(ThreeFPolicy(_policy).version(), _factory.lastVersion());
        assertEq(ThreeFPolicy(_policy).consumer(), _executor);
    }

    function test_InitializedPolicyCannotBeReinitialized() public {
        vm.expectRevert(IMigratableEntity.AlreadyInitialized.selector);
        ThreeFPolicy(_policy).initialize(1, address(this), abi.encode(_account));
    }

    function test_MigrationRequiresTheFactoryAndTheOwner() public {
        uint64 next = _whitelistNextVersion();
        vm.expectRevert(IMigratableEntity.NotFactory.selector);
        ThreeFPolicy(_policy).migrate(next, "");
        vm.prank(_other);
        vm.expectRevert(IMigratablesFactory.NotOwner.selector);
        _factory.migrate(_policy, next, "");
    }

    function test_MigrationIgnoresData() public {
        uint64 next = _whitelistNextVersion();
        _factory.migrate(_policy, next, abi.encode(_account));

        assertEq(ThreeFPolicy(_policy).version(), next);
        assertEq(ThreeFPolicy(_policy).consumer(), _executor);
    }

    /// @dev The reason to be migratable: a new implementation inherits the live budget, not a fresh one.
    function test_MigrationPreservesConsumerBudgetAndSpentUsage() public {
        vm.prank(_executor);
        ThreeFPolicy(_policy).consume(_asset, 600, 6);

        uint64 next = _whitelistNextVersion();
        _factory.migrate(_policy, next, "");

        assertEq(ThreeFPolicy(_policy).version(), next);
        assertEq(ThreeFPolicy(_policy).consumer(), _executor);
        assertEq(ThreeFPolicy(_policy).minYieldPerRequest(_asset), 10_000);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_asset), 400);
        vm.prank(_executor);
        vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
        ThreeFPolicy(_policy).consume(_asset, 401, 5);
    }

    function _whitelistNextVersion() internal returns (uint64) {
        _factory.whitelist(address(new ThreeFPolicy(address(_factory))));
        return _factory.lastVersion();
    }
}
