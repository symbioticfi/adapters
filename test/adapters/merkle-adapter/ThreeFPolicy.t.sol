// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ThreeFPolicy} from "src/contracts/merkle-adapter/capabilities/policies/ThreeFPolicy.sol";

import {AssetRateLimits} from "src/contracts/merkle-adapter/libraries/AssetRateLimits.sol";

import {IThreeFPolicy} from "src/interfaces/merkle-adapter/capabilities/policies/IThreeFPolicy.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IMigratableEntity} from "@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol";
import {IMigratablesFactory} from "@symbioticfi/core/src/interfaces/common/IMigratablesFactory.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";

import {createThreeFPolicyFactory} from "test/helpers/ThreeFPolicyFactory.sol";
import {
    ThreeFFacilityMock,
    ThreeFPositionManagerMock,
    ThreeFRequestFactoryMock,
    ThreeFRequestMock,
    ThreeFUnderlyingAssetMock
} from "test/mocks/ThreeFRequestMocks.sol";

contract ThreeFPolicyTest is Test {
    address internal _factory;
    address internal _requestsFactory;
    address internal _facility;
    address internal _request;
    address internal _positionManager;
    address internal _fundingAsset = makeAddr("fundingAsset");
    address internal _policy;
    address internal _account = makeAddr("account");
    address internal _asset = makeAddr("asset");
    address internal _other = makeAddr("other");

    function setUp() public {
        _requestsFactory = address(new ThreeFRequestFactoryMock());
        _facility = address(new ThreeFFacilityMock());
        _positionManager =
            address(new ThreeFPositionManagerMock(address(new ThreeFUnderlyingAssetMock(_asset)), _fundingAsset));
        _request = _createRequest(1, _positionManager);
        _factory = createThreeFPolicyFactory(address(this), _requestsFactory, _facility);
        _policy = MigratablesFactory(_factory)
            .create(MigratablesFactory(_factory).lastVersion(), address(this), abi.encode(_account));
        vm.prank(_account);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_fundingAsset, _asset, 1000, 1 days);
        vm.prank(_account);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_asset, 1_000_000);
    }

    /// forge-config: default.isolate = true
    function test_MulticallConfiguresPolicyAndPreservesAccount() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IThreeFPolicy.setMinYieldPerRequest, (_asset, 2_000_000));
        calls[1] = abi.encodeCall(IThreeFPolicy.setMaxAssetsPerDuration, (_fundingAsset, _asset, 2000, 2 days));
        vm.prank(_account);
        ThreeFPolicy(_policy).multicall(calls);
        vm.snapshotGasLastCall("ThreeFPolicy", "multicallConfigure");
        assertEq(ThreeFPolicy(_policy).minYieldPerRequest(_asset), 2_000_000);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 2000);
        vm.expectRevert(IThreeFPolicy.InvalidCaller.selector);
        ThreeFPolicy(_policy).multicall(calls);
    }

    function test_MulticallConsumesAsAccountAndRollsBackExceededBudget() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IThreeFPolicy.consume, (_request, 400, 4));
        calls[1] = abi.encodeCall(IThreeFPolicy.consume, (_request, 700, 7));
        vm.prank(_account);
        vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
        ThreeFPolicy(_policy).multicall(calls);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 1000);
        calls[1] = abi.encodeCall(IThreeFPolicy.consume, (_request, 600, 6));
        vm.prank(_account);
        ThreeFPolicy(_policy).multicall(calls);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 0);
    }

    function test_OwnerCannotChangePolicyDirectly() public {
        vm.expectRevert(IThreeFPolicy.InvalidCaller.selector);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_asset, 0);
        vm.expectRevert(IThreeFPolicy.InvalidCaller.selector);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_fundingAsset, _asset, 10_000, 1);
        assertEq(ThreeFPolicy(_policy).minYieldPerRequest(_asset), 1_000_000);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 1000);
    }

    function testFuzz_OnlyAccountCanChangePolicy(address caller) public {
        vm.assume(caller != _account);
        vm.startPrank(caller);
        vm.expectRevert(IThreeFPolicy.InvalidCaller.selector);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_asset, 0);
        vm.expectRevert(IThreeFPolicy.InvalidCaller.selector);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_fundingAsset, _asset, 10_000, 1);
        vm.stopPrank();
    }

    /// forge-config: default.isolate = true
    function test_OnlyTheCurrentAccountCanConsume() public {
        assertEq(ThreeFPolicy(_policy).account(), _account);
        vm.prank(_other);
        vm.expectRevert(IThreeFPolicy.InvalidCaller.selector);
        vm.startSnapshotGas("ThreeFPolicy", "consumeUnauthorized");
        ThreeFPolicy(_policy).consume(_request, 100, 1);
        vm.stopSnapshotGas("ThreeFPolicy", "consumeUnauthorized");
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(_request, 100, 1);
        vm.snapshotGasLastCall("ThreeFPolicy", "consume");
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 900);
    }

    /// forge-config: default.isolate = true
    function test_AccountCannotBeReboundByOwner() public {
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(_request, 600, 6);
        (bool success,) = _policy.call(abi.encodeWithSignature("setConsumer(address)", _other));
        assertFalse(success);
        assertEq(ThreeFPolicy(_policy).account(), _account);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 400);
        vm.prank(_other);
        vm.expectRevert(IThreeFPolicy.InvalidCaller.selector);
        ThreeFPolicy(_policy).consume(_request, 1, 1);
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(_request, 400, 4);
        vm.snapshotGasLastCall("ThreeFPolicy", "consumeSamePeriod");
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 0);
    }

    function test_ZeroAccountLeavesPolicyInert() public {
        _policy = MigratablesFactory(_factory).create(1, address(this), abi.encode(address(0)));
        vm.prank(_account);
        vm.expectRevert(IThreeFPolicy.InvalidCaller.selector);
        ThreeFPolicy(_policy).consume(_request, 1, 1);
    }

    function test_ZeroPrincipalRevertsInsteadOfDividing() public {
        vm.prank(_account);
        vm.expectRevert(IThreeFPolicy.InvalidAssets.selector);
        ThreeFPolicy(_policy).consume(_request, 0, 0);
        vm.prank(_account);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_asset, 0);
        vm.prank(_account);
        vm.expectRevert(IThreeFPolicy.InvalidAssets.selector);
        ThreeFPolicy(_policy).consume(_request, 0, 1);
    }

    function test_YieldProductOverflowRevertsBeforeBudgetConsumption() public {
        vm.prank(_account);
        vm.expectRevert(stdError.arithmeticError);
        ThreeFPolicy(_policy).consume(_request, 1000, type(uint256).max / 1e8 + 1);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 1000);
    }

    /// forge-config: default.isolate = true
    function test_ReconfigurationPreservesSpentAcrossDurationAndBudgetChanges() public {
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(_request, 100, 1);
        vm.prank(_account);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_fundingAsset, _asset, 200, 2 days);
        vm.snapshotGasLastCall("ThreeFPolicy", "setMaxAssetsNewDuration");
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 100);
        vm.prank(_account);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_fundingAsset, _asset, 0, 2 days);
        vm.snapshotGasLastCall("ThreeFPolicy", "setMaxAssetsDisable");
        uint256 remaining = ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset);
        vm.snapshotGasLastCall("ThreeFPolicy", "remainingAssetsDisabled");
        assertEq(remaining, 0);
        vm.prank(_account);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_fundingAsset, _asset, 200, 2 days);
        vm.snapshotGasLastCall("ThreeFPolicy", "setMaxAssetsSameDuration");
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 100);
    }

    /// forge-config: default.isolate = true
    function test_CurrentMinimumAppliesImmediatelyAndDoesNotResetUsage() public {
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(_request, 100, 1);
        vm.prank(_account);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_asset, 2_000_000);
        vm.snapshotGasLastCall("ThreeFPolicy", "setMinYieldPerRequest");
        vm.prank(_account);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        vm.startSnapshotGas("ThreeFPolicy", "consumeInsufficientYield");
        ThreeFPolicy(_policy).consume(_request, 100, 1);
        vm.stopSnapshotGas("ThreeFPolicy", "consumeInsufficientYield");
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 900);
        vm.prank(_account);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_asset, 0);
        vm.snapshotGasLastCall("ThreeFPolicy", "setMinYieldPerRequestDisable");
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(_request, 100, 0);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 800);
    }

    /// forge-config: default.isolate = true
    function test_PeriodRollsWithoutAccumulatingUnusedCapacity() public {
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(_request, 1000, 10);
        vm.prank(_account);
        vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
        vm.startSnapshotGas("ThreeFPolicy", "consumeBudgetExceeded");
        ThreeFPolicy(_policy).consume(_request, 1, 1);
        vm.stopSnapshotGas("ThreeFPolicy", "consumeBudgetExceeded");
        vm.warp(block.timestamp + 3 days);
        uint256 remaining = ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset);
        vm.snapshotGasLastCall("ThreeFPolicy", "remainingAssetsExpired");
        assertEq(remaining, 1000);
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(_request, 1000, 10);
        vm.snapshotGasLastCall("ThreeFPolicy", "consumeRollover");
        remaining = ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset);
        vm.snapshotGasLastCall("ThreeFPolicy", "remainingAssets");
        assertEq(remaining, 0);
    }

    /// forge-config: default.isolate = true
    function test_AssetsHaveIndependentBudgets() public {
        address second = makeAddr("secondAsset");
        address secondRequest = _createRequest(
            2, address(new ThreeFPositionManagerMock(address(new ThreeFUnderlyingAssetMock(second)), _fundingAsset))
        );
        vm.prank(_account);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_fundingAsset, second, 1000, 1 days);
        vm.snapshotGasLastCall("ThreeFPolicy", "setMaxAssetsPerDuration");
        vm.prank(_account);
        ThreeFPolicy(_policy).setMinYieldPerRequest(second, 2_000_000);
        assertEq(ThreeFRequestMock(_request).asset(), ThreeFRequestMock(secondRequest).asset());
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(_request, 1000, 10);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, second), 1000);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 0);
        vm.prank(_account);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        ThreeFPolicy(_policy).consume(secondRequest, 1000, 10);
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(secondRequest, 1000, 20);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, second), 0);
    }

    function test_RequestsWithTheSameUnderlyingShareBudgetAndMinimumYield() public {
        address secondRequest = _createRequest(2, _positionManager);
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(_request, 600, 6);
        vm.prank(_account);
        vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
        ThreeFPolicy(_policy).consume(secondRequest, 401, 5);
        vm.prank(_account);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        ThreeFPolicy(_policy).consume(secondRequest, 400, 3);
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(secondRequest, 400, 4);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 0);
    }

    function test_ResolvesAndChargesCollateralUnderlyingInsteadOfFundingToken() public {
        assertNotEq(_asset, ThreeFRequestMock(_request).asset());
        vm.prank(_account);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_fundingAsset, _fundingAsset, 1000, 1 days);
        vm.expectEmit(true, true, false, true);
        emit IThreeFPolicy.Consume(_fundingAsset, _asset, 100);
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(_request, 100, 1);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 900);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _fundingAsset), 1000);
    }

    /// forge-config: default.isolate = true
    function test_RedemptionChargesTheDepositPositionUnderlying() public {
        ThreeFFacilityMock(_facility).setRedemption(1, _request, _positionManager, _fundingAsset);
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(_request, 100, 1);
        vm.snapshotGasLastCall("ThreeFPolicy", "consumeRedemption");
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 900);
    }

    function test_RetargetToConfiguredPairChargesOnlyThatPair() public {
        address otherUnderlying = makeAddr("retargetedUnderlying");
        vm.startPrank(_account);
        ThreeFPolicy(_policy).consume(_request, 100, 1);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_fundingAsset, otherUnderlying, 500, 1 days);
        ThreeFPolicy(_policy).setMinYieldPerRequest(otherUnderlying, 2_000_000);
        ThreeFFacilityMock(_facility)
            .setIntent(
                1,
                _request,
                address(
                    new ThreeFPositionManagerMock(
                        address(new ThreeFUnderlyingAssetMock(otherUnderlying)), _fundingAsset
                    )
                ),
                true
            );
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        ThreeFPolicy(_policy).consume(_request, 100, 1);
        ThreeFPolicy(_policy).consume(_request, 100, 2);
        vm.stopPrank();
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 900);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, otherUnderlying), 400);
    }

    function test_RejectsRequestsNotRegisteredByTheTrustedFactory() public {
        ThreeFRequestFactoryMock(_requestsFactory).set(_request, false);
        vm.prank(_account);
        vm.expectRevert(IThreeFPolicy.InvalidRequest.selector);
        ThreeFPolicy(_policy).consume(_request, 100, 1);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 1000);
    }

    function test_RejectsRequestNamesWithoutIntentIds() public {
        string[3] memory names = [string(""), "request", "request-"];
        for (uint256 i; i < names.length; ++i) {
            ThreeFRequestMock(_request).setName(names[i]);
            vm.prank(_account);
            vm.expectRevert(IThreeFPolicy.InvalidRequestName.selector);
            ThreeFPolicy(_policy).consume(_request, 100, 1);
        }
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 1000);
    }

    function test_RejectsNonDecimalRequestIds() public {
        string[5] memory names = [string("request-+1"), "request--1", "request-1a", "request- 1", "request-1\x00"];
        for (uint256 i; i < names.length; ++i) {
            ThreeFRequestMock(_request).setName(names[i]);
            vm.prank(_account);
            vm.expectRevert(Strings.StringsInvalidChar.selector);
            ThreeFPolicy(_policy).consume(_request, 100, 1);
        }
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 1000);
    }

    function test_IntentIdOverflowRevertsBeforeConsumption() public {
        ThreeFRequestMock(_request).setName(string.concat("request-", vm.toString(type(uint256).max), "0"));
        vm.prank(_account);
        vm.expectRevert(stdError.arithmeticError);
        ThreeFPolicy(_policy).consume(_request, 100, 1);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 1000);
    }

    function test_ResolvesZeroAndMaximumIntentIdsAndLeadingZeros() public {
        address zeroRequest = _createRequest(0, _positionManager);
        address maximumRequest = _createRequest(type(uint256).max, _positionManager);
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(zeroRequest, 100, 1);
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(maximumRequest, 100, 1);
        ThreeFRequestMock(_request).setName("request-0001");
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(_request, 100, 1);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 700);
    }

    function testFuzz_ResolvesFactoryRegisteredAndFacilityBoundIntent(uint256 id) public {
        address request = _createRequest(id, _positionManager);
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(request, 100, 1);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 900);
    }

    function testFuzz_ConsumesRequestsWithoutCheckingThePrefix(bytes8 prefix, uint256 id) public {
        address request = _createRequest(id, _positionManager);
        ThreeFRequestMock(request).setName(string(abi.encodePacked(prefix, vm.toString(id))));
        vm.expectEmit(true, true, false, true);
        emit IThreeFPolicy.Consume(_fundingAsset, _asset, 100);
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(request, 100, 1);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 900);
    }

    function testFuzz_RejectsARequestNotBoundToItsNamedIntent(bytes8 prefix) public {
        ThreeFRequestMock(_request).setName(string(abi.encodePacked(prefix, "1")));
        ThreeFFacilityMock(_facility).setIntent(1, _other, _positionManager, true);
        vm.prank(_account);
        vm.expectRevert(IThreeFPolicy.RequestMismatch.selector);
        ThreeFPolicy(_policy).consume(_request, 100, 1);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 1000);
    }

    function test_RejectsIntentWithoutPositionManager() public {
        ThreeFFacilityMock(_facility).setIntent(1, _request, _positionManager, false);
        vm.prank(_account);
        vm.expectRevert(IThreeFPolicy.UnsupportedTarget.selector);
        ThreeFPolicy(_policy).consume(_request, 100, 1);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 1000);
    }

    function test_RejectsZeroCollateralUnderlying() public {
        ThreeFFacilityMock(_facility)
            .setIntent(
                1,
                _request,
                address(
                    new ThreeFPositionManagerMock(address(new ThreeFUnderlyingAssetMock(address(0))), _fundingAsset)
                ),
                true
            );
        vm.prank(_account);
        vm.expectRevert(IThreeFPolicy.InvalidAsset.selector);
        ThreeFPolicy(_policy).consume(_request, 100, 1);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 1000);
    }

    function test_RejectsZeroFundingAsset() public {
        vm.mockCall(_request, abi.encodeWithSignature("asset()"), abi.encode(address(0)));
        vm.prank(_account);
        vm.expectRevert(IThreeFPolicy.InvalidAsset.selector);
        ThreeFPolicy(_policy).consume(_request, 100, 1);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 1000);
    }

    function testFuzz_UnconfiguredFundingTokenCannotUseAnotherTokenBudget(address asset) public {
        vm.assume(asset != address(0) && asset != _fundingAsset);
        vm.mockCall(_request, abi.encodeWithSignature("asset()"), abi.encode(asset));
        vm.prank(_account);
        vm.expectRevert(AssetRateLimits.UnconfiguredAsset.selector);
        ThreeFPolicy(_policy).consume(_request, 100, 1);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 1000);
    }

    function test_FundingTokensHaveIndependentBudgetsAndShareUnderlyingYieldMinimum() public {
        address second = makeAddr("secondFunding");
        address secondRequest = _createRequest(2, _positionManager);
        vm.mockCall(secondRequest, abi.encodeWithSignature("asset()"), abi.encode(second));
        vm.startPrank(_account);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(second, _asset, 500, 1 days);
        ThreeFPolicy(_policy).consume(_request, 100, 1);
        ThreeFPolicy(_policy).consume(secondRequest, 100, 1);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_asset, 2_000_000);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        ThreeFPolicy(_policy).consume(_request, 100, 1);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        ThreeFPolicy(_policy).consume(secondRequest, 100, 1);
        ThreeFPolicy(_policy).consume(_request, 100, 2);
        ThreeFPolicy(_policy).consume(secondRequest, 100, 2);
        vm.stopPrank();
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 800);
        assertEq(ThreeFPolicy(_policy).remainingAssets(second, _asset), 300);
    }

    function test_UnconfiguredAssetCannotBeConsumed() public {
        address request = _createRequest(
            2,
            address(
                new ThreeFPositionManagerMock(
                    address(new ThreeFUnderlyingAssetMock(makeAddr("unconfigured"))), _fundingAsset
                )
            )
        );
        vm.prank(_account);
        vm.expectRevert(AssetRateLimits.UnconfiguredAsset.selector);
        ThreeFPolicy(_policy).consume(request, 1, 1);
    }

    function testFuzz_MinimumRoundsConservatively(uint128 principal, uint64 minimum) public {
        principal = uint128(bound(principal, 1, type(uint128).max));
        minimum = uint64(bound(minimum, 1, 1e8));
        vm.prank(_account);
        ThreeFPolicy(_policy).setMinYieldPerRequest(_asset, minimum);
        vm.prank(_account);
        ThreeFPolicy(_policy).setMaxAssetsPerDuration(_fundingAsset, _asset, principal, 1 days);
        uint256 yieldAssets = (uint256(principal) * minimum + 1e8 - 1) / 1e8;
        vm.prank(_account);
        vm.expectRevert(IThreeFPolicy.TooLowYield.selector);
        ThreeFPolicy(_policy).consume(_request, principal, yieldAssets - 1);
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(_request, principal, yieldAssets);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 0);
    }

    function test_FactoryCreationSetsOwnerFactoryVersionAndAccount() public {
        _policy = MigratablesFactory(_factory)
            .create(MigratablesFactory(_factory).lastVersion(), address(this), abi.encode(_account));

        assertEq(ThreeFPolicy(_policy).owner(), address(this));
        assertEq(ThreeFPolicy(_policy).FACTORY(), _factory);
        assertEq(ThreeFPolicy(_policy).REQUESTS_FACTORY(), _requestsFactory);
        assertEq(ThreeFPolicy(_policy).FACILITY(), _facility);
        assertEq(ThreeFPolicy(_policy).version(), MigratablesFactory(_factory).lastVersion());
        assertEq(ThreeFPolicy(_policy).account(), _account);
    }

    function test_InitializedPolicyCannotBeReinitialized() public {
        vm.expectRevert(IMigratableEntity.AlreadyInitialized.selector);
        ThreeFPolicy(_policy).initialize(1, address(this), abi.encode(_other));
    }

    function test_MigrationRequiresTheFactoryAndTheOwner() public {
        uint64 next = _whitelistNextVersion();
        vm.expectRevert(IMigratableEntity.NotFactory.selector);
        ThreeFPolicy(_policy).migrate(next, "");
        vm.prank(_other);
        vm.expectRevert(IMigratablesFactory.NotOwner.selector);
        MigratablesFactory(_factory).migrate(_policy, next, "");
    }

    function test_MigrationIgnoresData() public {
        uint64 next = _whitelistNextVersion();
        MigratablesFactory(_factory).migrate(_policy, next, abi.encode(_other));

        assertEq(ThreeFPolicy(_policy).version(), next);
        assertEq(ThreeFPolicy(_policy).account(), _account);
    }

    /// @dev The reason to be migratable: a new implementation inherits the live budget, not a fresh one.
    function test_MigrationPreservesAccountBudgetAndSpentUsage() public {
        vm.prank(_account);
        ThreeFPolicy(_policy).consume(_request, 600, 6);

        uint64 next = _whitelistNextVersion();
        MigratablesFactory(_factory).migrate(_policy, next, "");

        assertEq(ThreeFPolicy(_policy).version(), next);
        assertEq(ThreeFPolicy(_policy).account(), _account);
        assertEq(ThreeFPolicy(_policy).minYieldPerRequest(_asset), 1_000_000);
        assertEq(ThreeFPolicy(_policy).remainingAssets(_fundingAsset, _asset), 400);
        vm.prank(_account);
        vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
        ThreeFPolicy(_policy).consume(_request, 401, 5);
    }

    function _createRequest(uint256 id, address positionManager) internal returns (address request) {
        request = address(new ThreeFRequestMock(_fundingAsset, string.concat("request-", vm.toString(id))));
        ThreeFRequestFactoryMock(_requestsFactory).set(request, true);
        ThreeFFacilityMock(_facility).setIntent(id, request, positionManager, true);
    }

    function _whitelistNextVersion() internal returns (uint64) {
        MigratablesFactory(_factory).whitelist(address(new ThreeFPolicy(_factory, _requestsFactory, _facility)));
        return MigratablesFactory(_factory).lastVersion();
    }
}
