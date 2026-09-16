// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";

import {ThreeFAction} from "src/contracts/merkle_adapter/ThreeFAction.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {IAssetRateLimits} from "src/interfaces/merkle_adapter/IAssetRateLimits.sol";
import {IThreeFAction, MAX_REQUESTS} from "src/interfaces/merkle_adapter/IThreeFAction.sol";
import {IThreeFRequestCallback} from "src/interfaces/3f-adapter/IThreeFRequestCallback.sol";
import {IThreeFWhitelist} from "src/interfaces/3f-adapter/IThreeFWhitelist.sol";
import {Offer} from "src/interfaces/3f-adapter/ThreeFTypes.sol";

import {ThreeFCapabilityV1} from "test/mocks/ThreeFCapabilityV1.sol";
import {IThreeFCapabilityV1} from "test/mocks/IThreeFCapabilityV1.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    ThreeFActionAdapterMock,
    ThreeFActionVaultMock,
    ThreeFActionWhitelistMock,
    ThreeFActionTokenMock,
    ThreeFActionRequestMock,
    ThreeFActionFacilityMock,
    ThreeFActionCollateralMock,
    ThreeFActionPositionManagerMock
} from "test/mocks/ThreeFActionPushMocks.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

contract ThreeFActionTest is Test {
    uint256 internal constant PRINCIPAL = 100_000e6;
    uint256 internal constant YIELD = 2000e6;

    ThreeFActionTokenMock internal asset;
    ThreeFActionVaultMock internal vault;
    ThreeFActionAdapterMock internal adapter;
    ThreeFActionWhitelistMock internal whitelist;
    MigratablesFactory internal actionFactory;
    ThreeFAction internal actionContract;
    ThreeFActionRequestMock internal request;

    address internal adapterOwner = makeAddr("adapterOwner");
    address internal underlying = makeAddr("rwaUnderlying");
    ThreeFActionFacilityMock internal facility;
    uint256 internal nextIntentId;
    mapping(address => uint256) internal intentIds;
    mapping(address => address) internal positionManagers;

    function setUp() public {
        asset = new ThreeFActionTokenMock();
        vault = new ThreeFActionVaultMock(address(asset));
        adapter = new ThreeFActionAdapterMock(address(vault), adapterOwner);
        whitelist = new ThreeFActionWhitelistMock();
        facility = new ThreeFActionFacilityMock();
        actionFactory = new MigratablesFactory(address(this));
        actionFactory.whitelist(
            address(new ThreeFAction(address(actionFactory), address(whitelist), address(facility)))
        );
        actionContract =
            ThreeFAction(actionFactory.create(actionFactory.lastVersion(), adapterOwner, abi.encode(address(adapter))));
        request = _newRequest(address(asset));

        _setLimits(0, type(uint256).max);
    }

    function test_FactoryCreationInitializesAdapterOwnerFactoryAndVersion() public view {
        assertEq(actionContract.adapter(), address(adapter));
        assertEq(actionContract.REQUEST_WHITELIST(), address(whitelist));
        assertEq(actionContract.FACILITY(), address(facility));
        assertEq(actionContract.FACTORY(), address(actionFactory));
        assertEq(actionContract.version(), actionFactory.lastVersion());
        assertEq(actionContract.owner(), adapterOwner);
    }

    function test_MigratePreservesConfigurationAndActiveRequestAccounting() public {
        uint256 periodStart = vm.getBlockTimestamp();
        _setLimits(20_000, 200_000e6);
        _fundAndApprove(PRINCIPAL);
        _mint(request, PRINCIPAL, YIELD);
        vm.warp(block.timestamp + 10 minutes);
        actionFactory.whitelist(
            address(new ThreeFAction(address(actionFactory), address(whitelist), address(facility)))
        );
        uint64 newVersion = actionFactory.lastVersion();

        vm.prank(adapterOwner);
        actionFactory.migrate(address(actionContract), newVersion, bytes(""));

        assertEq(actionContract.version(), newVersion);
        assertEq(actionContract.owner(), adapterOwner);
        assertEq(actionContract.adapter(), address(adapter));
        _assertLimits(actionContract, underlying, 20_000, 200_000e6);
        assertEq(actionContract.requestsLength(), 1);
        assertEq(actionContract.requests(0), address(request));
        assertEq(actionContract.requestIndex(address(request)), 1);
        assertEq(actionContract.pendingAssets(address(request)), PRINCIPAL);
        assertEq(actionContract.totalAssets(), PRINCIPAL);
        (uint256 maximum, uint256 duration, uint256 start, uint256 spent) = actionContract.assetLimits(underlying);
        assertEq(maximum, 200_000e6);
        assertEq(duration, 1 days);
        assertEq(start, periodStart);
        assertEq(spent, PRINCIPAL);
        assertEq(actionContract.remainingAssets(underlying), 100_000e6);
    }

    function test_MigrateRejectsNonEmptyDataAndKeepsVersion() public {
        actionFactory.whitelist(
            address(new ThreeFAction(address(actionFactory), address(whitelist), address(facility)))
        );
        uint64 newVersion = actionFactory.lastVersion();

        vm.prank(adapterOwner);
        vm.expectRevert(IThreeFAction.InvalidMigrationData.selector);
        actionFactory.migrate(address(actionContract), newVersion, hex"01");

        assertEq(actionContract.version(), 1);
    }

    function test_SetLimitsStoresValuesAndRejectsNonAdapter() public {
        vm.expectEmit(true, false, false, true, address(actionContract));
        emit IThreeFAction.SetMinYieldPerRequest(underlying, 10);
        _execute(abi.encodeCall(IThreeFAction.setMinYieldPerRequest, (underlying, 10)));
        vm.expectEmit(true, false, false, true, address(actionContract));
        emit IAssetRateLimits.SetMaxAssetsPerDuration(underlying, 30, 1 days);
        _execute(abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (underlying, 30, 1 days)));
        _assertLimits(actionContract, underlying, 10, 30);

        vm.expectRevert(IThreeFAction.InvalidCaller.selector);
        actionContract.setMinYieldPerRequest(underlying, 0);
        vm.expectRevert(IThreeFAction.InvalidCaller.selector);
        actionContract.setMaxAssetsPerDuration(underlying, type(uint256).max, 1 days);
    }

    function test_GetMaxAssetsSelectorIsUnavailable() public {
        (bool success,) = address(actionContract).call(abi.encodeWithSelector(bytes4(keccak256("getMaxAssets()"))));

        assertFalse(success);
    }

    function test_MintRequestsShareAssetBudgetUntilDurationEnds() public {
        _execute(abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (underlying, PRINCIPAL, 1 days)));
        ThreeFActionRequestMock second = _newRequest(address(asset));
        _fundAndApprove(PRINCIPAL * 2);
        _mint(request, PRINCIPAL, YIELD);

        _expectConsumeRevert(IAssetRateLimits.AssetLimitExceeded.selector, second, PRINCIPAL, YIELD);
        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL);
        assertEq(actionContract.requestsLength(), 1);

        vm.warp(block.timestamp + 1 days);
        _mint(second, PRINCIPAL, YIELD);
        assertEq(actionContract.requestsLength(), 2);
        assertEq(asset.balanceOf(address(adapter)), 0);
    }

    function test_FinalizationDoesNotRefundPeriodBudget() public {
        _setLimits(0, PRINCIPAL);
        _fundAndApprove(PRINCIPAL);
        _mint(request, PRINCIPAL, YIELD);
        asset.mint(address(request), YIELD);
        request.setCanWithdraw(true);
        actionContract.finalizeRequest(address(request));
        assertEq(actionContract.remainingAssets(underlying), 0);
        _expectConsumeRevert(IAssetRateLimits.AssetLimitExceeded.selector, _newRequest(address(asset)), 1, 1);
    }

    function test_FailedMintRestoresPeriodBudgetForRetry() public {
        _setLimits(0, PRINCIPAL);
        _fundAndApprove(PRINCIPAL);
        request.setFailMint(true);
        _expectConsumeRevert(ThreeFActionRequestMock.MintFailed.selector, request, PRINCIPAL, YIELD);
        assertEq(actionContract.remainingAssets(underlying), PRINCIPAL);
        request.setFailMint(false);
        _mint(request, PRINCIPAL, YIELD);
        assertEq(actionContract.remainingAssets(underlying), 0);
    }

    function test_ZeroDurationCannotReplaceAnActiveBudget() public {
        _setLimits(0, PRINCIPAL);
        _expectExecuteRevert(
            IAssetRateLimits.InvalidDuration.selector,
            abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (underlying, PRINCIPAL * 2, 0))
        );
        assertEq(actionContract.remainingAssets(underlying), PRINCIPAL);
    }

    /// @dev Baseline c297d8f's compiler layout puts all three old limit words at mapping slot 18.
    function test_MigratePreservesReservedPerAssetMappingAndRequiresNewConfiguration() public {
        actionContract = ThreeFAction(actionFactory.create(1, adapterOwner, abi.encode(address(adapter))));
        address second = makeAddr("legacySecondUnderlying");
        bytes32[2] memory keys =
            [keccak256(abi.encode(underlying, uint256(18))), keccak256(abi.encode(second, uint256(18)))];
        for (uint256 i; i < keys.length; ++i) {
            for (uint256 j; j < 3; ++j) {
                vm.store(address(actionContract), bytes32(uint256(keys[i]) + j), bytes32(100 + i * 10 + j));
            }
        }
        actionFactory.whitelist(
            address(new ThreeFAction(address(actionFactory), address(whitelist), address(facility)))
        );
        vm.prank(adapterOwner);
        actionFactory.migrate(address(actionContract), 2, "");
        _assertLimits(actionContract, underlying, 100, 0);
        _assertLimits(actionContract, second, 110, 0);
        _fundAndApprove(PRINCIPAL);
        _expectConsumeRevert(IAssetRateLimits.UnconfiguredAsset.selector, request, PRINCIPAL, YIELD);
        _execute(abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (underlying, PRINCIPAL, 1 days)));
        _mint(request, PRINCIPAL, YIELD);
        for (uint256 i; i < keys.length; ++i) {
            for (uint256 j; j < 3; ++j) {
                assertEq(vm.load(address(actionContract), bytes32(uint256(keys[i]) + j)), bytes32(100 + i * 10 + j));
            }
        }
    }

    function test_MintRequestPullsPrincipalFromAdapterAndTracksRequest() public {
        _fundAndApprove(PRINCIPAL);

        _mint(request, PRINCIPAL, YIELD);

        assertEq(asset.balanceOf(address(request)), PRINCIPAL);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(address(actionContract)), 0);
        assertEq(actionContract.totalAssets(), PRINCIPAL);
        assertEq(actionContract.requestsLength(), 1);
        assertEq(actionContract.requests(0), address(request));
        assertEq(actionContract.requestIndex(address(request)), 1);
        assertEq(actionContract.pendingAssets(address(request)), PRINCIPAL);
    }

    /// @dev A ready push authorization must fund and track a position through an adapter-initiated mint.
    function test_MintRequestFundsAuthorizedPrincipalFromAdapter() public {
        _fundAndApprove(PRINCIPAL);
        request.authorizeMinting(address(actionContract), uint128(PRINCIPAL), uint128(YIELD));

        _execute(
            abi.encodeWithSignature(
                "mintRequest(address,uint128,uint128,uint256)",
                address(request),
                uint128(PRINCIPAL),
                uint128(YIELD),
                block.timestamp
            )
        );

        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(address(actionContract)), 0);
        assertEq(actionContract.pendingAssets(address(request)), PRINCIPAL);
        assertEq(actionContract.totalAssets(), PRINCIPAL);
        (uint256 principalShares, uint256 yieldShares) = request.balancesOf(address(actionContract));
        assertEq(principalShares, PRINCIPAL);
        assertEq(yieldShares, YIELD);
    }

    function test_TotalAssetsUsesPendingPrincipalBeforeWithdrawable() public {
        _fundAndApprove(PRINCIPAL);
        _mint(request, PRINCIPAL, YIELD);
        request.pull(makeAddr("borrower"), PRINCIPAL - 1);
        request.setRevertBalancesOf(true);

        assertEq(asset.balanceOf(address(request)), 1);
        assertEq(actionContract.totalAssets(), PRINCIPAL);
    }

    function test_TotalAssetsUsesLiveConversionWhenWithdrawable() public {
        _fundAndApprove(PRINCIPAL);
        _mint(request, PRINCIPAL, YIELD);
        request.pull(makeAddr("loss"), 10_000e6);
        request.setCanWithdraw(true);

        assertEq(actionContract.totalAssets(), PRINCIPAL - 10_000e6);

        asset.mint(address(request), YIELD);
        assertEq(actionContract.totalAssets(), PRINCIPAL - 10_000e6 + YIELD);
    }

    function test_MintRequestRejectsDuplicateAndMoreThanMaximumRequests() public {
        asset.mint(address(adapter), PRINCIPAL + MAX_REQUESTS * 1e6);
        adapter.approve(address(asset), address(actionContract), type(uint256).max);
        _mint(request, PRINCIPAL, YIELD);

        _expectConsumeRevert(IThreeFAction.AlreadyRequest.selector, request, PRINCIPAL, YIELD);

        for (uint256 i = 1; i < MAX_REQUESTS; ++i) {
            _mint(_newRequest(address(asset)), 1e6, 1);
        }
        _expectConsumeRevert(IThreeFAction.TooManyRequests.selector, _newRequest(address(asset)), 1e6, 1);
    }

    function test_MintRequestRejectsUnknownPausedAndWrongAssetRequests() public {
        whitelist.set(address(request), IThreeFWhitelist.WhitelistStatus.NotWhitelisted);
        _expectConsumeRevert(IThreeFAction.NotRequest.selector, request, PRINCIPAL, YIELD);

        whitelist.set(address(request), IThreeFWhitelist.WhitelistStatus.PausedWhitelisted);
        _expectConsumeRevert(IThreeFAction.NotRequest.selector, request, PRINCIPAL, YIELD);

        ThreeFActionRequestMock wrongRequest = _newRequest(address(new ThreeFActionTokenMock()));
        _expectConsumeRevert(IThreeFAction.WrongAsset.selector, wrongRequest, PRINCIPAL, YIELD);
    }

    function test_MintRequestRejectsExhaustedBudgetAndLowYieldRequests() public {
        _setLimits(0, PRINCIPAL - 1);
        _expectConsumeRevert(IAssetRateLimits.AssetLimitExceeded.selector, request, PRINCIPAL, YIELD);

        _setLimits(30_000, type(uint256).max);
        _expectConsumeRevert(IThreeFAction.TooLowYield.selector, request, PRINCIPAL, YIELD);
    }

    function test_MintRequestPropagatesAdapterAllowanceAndBalanceFailures() public {
        asset.mint(address(adapter), PRINCIPAL);
        request.authorizeMinting(address(actionContract), uint128(PRINCIPAL), uint128(YIELD));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(actionContract), uint256(0), PRINCIPAL
            )
        );
        _mintWithBounds(request, PRINCIPAL, YIELD, block.timestamp);

        adapter.approve(address(asset), address(actionContract), type(uint256).max);
        asset.burn(address(adapter), PRINCIPAL);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(adapter), uint256(0), PRINCIPAL
            )
        );
        _mintWithBounds(request, PRINCIPAL, YIELD, block.timestamp);
    }

    function test_FinalizeRequestTransfersReturnedAssetsToAdapterAndRemovesRequest() public {
        _fundAndApprove(PRINCIPAL);
        _mint(request, PRINCIPAL, YIELD);
        asset.mint(address(request), YIELD);
        request.setCanWithdraw(true);

        vm.prank(makeAddr("finalizer"));
        actionContract.finalizeRequest(address(request));

        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL + YIELD);
        assertEq(asset.balanceOf(address(actionContract)), 0);
        assertEq(actionContract.requestsLength(), 0);
        assertEq(actionContract.requestIndex(address(request)), 0);
        assertEq(actionContract.pendingAssets(address(request)), 0);
    }

    function test_FinalizeRequestKeepsUnrelatedCapabilityAssets() public {
        _fundAndApprove(PRINCIPAL);
        _mint(request, PRINCIPAL, YIELD);
        asset.mint(address(request), YIELD);
        asset.mint(address(actionContract), 1);
        request.setCanWithdraw(true);

        actionContract.finalizeRequest(address(request));

        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL + YIELD);
        assertEq(asset.balanceOf(address(actionContract)), 1);
    }

    function test_FinalizeRequestKeepsMovedRequestIndex() public {
        ThreeFActionRequestMock secondRequest = _newRequest(address(asset));
        _fundAndApprove(PRINCIPAL + PRINCIPAL / 2);
        _mint(request, PRINCIPAL, YIELD);
        _mint(secondRequest, PRINCIPAL / 2, YIELD / 2);
        asset.mint(address(request), YIELD);
        asset.mint(address(secondRequest), YIELD / 2);
        request.setCanWithdraw(true);
        secondRequest.setCanWithdraw(true);

        actionContract.finalizeRequest(address(request));
        assertEq(actionContract.requestIndex(address(secondRequest)), 1);
        assertEq(actionContract.requests(0), address(secondRequest));

        actionContract.finalizeRequest(address(secondRequest));
        assertEq(actionContract.requestsLength(), 0);
        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL + YIELD + PRINCIPAL / 2 + YIELD / 2);
    }

    function test_FinalizeRequestRejectsUnknownRequest() public {
        vm.expectRevert(IThreeFAction.NotRequest.selector);
        actionContract.finalizeRequest(makeAddr("unknownRequest"));
    }

    function _fundAndApprove(uint256 amount) internal {
        asset.mint(address(adapter), amount);
        adapter.approve(address(asset), address(actionContract), type(uint256).max);
    }

    function _execute(bytes memory data) internal returns (bytes memory result) {
        result = adapter.execute(address(actionContract), data);
    }

    function _expectExecuteRevert(bytes4 selector, bytes memory data) internal {
        vm.expectRevert(selector);
        _execute(data);
    }

    function _setLimits(uint256 minYield, uint256 maxAssets) internal {
        _setAssetLimits(underlying, minYield, maxAssets);
    }

    function _newRequest(address requestAsset) internal returns (ThreeFActionRequestMock) {
        return _newRequestForUnderlying(requestAsset, underlying);
    }

    function _newRequestForUnderlying(address requestAsset, address riskAsset)
        internal
        returns (ThreeFActionRequestMock newRequest)
    {
        uint256 id = ++nextIntentId;
        newRequest = new ThreeFActionRequestMock(requestAsset, string.concat("request-", vm.toString(id)));
        ThreeFActionCollateralMock collateral = new ThreeFActionCollateralMock(riskAsset);
        ThreeFActionPositionManagerMock positionManager = new ThreeFActionPositionManagerMock(address(collateral));
        facility.setIntent(id, address(newRequest), address(positionManager), true);
        intentIds[address(newRequest)] = id;
        positionManagers[address(newRequest)] = address(positionManager);
        whitelist.set(address(newRequest), IThreeFWhitelist.WhitelistStatus.Whitelisted);
    }

    function _mint(ThreeFActionRequestMock targetRequest, uint256 principal, uint256 yieldAmount) internal {
        targetRequest.authorizeMinting(address(actionContract), uint128(principal), uint128(yieldAmount));
        _mintWithBounds(targetRequest, principal, yieldAmount, block.timestamp);
    }

    function _mintWithBounds(
        ThreeFActionRequestMock targetRequest,
        uint256 maxPrincipal,
        uint256 minYield,
        uint256 deadline
    ) internal {
        _execute(_mintData(targetRequest, maxPrincipal, minYield, deadline));
    }

    function _mintData(ThreeFActionRequestMock targetRequest, uint256 maxPrincipal, uint256 minYield, uint256 deadline)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(
            IThreeFAction.mintRequest, (address(targetRequest), uint128(maxPrincipal), uint128(minYield), deadline)
        );
    }

    function _expectConsumeRevert(
        bytes4 selector,
        ThreeFActionRequestMock targetRequest,
        uint256 principal,
        uint256 yieldAmount
    ) internal {
        targetRequest.authorizeMinting(address(actionContract), uint128(principal), uint128(yieldAmount));
        _expectMintRevert(selector, targetRequest, principal, yieldAmount, block.timestamp);
    }

    function _expectMintRevert(
        bytes4 selector,
        ThreeFActionRequestMock targetRequest,
        uint256 maxPrincipal,
        uint256 minYield,
        uint256 deadline
    ) internal {
        vm.expectRevert(selector);
        _mintWithBounds(targetRequest, maxPrincipal, minYield, deadline);
    }

    function _assertLimits(ThreeFAction target, address riskAsset, uint256 minYield, uint256 maxPrincipal)
        internal
        view
    {
        (uint256 actualMax,,,) = target.assetLimits(riskAsset);
        assertEq(target.minYieldPerRequest(riskAsset), minYield);
        assertEq(actualMax, maxPrincipal);
    }

    function _setAssetLimits(address riskAsset, uint256 minYield, uint256 maxPrincipal) internal {
        _execute(abi.encodeCall(IThreeFAction.setMinYieldPerRequest, (riskAsset, minYield)));
        _execute(abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (riskAsset, maxPrincipal, 1 days)));
    }

    function _offer(address maker, uint256 amount, uint256 expectedReturn, uint256 expiration)
        internal
        pure
        returns (Offer memory offer)
    {
        offer = Offer({
            maker: maker,
            amount: amount,
            expectedReturn: expectedReturn,
            nonce: 1,
            expiration: expiration,
            useCallback: true
        });
    }

    function test_MintRequestUsesCapabilityAuthorizationAndPinsActualAmounts() public {
        _fundAndApprove(PRINCIPAL * 2);
        request.authorizeMinting(address(actionContract), uint128(PRINCIPAL), uint128(YIELD));
        request.authorizeMinting(address(adapter), 1, 1);
        vm.expectEmit(true, true, false, true, address(actionContract));
        emit IThreeFAction.MintRequest(address(request), underlying, PRINCIPAL, YIELD);

        _mintWithBounds(request, PRINCIPAL * 2, YIELD / 2, block.timestamp);

        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL);
        assertEq(request.mintCaller(), address(actionContract));
        assertEq(request.principalCapAtMint(), PRINCIPAL);
        assertEq(request.yieldFloorAtMint(), YIELD);
        assertEq(request.allowanceAtMint(), PRINCIPAL);
        assertEq(request.mintCalls(), 1);
        _assertAuthorization(request, address(actionContract), 0, 0);
        _assertAuthorization(request, address(adapter), 1, 1);
        _assertPosition(request, address(actionContract), PRINCIPAL, YIELD);
    }

    function test_MintRequestAndLimitsRejectOwnerAsCaller() public {
        _fundAndApprove(PRINCIPAL);
        request.authorizeMinting(address(actionContract), uint128(PRINCIPAL), uint128(YIELD));
        vm.expectRevert(IThreeFAction.InvalidCaller.selector);
        actionContract.mintRequest(address(request), uint128(PRINCIPAL), uint128(YIELD), block.timestamp);
        vm.prank(adapterOwner);
        vm.expectRevert(IThreeFAction.InvalidCaller.selector);
        actionContract.mintRequest(address(request), uint128(PRINCIPAL), uint128(YIELD), block.timestamp);
        vm.prank(adapterOwner);
        vm.expectRevert(IThreeFAction.InvalidCaller.selector);
        actionContract.setMaxAssetsPerDuration(underlying, PRINCIPAL, 1 days);
        _assertUnminted(request, PRINCIPAL, PRINCIPAL, YIELD);
    }

    function test_MintRequestRejectsMissingAndZeroAuthorization() public {
        _fundAndApprove(PRINCIPAL);
        _expectMintRevert(IThreeFAction.InvalidMintAuthorization.selector, request, PRINCIPAL, 0, block.timestamp);
        request.authorizeMinting(address(actionContract), 0, uint128(YIELD));
        _expectMintRevert(IThreeFAction.InvalidMintAuthorization.selector, request, PRINCIPAL, 0, block.timestamp);
        request.authorizeMinting(address(actionContract), uint128(PRINCIPAL), 0);
        _expectMintRevert(IThreeFAction.InvalidMintAuthorization.selector, request, PRINCIPAL, 0, block.timestamp);
        _assertUnminted(request, PRINCIPAL, PRINCIPAL, 0);
    }

    function test_MintRequestDoesNotUseAuthorizationForAdapterOrCaller() public {
        _fundAndApprove(PRINCIPAL);
        request.authorizeMinting(address(adapter), uint128(PRINCIPAL), uint128(YIELD));
        request.authorizeMinting(address(this), uint128(PRINCIPAL), uint128(YIELD));
        _expectMintRevert(IThreeFAction.InvalidMintAuthorization.selector, request, PRINCIPAL, YIELD, block.timestamp);
        _assertUnminted(request, PRINCIPAL, 0, 0);
    }

    function test_MintRequestRejectsExpiredDeadlineAndAcceptsEquality() public {
        vm.warp(100);
        _fundAndApprove(PRINCIPAL);
        request.authorizeMinting(address(actionContract), uint128(PRINCIPAL), uint128(YIELD));
        _expectMintRevert(IThreeFAction.MintDeadlineExpired.selector, request, PRINCIPAL, YIELD, block.timestamp - 1);
        _assertUnminted(request, PRINCIPAL, PRINCIPAL, YIELD);
        _mintWithBounds(request, PRINCIPAL, YIELD, block.timestamp);
        assertEq(actionContract.pendingAssets(address(request)), PRINCIPAL);
    }

    function test_MintRequestRejectsAuthorizationOutsideCallerBounds() public {
        _fundAndApprove(PRINCIPAL);
        request.authorizeMinting(address(actionContract), uint128(PRINCIPAL), uint128(YIELD));
        _expectMintRevert(IThreeFAction.SlippageExceeded.selector, request, PRINCIPAL - 1, YIELD, block.timestamp);
        _expectMintRevert(IThreeFAction.SlippageExceeded.selector, request, PRINCIPAL, YIELD + 1, block.timestamp);
        _assertUnminted(request, PRINCIPAL, PRINCIPAL, YIELD);
    }

    function test_MintRequestChecksOverwrittenAuthorizationAgainstCallerBounds() public {
        _fundAndApprove(PRINCIPAL * 2);
        request.authorizeMinting(address(actionContract), uint128(PRINCIPAL), uint128(YIELD));
        request.authorizeMinting(address(actionContract), uint128(PRINCIPAL + 1), uint128(YIELD));
        _expectMintRevert(IThreeFAction.SlippageExceeded.selector, request, PRINCIPAL, YIELD, block.timestamp);
        request.authorizeMinting(address(actionContract), uint128(PRINCIPAL), uint128(YIELD - 1));
        _expectMintRevert(IThreeFAction.SlippageExceeded.selector, request, PRINCIPAL, YIELD, block.timestamp);
        _assertUnminted(request, PRINCIPAL * 2, PRINCIPAL, YIELD - 1);
    }

    function test_PerAssetLimitsKeepDifferentUnderlyingRisksIndependent() public {
        address secondUnderlying = makeAddr("secondUnderlying");
        _setLimits(20_000, PRINCIPAL);
        _setAssetLimits(secondUnderlying, 10_000, PRINCIPAL / 2);
        _assertLimits(actionContract, underlying, 20_000, PRINCIPAL);
        _assertLimits(actionContract, secondUnderlying, 10_000, PRINCIPAL / 2);
        _assertLimits(actionContract, address(asset), 0, 0);
        ThreeFActionRequestMock secondRequest = _newRequestForUnderlying(address(asset), secondUnderlying);
        _fundAndApprove(PRINCIPAL * 2);
        _mint(request, PRINCIPAL, YIELD);
        _expectConsumeRevert(IAssetRateLimits.AssetLimitExceeded.selector, secondRequest, PRINCIPAL, YIELD);
        _mint(secondRequest, PRINCIPAL / 2, YIELD / 2);
        assertEq(actionContract.requestsLength(), 2);
    }

    function test_MintRequestRejectsUnconfiguredUnderlyingDespiteConfiguredFundingAsset() public {
        ThreeFActionRequestMock unknown = _newRequestForUnderlying(address(asset), makeAddr("unknownUnderlying"));
        _setAssetLimits(address(asset), 0, type(uint256).max);
        _fundAndApprove(PRINCIPAL);
        _expectConsumeRevert(IAssetRateLimits.UnconfiguredAsset.selector, unknown, PRINCIPAL, YIELD);
        _assertUnminted(unknown, PRINCIPAL, PRINCIPAL, YIELD);
    }

    function test_DisablingAssetBlocksNewMintButPreservesFinalization() public {
        _fundAndApprove(PRINCIPAL);
        _mint(request, PRINCIPAL, YIELD);
        _setLimits(0, 0);
        _expectConsumeRevert(IAssetRateLimits.UnconfiguredAsset.selector, _newRequest(address(asset)), 1, 1);
        asset.mint(address(request), YIELD);
        request.setCanWithdraw(true);
        actionContract.finalizeRequest(address(request));
        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL + YIELD);
        assertEq(actionContract.requestsLength(), 0);
    }

    function test_MintRequestChecksYieldPpmWithFloorRounding() public {
        _setLimits(1, type(uint256).max);
        _expectConsumeRevert(IThreeFAction.TooLowYield.selector, request, 1_000_001, 1);
        _fundAndApprove(1_000_000);
        _mint(request, 1_000_000, 1);
        assertEq(actionContract.pendingAssets(address(request)), 1_000_000);
    }

    function testFuzz_MintRequestAcceptsExactLimitsAndPreservesDust(uint128 principal, uint128 yieldAmount, uint96 dust)
        public
    {
        principal = uint128(bound(principal, 1, 1e30));
        yieldAmount = uint128(bound(yieldAmount, 1, principal));
        _setLimits(uint256(yieldAmount) * 1_000_000 / principal, principal);
        _fundAndApprove(principal);
        asset.mint(address(actionContract), dust);
        _mint(request, principal, yieldAmount);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(address(actionContract)), dust);
        assertEq(asset.allowance(address(actionContract), address(request)), 0);
        assertEq(actionContract.pendingAssets(address(request)), principal);
        assertEq(actionContract.totalAssets(), uint256(principal) + dust);
        _assertPosition(request, address(actionContract), principal, yieldAmount);
    }

    function test_MintRequestRejectsMalformedRequestNames() public {
        string[8] memory names =
            ["", "request", "request-", "Request-1", "request--1", "request-1x", "request- 1", "other-1"];
        for (uint256 i; i < names.length; ++i) {
            request.setName(names[i]);
            _expectConsumeRevert(IThreeFAction.InvalidRequestName.selector, request, PRINCIPAL, YIELD);
        }
    }

    function testFuzz_MintRequestRejectsNonDigitSuffix(bytes1 nonDigit) public {
        vm.assume(nonDigit < bytes1("0") || nonDigit > bytes1("9"));
        request.setName(string(abi.encodePacked("request-1", nonDigit, "2")));
        _expectConsumeRevert(IThreeFAction.InvalidRequestName.selector, request, PRINCIPAL, YIELD);
    }

    function test_MintRequestRejectsOverflowingRequestId() public {
        request.setName("request-115792089237316195423570985008687907853269984665640564039457584007913129639936");
        request.authorizeMinting(address(actionContract), uint128(PRINCIPAL), uint128(YIELD));
        vm.expectRevert();
        _mintWithBounds(request, PRINCIPAL, YIELD, block.timestamp);
        assertEq(actionContract.requestsLength(), 0);
    }

    function testFuzz_MintRequestResolvesEntireDecimalRequestId(uint256 id) public {
        request.setName(string.concat("request-", vm.toString(id)));
        facility.setIntent(id, address(request), positionManagers[address(request)], true);
        _fundAndApprove(PRINCIPAL);
        _mint(request, PRINCIPAL, YIELD);
        assertEq(actionContract.pendingAssets(address(request)), PRINCIPAL);
    }

    function test_MintRequestRejectsFacilityRequestMismatchAndMissingIntent() public {
        facility.setIntent(
            intentIds[address(request)], makeAddr("otherRequest"), positionManagers[address(request)], true
        );
        _expectConsumeRevert(IThreeFAction.RequestMismatch.selector, request, PRINCIPAL, YIELD);
        request.setName("request-999");
        _expectConsumeRevert(IThreeFAction.RequestMismatch.selector, request, PRINCIPAL, YIELD);
    }

    function test_MintRequestRejectsNonPositionManagerTarget() public {
        facility.setIntent(intentIds[address(request)], address(request), positionManagers[address(request)], false);
        _expectConsumeRevert(IThreeFAction.UnsupportedTarget.selector, request, PRINCIPAL, YIELD);
    }

    function test_MintRequestUsesCollateralUnderlyingFromTrustedFacilityTarget() public {
        address nextUnderlying = makeAddr("nextUnderlying");
        ThreeFActionCollateralMock collateral = new ThreeFActionCollateralMock(nextUnderlying);
        ThreeFActionPositionManagerMock(positionManagers[address(request)]).setCollateral(address(collateral));
        _fundAndApprove(PRINCIPAL);
        _expectConsumeRevert(IAssetRateLimits.UnconfiguredAsset.selector, request, PRINCIPAL, YIELD);
        _setAssetLimits(nextUnderlying, 20_000, PRINCIPAL);
        _mint(request, PRINCIPAL, YIELD);
        assertEq(actionContract.pendingAssets(address(request)), PRINCIPAL);
    }

    function test_MintRequestUsesExactAllowanceAndKeepsDust() public {
        _fundAndApprove(PRINCIPAL);
        asset.mint(address(actionContract), 17);
        vm.prank(address(actionContract));
        asset.approve(address(request), type(uint256).max);
        _mint(request, PRINCIPAL, YIELD);
        assertEq(request.allowanceAtMint(), PRINCIPAL);
        assertEq(asset.allowance(address(actionContract), address(request)), 0);
        assertEq(asset.balanceOf(address(actionContract)), 17);
        assertEq(asset.balanceOf(address(adapter)), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(request), 0, 1)
        );
        request.pullFrom(address(actionContract), address(request), 1);
    }

    function test_MintRequestDoesNotUseDustToCoverUnfundedAdapter() public {
        asset.mint(address(actionContract), PRINCIPAL);
        adapter.approve(address(asset), address(actionContract), PRINCIPAL);
        request.authorizeMinting(address(actionContract), uint128(PRINCIPAL), uint128(YIELD));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(adapter), 0, PRINCIPAL)
        );
        _mintWithBounds(request, PRINCIPAL, YIELD, block.timestamp);
        assertEq(asset.balanceOf(address(actionContract)), PRINCIPAL);
        assertEq(actionContract.requestsLength(), 0);
    }

    function test_MintRequestRevertsFundingSharesAuthorizationAndAllowanceWhenMintFails() public {
        _fundAndApprove(PRINCIPAL);
        asset.mint(address(actionContract), 13);
        request.authorizeMinting(address(actionContract), uint128(PRINCIPAL), uint128(YIELD));
        request.setFailMint(true);
        _expectMintRevert(ThreeFActionRequestMock.MintFailed.selector, request, PRINCIPAL, YIELD, block.timestamp);
        _assertUnminted(request, PRINCIPAL, PRINCIPAL, YIELD);
        assertEq(asset.balanceOf(address(actionContract)), 13);
        request.setFailMint(false);
        _mintWithBounds(request, PRINCIPAL, YIELD, block.timestamp);
        assertEq(actionContract.pendingAssets(address(request)), PRINCIPAL);
    }

    function test_MintRequestRejectsAuthorizationRevokedDuringFunding() public {
        _fundAndApprove(PRINCIPAL);
        request.authorizeMinting(address(actionContract), uint128(PRINCIPAL), uint128(YIELD));
        _replaceAuthorizationDuringFunding(0, 0);
        _expectMintRevert(IThreeFAction.InvalidMintAuthorization.selector, request, PRINCIPAL, YIELD, block.timestamp);
        _assertUnminted(request, PRINCIPAL, PRINCIPAL, YIELD);
    }

    function test_MintRequestRejectsReducedPrincipalDuringFunding() public {
        _fundAndApprove(PRINCIPAL);
        request.authorizeMinting(address(actionContract), uint128(PRINCIPAL), uint128(YIELD));
        _replaceAuthorizationDuringFunding(PRINCIPAL - 1, YIELD);
        _expectMintRevert(IThreeFAction.InvalidMintAuthorization.selector, request, PRINCIPAL, YIELD, block.timestamp);
        _assertUnminted(request, PRINCIPAL, PRINCIPAL, YIELD);
    }

    function test_MintRequestPinsPrincipalAndYieldAgainstFundingCallback() public {
        _fundAndApprove(PRINCIPAL * 2);
        request.authorizeMinting(address(actionContract), uint128(PRINCIPAL), uint128(YIELD));
        _replaceAuthorizationDuringFunding(PRINCIPAL + 1, YIELD);
        _expectMintRevert(ThreeFActionRequestMock.SlippageExceeded.selector, request, PRINCIPAL * 2, 1, block.timestamp);
        _assertUnminted(request, PRINCIPAL * 2, PRINCIPAL, YIELD);
        _replaceAuthorizationDuringFunding(PRINCIPAL, YIELD - 1);
        _expectMintRevert(ThreeFActionRequestMock.SlippageExceeded.selector, request, PRINCIPAL * 2, 1, block.timestamp);
        _assertUnminted(request, PRINCIPAL * 2, PRINCIPAL, YIELD);
    }

    function test_MintRequestRejectsLostDustDuringMint() public {
        _fundAndApprove(PRINCIPAL);
        asset.mint(address(actionContract), 1);
        request.setMintCallback(
            address(asset), abi.encodeCall(ThreeFActionTokenMock.burn, (address(actionContract), 1))
        );
        _expectConsumeRevert(IThreeFAction.InvalidMintAuthorization.selector, request, PRINCIPAL, YIELD);
        _assertUnminted(request, PRINCIPAL, PRINCIPAL, YIELD);
        assertEq(asset.balanceOf(address(actionContract)), 1);
    }

    function test_MintRequestBlocksReentryThroughBoundAdapter() public {
        _fundAndApprove(PRINCIPAL);
        request.setMintCallback(
            address(adapter),
            abi.encodeCall(
                ThreeFActionAdapterMock.execute,
                (address(actionContract), _mintData(request, PRINCIPAL, YIELD, block.timestamp))
            )
        );
        _mint(request, PRINCIPAL, YIELD);
        assertFalse(request.callbackSuccess());
        assertEq(
            request.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(actionContract.requestsLength(), 1);
        assertEq(request.mintCalls(), 1);
    }

    function test_MintRequestBlocksReentrantFinalization() public {
        ThreeFActionRequestMock second = _newRequest(address(asset));
        _fundAndApprove(PRINCIPAL * 2);
        _mint(request, PRINCIPAL, YIELD);
        request.setCanWithdraw(true);
        second.setMintCallback(
            address(actionContract), abi.encodeCall(IThreeFAction.finalizeRequest, (address(request)))
        );
        _mint(second, PRINCIPAL, YIELD);
        assertFalse(second.callbackSuccess());
        assertEq(
            second.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(actionContract.requestsLength(), 2);
        _assertPosition(request, address(actionContract), PRINCIPAL, YIELD);
    }

    function test_FinalizeRequestBurnFailurePreservesTrackedPosition() public {
        _fundAndApprove(PRINCIPAL);
        _mint(request, PRINCIPAL, YIELD);
        vm.expectRevert(ThreeFActionRequestMock.NotWithdrawable.selector);
        actionContract.finalizeRequest(address(request));
        assertEq(actionContract.requestsLength(), 1);
        assertEq(actionContract.pendingAssets(address(request)), PRINCIPAL);
        _assertPosition(request, address(actionContract), PRINCIPAL, YIELD);
    }

    function test_MigratePreservesMultiplePerAssetLimits() public {
        address secondUnderlying = makeAddr("secondUnderlying");
        _setLimits(20_000, PRINCIPAL);
        _setAssetLimits(secondUnderlying, 30_000, PRINCIPAL * 2);
        actionFactory.whitelist(
            address(new ThreeFAction(address(actionFactory), address(whitelist), address(facility)))
        );
        uint64 version = actionFactory.lastVersion();
        vm.prank(adapterOwner);
        actionFactory.migrate(address(actionContract), version, "");
        _assertLimits(actionContract, underlying, 20_000, PRINCIPAL);
        _assertLimits(actionContract, secondUnderlying, 30_000, PRINCIPAL * 2);
    }

    function test_LegacyMigrationPreservesStoragePositionsAndStartsAssetLimitsClosed() public {
        ThreeFCapabilityV1 legacy = _newLegacyCapability();
        ThreeFActionRequestMock second = _newRequest(address(asset));
        _legacyConsume(legacy, request, PRINCIPAL, YIELD);
        _legacyConsume(legacy, second, PRINCIPAL / 2, YIELD / 2);
        asset.mint(address(legacy), 9);
        bytes32[8] memory oldSlots;
        for (uint256 i; i < oldSlots.length; ++i) {
            oldSlots[i] = vm.load(address(legacy), bytes32(i + 10));
        }
        ThreeFAction upgraded = _upgradeLegacy(legacy);
        for (uint256 i; i < oldSlots.length; ++i) {
            assertEq(vm.load(address(upgraded), bytes32(i + 10)), oldSlots[i]);
        }
        _assertMigratedLegacyPositions(upgraded, second);
        _resumeLegacyMinting(upgraded, second);
    }

    function test_LegacyMigrationDisablesPullSignerAndNonceSelectors() public {
        ThreeFAction upgraded = _upgradeLegacy(_newLegacyCapability());
        _assertLegacySelectorsRemoved(address(upgraded));
        Offer memory offer = _offer(address(upgraded), PRINCIPAL, YIELD, type(uint256).max);
        vm.expectRevert();
        request.consume(address(upgraded), offer, "", PRINCIPAL, YIELD);
        assertEq(upgraded.requestsLength(), 0);
    }

    function test_PushImplementationDisablesPullSignerAndNonceSelectors() public {
        _assertLegacySelectorsRemoved(address(actionContract));
        Offer memory offer = _offer(address(actionContract), PRINCIPAL, YIELD, type(uint256).max);
        vm.expectRevert();
        request.consume(address(actionContract), offer, "", PRINCIPAL, YIELD);
    }

    function _assertMigratedLegacyPositions(ThreeFAction upgraded, ThreeFActionRequestMock second) internal view {
        assertEq(upgraded.adapter(), address(adapter));
        assertEq(upgraded.owner(), adapterOwner);
        assertEq(upgraded.FACILITY(), address(facility));
        _assertLimits(upgraded, underlying, 0, 0);
        _assertLimits(upgraded, address(asset), 0, 0);
        assertEq(upgraded.requestsLength(), 2);
        assertEq(upgraded.requests(0), address(request));
        assertEq(upgraded.requests(1), address(second));
        assertEq(upgraded.requestIndex(address(request)), 1);
        assertEq(upgraded.requestIndex(address(second)), 2);
        assertEq(upgraded.pendingAssets(address(request)), PRINCIPAL);
        assertEq(upgraded.pendingAssets(address(second)), PRINCIPAL / 2);
        assertEq(upgraded.totalAssets(), PRINCIPAL + PRINCIPAL / 2 + 9);
    }

    function _resumeLegacyMinting(ThreeFAction upgraded, ThreeFActionRequestMock second) internal {
        ThreeFActionRequestMock next = _newRequest(address(asset));
        next.authorizeMinting(address(upgraded), uint128(PRINCIPAL), uint128(YIELD));
        vm.expectRevert(IAssetRateLimits.UnconfiguredAsset.selector);
        adapter.execute(address(upgraded), _mintData(next, PRINCIPAL, YIELD, block.timestamp));
        asset.mint(address(request), YIELD);
        request.setCanWithdraw(true);
        upgraded.finalizeRequest(address(request));
        assertEq(upgraded.requests(0), address(second));
        assertEq(upgraded.requestIndex(address(second)), 1);
        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL + YIELD);
        assertEq(upgraded.totalAssets(), PRINCIPAL / 2 + 9);
        adapter.execute(
            address(upgraded), abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (underlying, PRINCIPAL, 1 days))
        );
        adapter.execute(address(upgraded), _mintData(next, PRINCIPAL, YIELD, block.timestamp));
        assertEq(upgraded.requestsLength(), 2);
        assertEq(upgraded.pendingAssets(address(next)), PRINCIPAL);
        assertEq(asset.balanceOf(address(upgraded)), 9);
    }

    function _replaceAuthorizationDuringFunding(uint256 principal, uint256 yieldAmount) internal {
        asset.setTransferFromCallback(
            address(adapter),
            address(request),
            abi.encodeCall(
                ThreeFActionRequestMock.authorizeMinting,
                (address(actionContract), uint128(principal), uint128(yieldAmount))
            )
        );
    }

    function _assertAuthorization(
        ThreeFActionRequestMock target,
        address account,
        uint256 principal,
        uint256 yieldAmount
    ) internal view {
        (uint128 actualPrincipal, uint128 actualYield) = target.mintAuthorization(account);
        assertEq(actualPrincipal, principal);
        assertEq(actualYield, yieldAmount);
    }

    function _assertPosition(ThreeFActionRequestMock target, address account, uint256 principal, uint256 yieldAmount)
        internal
        view
    {
        (uint256 pt, uint256 yt) = target.balancesOf(account);
        assertEq(pt, principal);
        assertEq(yt, yieldAmount);
    }

    function _assertUnminted(
        ThreeFActionRequestMock target,
        uint256 adapterBalance,
        uint256 principal,
        uint256 yieldAmount
    ) internal view {
        assertEq(asset.balanceOf(address(adapter)), adapterBalance);
        assertEq(asset.balanceOf(address(target)), 0);
        assertEq(asset.allowance(address(actionContract), address(target)), 0);
        assertEq(actionContract.requestIndex(address(target)), 0);
        assertEq(actionContract.pendingAssets(address(target)), 0);
        assertEq(target.mintCalls(), 0);
        _assertPosition(target, address(actionContract), 0, 0);
        _assertAuthorization(target, address(actionContract), principal, yieldAmount);
    }

    function _newLegacyCapability() internal returns (ThreeFCapabilityV1 legacy) {
        actionFactory.whitelist(address(new ThreeFCapabilityV1(address(actionFactory), address(whitelist))));
        legacy = ThreeFCapabilityV1(
            actionFactory.create(actionFactory.lastVersion(), adapterOwner, abi.encode(address(adapter)))
        );
        adapter.execute(address(legacy), abi.encodeCall(IThreeFCapabilityV1.setOfferSigner, (makeAddr("legacySigner"))));
        adapter.execute(
            address(legacy), abi.encodeCall(IThreeFCapabilityV1.setLimitsPerRequest, (20_000, 1, PRINCIPAL * 2))
        );
        adapter.approve(address(asset), address(legacy), type(uint256).max);
    }

    function _upgradeLegacy(ThreeFCapabilityV1 legacy) internal returns (ThreeFAction upgraded) {
        actionFactory.whitelist(
            address(new ThreeFAction(address(actionFactory), address(whitelist), address(facility)))
        );
        uint64 version = actionFactory.lastVersion();
        vm.prank(adapterOwner);
        actionFactory.migrate(address(legacy), version, "");
        upgraded = ThreeFAction(address(legacy));
        assertEq(upgraded.version(), version);
    }

    function _legacyConsume(
        ThreeFCapabilityV1 legacy,
        ThreeFActionRequestMock target,
        uint256 principal,
        uint256 yieldAmount
    ) internal {
        asset.mint(address(adapter), principal);
        target.consume(
            address(legacy),
            _offer(address(legacy), principal, yieldAmount, type(uint256).max),
            "",
            principal,
            yieldAmount
        );
    }

    function _assertLegacySelectorsRemoved(address target) internal {
        bytes[8] memory calls = [
            abi.encodeCall(IThreeFCapabilityV1.setOfferSigner, (address(this))),
            abi.encodeCall(IThreeFCapabilityV1.offerSigner, ()),
            abi.encodeCall(IThreeFCapabilityV1.setRequestNonce, (address(request), 2)),
            abi.encodeCall(IThreeFCapabilityV1.isValidSignature, (bytes32(0), bytes(""))),
            abi.encodeCall(IThreeFCapabilityV1.setLimitsPerRequest, (0, 1, type(uint256).max)),
            abi.encodeCall(IThreeFCapabilityV1.minAssetsPerRequest, ()),
            abi.encodeCall(IThreeFCapabilityV1.maxAssetsPerRequest, ()),
            abi.encodeCall(IThreeFCapabilityV1.minYieldPerRequest, ())
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(address(adapter));
            (bool success,) = target.call(calls[i]);
            assertFalse(success);
        }
    }
}
