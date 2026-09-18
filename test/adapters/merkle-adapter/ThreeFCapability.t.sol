// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {ThreeFCapability} from "src/contracts/merkle-adapter/capabilities/ThreeFCapability.sol";
import {IThreeFCapability, MAX_REQUESTS} from "src/interfaces/merkle-adapter/capabilities/IThreeFCapability.sol";
import {ICapability} from "src/interfaces/merkle-adapter/capabilities/ICapability.sol";
import {IAssetRateLimits} from "src/interfaces/merkle-adapter/IAssetRateLimits.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IThreeFWhitelist} from "src/interfaces/3f-adapter/IThreeFWhitelist.sol";
import {
    ThreeFCapabilityWhitelistMock,
    ThreeFCapabilityTokenMock,
    ThreeFCapabilityRequestMock,
    ThreeFCapabilityFacilityMock,
    ThreeFCapabilityCollateralMock,
    ThreeFCapabilityPositionManagerMock
} from "test/mocks/ThreeFCapabilityPushMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

contract ThreeFCapabilityTest is CapabilityTestBase {
    uint128 internal constant PRINCIPAL = 100_000e6;
    uint128 internal constant YIELD = 2000e6;
    ThreeFCapabilityTokenMock internal asset;
    ThreeFCapabilityWhitelistMock internal whitelist;
    ThreeFCapabilityFacilityMock internal facility;
    ThreeFCapability internal implementation;
    ThreeFCapability internal capability;
    ThreeFCapabilityRequestMock internal request;
    address internal underlying = makeAddr("underlying");
    uint256 internal nextIntent;

    function setUp() public {
        asset = new ThreeFCapabilityTokenMock();
        whitelist = new ThreeFCapabilityWhitelistMock();
        facility = new ThreeFCapabilityFacilityMock();
        implementation = new ThreeFCapability(address(whitelist), address(facility));
        _deployAdapter(address(asset));
        _installCapability(adapter, address(implementation), _threeFSelectors());
        capability = ThreeFCapability(address(adapter));
        request = _newRequest(underlying);
        _configure(underlying, 0, type(uint256).max);
        asset.mint(address(adapter), PRINCIPAL);
    }

    function test_MintUsesAdapterAuthorizationAndKeepsPositionsOnAdapter() public {
        _authorizeAndApprove(request, PRINCIPAL, YIELD);
        request.authorizeMinting(address(implementation), 1, 1);
        _mint(request, PRINCIPAL, YIELD, block.timestamp);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(address(implementation)), 0);
        assertEq(asset.balanceOf(address(request)), PRINCIPAL);
        assertEq(request.mintCaller(), address(adapter));
        _assertPosition(request, address(adapter), PRINCIPAL, YIELD);
        _assertPosition(request, address(implementation), 0, 0);
        assertEq(capability.requests(0), address(request));
        assertEq(capability.requestIndex(address(request)), 1);
        assertEq(capability.pendingAssets(address(request)), PRINCIPAL);
        assertEq(capability.threeFPositionAssets(), PRINCIPAL);
        assertEq(request.principalCapAtMint(), PRINCIPAL);
        assertEq(request.yieldFloorAtMint(), YIELD);
        (uint128 principal, uint128 yieldAmount) = request.mintAuthorization(address(adapter));
        assertEq(principal, 0);
        assertEq(yieldAmount, 0);
    }

    function test_CapabilityDoesNotManageAllowances() public {
        request.authorizeMinting(address(adapter), PRINCIPAL, YIELD);
        IMerkleAdapter.Action[] memory calls =
            _publishCall(address(adapter), _mintData(request, PRINCIPAL, YIELD, block.timestamp));
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        adapter.manage(calls);
        _manage(address(asset), abi.encodeCall(IERC20.approve, (address(request), uint256(PRINCIPAL) + 17)));
        _mint(request, PRINCIPAL, YIELD, block.timestamp);
        assertEq(asset.allowance(address(adapter), address(request)), 17);
    }

    function test_OnlySelfCanMintConfigureOrFinalize() public {
        vm.expectRevert(ICapability.InvalidCaller.selector);
        capability.mintRequest(address(request), PRINCIPAL, YIELD, block.timestamp);
        vm.expectRevert(ICapability.InvalidCaller.selector);
        capability.setMinYieldPerRequest(underlying, 1);
        vm.expectRevert(ICapability.InvalidCaller.selector);
        capability.setMaxAssetsPerDuration(underlying, PRINCIPAL, 1 days);
        vm.expectRevert(ICapability.InvalidCaller.selector);
        capability.finalizeRequest(address(request));
        vm.expectRevert(ICapability.InvalidCaller.selector);
        implementation.setMaxAssetsPerDuration(underlying, PRINCIPAL, 1 days);
    }

    function test_ImplementationAuthorizationDoesNotAuthorizeAdapter() public {
        request.authorizeMinting(address(implementation), PRINCIPAL, YIELD);
        _expectMintRevert(
            request, PRINCIPAL, YIELD, block.timestamp, IThreeFCapability.InvalidMintAuthorization.selector
        );
    }

    function test_ZeroAuthorizationAndZeroYieldRejected() public {
        _expectMintRevert(request, PRINCIPAL, 0, block.timestamp, IThreeFCapability.InvalidMintAuthorization.selector);
        request.authorizeMinting(address(adapter), PRINCIPAL, 0);
        _expectMintRevert(request, PRINCIPAL, 0, block.timestamp, IThreeFCapability.InvalidMintAuthorization.selector);
        request.authorizeMinting(address(adapter), 0, YIELD);
        _expectMintRevert(request, PRINCIPAL, 0, block.timestamp, IThreeFCapability.InvalidMintAuthorization.selector);
    }

    function test_LiveAuthorizationBoundsAndDeadline() public {
        _authorizeAndApprove(request, PRINCIPAL, YIELD);
        _expectMintRevert(request, PRINCIPAL - 1, YIELD, block.timestamp, IThreeFCapability.SlippageExceeded.selector);
        _expectMintRevert(request, PRINCIPAL, YIELD + 1, block.timestamp, IThreeFCapability.SlippageExceeded.selector);
        _expectMintRevert(
            request, PRINCIPAL, YIELD, block.timestamp - 1, IThreeFCapability.MintDeadlineExpired.selector
        );
        _mint(request, PRINCIPAL, YIELD, block.timestamp);
    }

    function test_MinYieldUsesCollateralUnderlyingAndFundingBudgetUsesPrincipal() public {
        _configure(underlying, 20_001, PRINCIPAL);
        _authorizeAndApprove(request, PRINCIPAL, YIELD);
        _expectMintRevert(request, PRINCIPAL, YIELD, block.timestamp, IThreeFCapability.TooLowYield.selector);
        _configure(underlying, 20_000, PRINCIPAL);
        _mint(request, PRINCIPAL, YIELD, block.timestamp);
        assertEq(capability.remainingAssets(underlying), 0);
        (uint256 maximum, uint256 duration, uint256 start, uint256 spent) = capability.assetLimits(underlying);
        assertEq(maximum, PRINCIPAL);
        assertEq(duration, 1 days);
        assertEq(start, block.timestamp);
        assertEq(spent, PRINCIPAL);
    }

    function test_PeriodBudgetSharedAcrossRequestsAndResetsAtBoundary() public {
        _configure(underlying, 0, PRINCIPAL);
        _authorizeAndApprove(request, PRINCIPAL, YIELD);
        _mint(request, PRINCIPAL, YIELD, block.timestamp);
        ThreeFCapabilityRequestMock second = _newRequest(underlying);
        asset.mint(address(adapter), PRINCIPAL);
        _authorizeAndApprove(second, PRINCIPAL, YIELD);
        _expectMintRevert(second, PRINCIPAL, YIELD, block.timestamp, IAssetRateLimits.AssetLimitExceeded.selector);
        vm.warp(block.timestamp + 1 days);
        _mint(second, PRINCIPAL, YIELD, block.timestamp);
        assertEq(capability.requestsLength(), 2);
    }

    function test_FundingAssetBudgetCannotEnableDifferentUnderlying() public {
        address other = makeAddr("other underlying");
        ThreeFCapabilityRequestMock second = _newRequest(other);
        _configure(address(asset), 0, PRINCIPAL);
        _authorizeAndApprove(second, PRINCIPAL, YIELD);
        _expectMintRevert(second, PRINCIPAL, YIELD, block.timestamp, IAssetRateLimits.UnconfiguredAsset.selector);
        _configure(other, 0, PRINCIPAL);
        _mint(second, PRINCIPAL, YIELD, block.timestamp);
        assertEq(capability.remainingAssets(other), 0);
        assertEq(capability.remainingAssets(address(asset)), PRINCIPAL);
    }

    function test_FinalizationReturnsFundsToAdapterAndDoesNotRefundBudget() public {
        _configure(underlying, 0, PRINCIPAL);
        _authorizeAndApprove(request, PRINCIPAL, YIELD);
        _mint(request, PRINCIPAL, YIELD, block.timestamp);
        asset.mint(address(request), YIELD);
        request.setCanWithdraw(true);
        _manage(address(adapter), abi.encodeCall(IThreeFCapability.finalizeRequest, (address(request))));
        assertEq(asset.balanceOf(address(adapter)), uint256(PRINCIPAL) + YIELD);
        assertEq(asset.balanceOf(address(implementation)), 0);
        assertEq(capability.requestsLength(), 0);
        assertEq(capability.requestIndex(address(request)), 0);
        assertEq(capability.pendingAssets(address(request)), 0);
        assertEq(capability.remainingAssets(underlying), 0);
        assertEq(capability.threeFPositionAssets(), 0);
    }

    function test_FinalizationStillWorksAfterDisablingUnderlying() public {
        _authorizeAndApprove(request, PRINCIPAL, YIELD);
        _mint(request, PRINCIPAL, YIELD, block.timestamp);
        _configure(underlying, 0, 0);
        request.setCanWithdraw(true);
        _manage(address(adapter), abi.encodeCall(IThreeFCapability.finalizeRequest, (address(request))));
        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL);
    }

    function test_ValuationExcludesIdleFundsAndUsesLiveRedemptionOnlyWhenReady() public {
        asset.mint(address(adapter), 7);
        _authorizeAndApprove(request, PRINCIPAL, YIELD);
        _mint(request, PRINCIPAL, YIELD, block.timestamp);
        assertEq(capability.threeFPositionAssets(), PRINCIPAL);
        request.setRevertBalancesOf(true);
        assertEq(capability.threeFPositionAssets(), PRINCIPAL);
        request.setRevertBalancesOf(false);
        asset.burn(address(request), 10_000e6);
        request.setCanWithdraw(true);
        assertEq(capability.threeFPositionAssets(), PRINCIPAL - 10_000e6);
        assertEq(asset.balanceOf(address(adapter)), 7);
    }

    function test_ReplacementPreservesPositionsBudgetsAndFinalization() public {
        _configure(underlying, 20_000, 2 * uint256(PRINCIPAL));
        _authorizeAndApprove(request, PRINCIPAL, YIELD);
        _mint(request, PRINCIPAL, YIELD, block.timestamp);
        adapter.removeCapability(address(implementation));
        _installCapability(
            adapter, address(new ThreeFCapability(address(whitelist), address(facility))), _threeFSelectors()
        );
        assertEq(capability.pendingAssets(address(request)), PRINCIPAL);
        assertEq(capability.remainingAssets(underlying), PRINCIPAL);
        assertEq(capability.minYieldPerRequest(underlying), 20_000);
        request.setCanWithdraw(true);
        _manage(address(adapter), abi.encodeCall(IThreeFCapability.finalizeRequest, (address(request))));
        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL);
    }

    function test_StorageUsesThreeFNamespace() public {
        _configure(underlying, 20_000, 2 * uint256(PRINCIPAL));
        _authorizeAndApprove(request, PRINCIPAL, YIELD);
        _mint(request, PRINCIPAL, YIELD, block.timestamp);
        uint256 base = 0xafa435bfb801b5ecfbd0eaecba05fcd8a4ce8cf748d229c095b069955e2c8600;
        assertEq(uint256(vm.load(address(adapter), bytes32(base))), 1);
        assertEq(uint256(vm.load(address(adapter), keccak256(abi.encode(base)))), uint160(address(request)));
        assertEq(uint256(vm.load(address(adapter), keccak256(abi.encode(address(request), base + 1)))), 1);
        assertEq(uint256(vm.load(address(adapter), keccak256(abi.encode(address(request), base + 2)))), PRINCIPAL);
        assertEq(uint256(vm.load(address(adapter), keccak256(abi.encode(underlying, base + 3)))), 20_000);
        uint256 limit = uint256(keccak256(abi.encode(underlying, base + 4)));
        assertEq(uint256(vm.load(address(adapter), bytes32(limit))), 2 * uint256(PRINCIPAL));
        assertEq(uint256(vm.load(address(adapter), bytes32(limit + 1))), 1 days);
        assertEq(uint256(vm.load(address(adapter), bytes32(limit + 2))), block.timestamp);
        assertEq(uint256(vm.load(address(adapter), bytes32(limit + 3))), PRINCIPAL);
    }

    function test_SharedImplementationKeepsBudgetsAndPositionsIsolated() public {
        _authorizeAndApprove(request, PRINCIPAL, YIELD);
        _mint(request, PRINCIPAL, YIELD, block.timestamp);
        MerkleAdapter first = adapter;
        _deployAdapter(address(asset));
        _installCapability(adapter, address(implementation), _threeFSelectors());
        assertEq(ThreeFCapability(address(adapter)).requestsLength(), 0);
        assertEq(ThreeFCapability(address(adapter)).remainingAssets(underlying), 0);
        assertEq(ThreeFCapability(address(first)).requestsLength(), 1);
        assertEq(implementation.requestsLength(), 0);
    }

    function test_WhitelistWrongAssetAndFacilityBindingAreEnforced() public {
        _authorizeAndApprove(request, PRINCIPAL, YIELD);
        whitelist.set(address(request), IThreeFWhitelist.WhitelistStatus.PausedWhitelisted);
        _expectMintRevert(request, PRINCIPAL, YIELD, block.timestamp, IThreeFCapability.NotRequest.selector);
        whitelist.set(address(request), IThreeFWhitelist.WhitelistStatus.Whitelisted);
        facility.setIntent(1, address(0x123), address(0), true);
        _expectMintRevert(request, PRINCIPAL, YIELD, block.timestamp, IThreeFCapability.RequestMismatch.selector);
        facility.setIntent(1, address(request), address(0), false);
        _expectMintRevert(request, PRINCIPAL, YIELD, block.timestamp, IThreeFCapability.UnsupportedTarget.selector);
        ThreeFCapabilityRequestMock wrong =
            new ThreeFCapabilityRequestMock(address(new ThreeFCapabilityTokenMock()), "request-2");
        whitelist.set(address(wrong), IThreeFWhitelist.WhitelistStatus.Whitelisted);
        _expectMintRevert(wrong, PRINCIPAL, YIELD, block.timestamp, IThreeFCapability.WrongAsset.selector);
    }

    function test_MalformedRequestNamesAreRejected() public {
        string[4] memory names = ["request-", "other-1", "request-1a", "request--1"];
        for (uint256 i; i < names.length; ++i) {
            request.setName(names[i]);
            _expectMintRevert(request, PRINCIPAL, YIELD, block.timestamp, IThreeFCapability.InvalidRequestName.selector);
        }
    }

    function test_OverflowingRequestIdRevertsWithoutChangingFunding() public {
        request.setName("request-115792089237316195423570985008687907853269984665640564039457584007913129639936");
        IMerkleAdapter.Action[] memory calls =
            _publishCall(address(adapter), _mintData(request, PRINCIPAL, YIELD, block.timestamp));
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        adapter.manage(calls);
        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL);
        assertEq(capability.requestsLength(), 0);
    }

    function test_DuplicateAndMaximumRequestCountAreEnforced() public {
        _authorizeAndApprove(request, PRINCIPAL, YIELD);
        _mint(request, PRINCIPAL, YIELD, block.timestamp);
        _expectMintRevert(request, PRINCIPAL, YIELD, block.timestamp, IThreeFCapability.AlreadyRequest.selector);
        for (uint256 i = 1; i < MAX_REQUESTS; ++i) {
            ThreeFCapabilityRequestMock next = _newRequest(underlying);
            asset.mint(address(adapter), 1);
            _authorizeAndApprove(next, 1, 1);
            _mint(next, 1, 1, block.timestamp);
        }
        ThreeFCapabilityRequestMock overflow = _newRequest(underlying);
        _expectMintRevert(overflow, 1, 1, block.timestamp, IThreeFCapability.TooManyRequests.selector);
    }

    function test_FinalizationMaintainsMovedRequestIndexAndRejectsUnknown() public {
        _authorizeAndApprove(request, PRINCIPAL, YIELD);
        _mint(request, PRINCIPAL, YIELD, block.timestamp);
        ThreeFCapabilityRequestMock second = _newRequest(underlying);
        asset.mint(address(adapter), 1);
        _authorizeAndApprove(second, 1, 1);
        _mint(second, 1, 1, block.timestamp);
        request.setCanWithdraw(true);
        _manage(address(adapter), abi.encodeCall(IThreeFCapability.finalizeRequest, (address(request))));
        assertEq(capability.requests(0), address(second));
        assertEq(capability.requestIndex(address(second)), 1);
        IMerkleAdapter.Action[] memory calls =
            _publishCall(address(adapter), abi.encodeCall(IThreeFCapability.finalizeRequest, (address(request))));
        vm.expectRevert(IThreeFCapability.NotRequest.selector);
        adapter.manage(calls);
    }

    function test_FailedMintRestoresFundingAuthorizationBudgetAndApproval() public {
        _configure(underlying, 0, PRINCIPAL);
        _authorizeAndApprove(request, PRINCIPAL, YIELD);
        request.setFailMint(true);
        _expectMintRevert(request, PRINCIPAL, YIELD, block.timestamp, ThreeFCapabilityRequestMock.MintFailed.selector);
        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL);
        assertEq(asset.allowance(address(adapter), address(request)), PRINCIPAL);
        assertEq(capability.requestsLength(), 0);
        assertEq(capability.remainingAssets(underlying), PRINCIPAL);
        (uint128 principal,) = request.mintAuthorization(address(adapter));
        assertEq(principal, PRINCIPAL);
    }

    function test_FailedRedemptionPreservesPosition() public {
        _authorizeAndApprove(request, PRINCIPAL, YIELD);
        _mint(request, PRINCIPAL, YIELD, block.timestamp);
        IMerkleAdapter.Action[] memory calls =
            _publishCall(address(adapter), abi.encodeCall(IThreeFCapability.finalizeRequest, (address(request))));
        vm.expectRevert(ThreeFCapabilityRequestMock.NotWithdrawable.selector);
        adapter.manage(calls);
        assertEq(capability.pendingAssets(address(request)), PRINCIPAL);
    }

    function test_CallbackCannotReenterManageOrCallCapabilityMutation() public {
        _authorizeAndApprove(request, PRINCIPAL, YIELD);
        request.setMintCallback(
            address(adapter), abi.encodeCall(IMerkleAdapter.manage, (new IMerkleAdapter.Action[](0)))
        );
        _mint(request, PRINCIPAL, YIELD, block.timestamp);
        assertFalse(request.callbackSuccess());
        assertEq(bytes4(request.callbackResult()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        ThreeFCapabilityRequestMock second = _newRequest(underlying);
        asset.mint(address(adapter), 1);
        _authorizeAndApprove(second, 1, 1);
        second.setMintCallback(
            address(adapter), abi.encodeCall(IThreeFCapability.setMinYieldPerRequest, (underlying, 1))
        );
        _mint(second, 1, 1, block.timestamp);
        assertFalse(second.callbackSuccess());
        assertEq(bytes4(second.callbackResult()), ICapability.InvalidCaller.selector);
        assertEq(capability.minYieldPerRequest(underlying), 0);
    }

    function test_UnexpectedBalanceChangeDuringMintRollsBack() public {
        asset.mint(address(adapter), 1);
        _authorizeAndApprove(request, PRINCIPAL, YIELD);
        request.setMintCallback(address(asset), abi.encodeCall(asset.burn, (address(adapter), 1)));
        _expectMintRevert(
            request, PRINCIPAL, YIELD, block.timestamp, IThreeFCapability.InvalidMintAuthorization.selector
        );
        assertEq(asset.balanceOf(address(adapter)), uint256(PRINCIPAL) + 1);
    }

    function testFuzz_ExactFundingPreservesIdleBalanceAndBudget(uint128 principal, uint128 yieldAmount, uint96 idle)
        public
    {
        principal = uint128(bound(principal, 1, type(uint128).max));
        yieldAmount = uint128(bound(yieldAmount, 1, type(uint128).max));
        asset.burn(address(adapter), PRINCIPAL);
        asset.mint(address(adapter), uint256(principal) + idle);
        _configure(underlying, 0, principal);
        _authorizeAndApprove(request, principal, yieldAmount);
        _mint(request, principal, yieldAmount, block.timestamp);
        assertEq(asset.balanceOf(address(adapter)), idle);
        assertEq(capability.threeFPositionAssets(), principal);
        assertEq(capability.remainingAssets(underlying), 0);
        assertEq(asset.balanceOf(address(implementation)), 0);
    }

    function _newRequest(address riskAsset) internal returns (ThreeFCapabilityRequestMock created) {
        uint256 id = ++nextIntent;
        created = new ThreeFCapabilityRequestMock(address(asset), string.concat("request-", vm.toString(id)));
        whitelist.set(address(created), IThreeFWhitelist.WhitelistStatus.Whitelisted);
        facility.setIntent(
            id,
            address(created),
            address(new ThreeFCapabilityPositionManagerMock(address(new ThreeFCapabilityCollateralMock(riskAsset)))),
            true
        );
    }

    function _configure(address riskAsset, uint256 minYield, uint256 maxAssets) internal {
        _manage(address(adapter), abi.encodeCall(IThreeFCapability.setMinYieldPerRequest, (riskAsset, minYield)));
        _manage(
            address(adapter), abi.encodeCall(IAssetRateLimits.setMaxAssetsPerDuration, (riskAsset, maxAssets, 1 days))
        );
    }

    function _authorizeAndApprove(ThreeFCapabilityRequestMock target, uint128 principal, uint128 yieldAmount) internal {
        target.authorizeMinting(address(adapter), principal, yieldAmount);
        _manage(address(asset), abi.encodeCall(IERC20.approve, (address(target), principal)));
    }

    function _mint(ThreeFCapabilityRequestMock target, uint128 principal, uint128 yieldAmount, uint256 deadline)
        internal
    {
        _manage(address(adapter), _mintData(target, principal, yieldAmount, deadline));
    }

    function _mintData(ThreeFCapabilityRequestMock target, uint128 principal, uint128 yieldAmount, uint256 deadline)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(IThreeFCapability.mintRequest, (address(target), principal, yieldAmount, deadline));
    }

    function _expectMintRevert(
        ThreeFCapabilityRequestMock target,
        uint128 principal,
        uint128 yieldAmount,
        uint256 deadline,
        bytes4 errorSelector
    ) internal {
        IMerkleAdapter.Action[] memory calls =
            _publishCall(address(adapter), _mintData(target, principal, yieldAmount, deadline));
        vm.expectRevert(errorSelector);
        adapter.manage(calls);
    }

    function _assertPosition(
        ThreeFCapabilityRequestMock target,
        address account,
        uint256 principal,
        uint256 yieldAmount
    ) internal view {
        (uint256 pt, uint256 yt) = target.balancesOf(account);
        assertEq(pt, principal);
        assertEq(yt, yieldAmount);
    }
}
