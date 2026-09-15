// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";

import {ThreeFCapability} from "src/contracts/merkle_adapter/ThreeFCapability.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {IThreeFCapability, MAX_REQUESTS} from "src/interfaces/merkle_adapter/IThreeFCapability.sol";
import {IThreeFRequestCallback} from "src/interfaces/3f-adapter/IThreeFRequestCallback.sol";
import {IThreeFWhitelist} from "src/interfaces/3f-adapter/IThreeFWhitelist.sol";
import {Offer} from "src/interfaces/3f-adapter/ThreeFTypes.sol";

import {ThreeFCapabilityV1} from "test/mocks/ThreeFCapabilityV1.sol";
import {IThreeFCapabilityV1} from "test/mocks/IThreeFCapabilityV1.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    ThreeFCapabilityAdapterMock,
    ThreeFCapabilityVaultMock,
    ThreeFCapabilityWhitelistMock,
    ThreeFCapabilityTokenMock,
    ThreeFCapabilityRequestMock,
    ThreeFCapabilityFacilityMock,
    ThreeFCapabilityCollateralMock,
    ThreeFCapabilityPositionManagerMock
} from "test/mocks/ThreeFCapabilityPushMocks.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

contract ThreeFCapabilityTest is Test {
    uint256 internal constant PRINCIPAL = 100_000e6;
    uint256 internal constant YIELD = 2000e6;

    ThreeFCapabilityTokenMock internal asset;
    ThreeFCapabilityVaultMock internal vault;
    ThreeFCapabilityAdapterMock internal adapter;
    ThreeFCapabilityWhitelistMock internal whitelist;
    MigratablesFactory internal capabilityFactory;
    ThreeFCapability internal capability;
    ThreeFCapabilityRequestMock internal request;

    address internal adapterOwner = makeAddr("adapterOwner");
    address internal underlying = makeAddr("rwaUnderlying");
    ThreeFCapabilityFacilityMock internal facility;
    uint256 internal nextIntentId;
    mapping(address => uint256) internal intentIds;
    mapping(address => address) internal positionManagers;

    function setUp() public {
        asset = new ThreeFCapabilityTokenMock();
        vault = new ThreeFCapabilityVaultMock(address(asset));
        adapter = new ThreeFCapabilityAdapterMock(address(vault), adapterOwner);
        whitelist = new ThreeFCapabilityWhitelistMock();
        facility = new ThreeFCapabilityFacilityMock();
        capabilityFactory = new MigratablesFactory(address(this));
        capabilityFactory.whitelist(
            address(new ThreeFCapability(address(capabilityFactory), address(whitelist), address(facility)))
        );
        capability = ThreeFCapability(
            capabilityFactory.create(capabilityFactory.lastVersion(), adapterOwner, abi.encode(address(adapter)))
        );
        request = _newRequest(address(asset));

        _setLimits(0, 1, type(uint256).max);
    }

    function test_FactoryCreationInitializesAdapterOwnerFactoryAndVersion() public view {
        assertEq(capability.adapter(), address(adapter));
        assertEq(capability.REQUEST_WHITELIST(), address(whitelist));
        assertEq(capability.FACILITY(), address(facility));
        assertEq(capability.FACTORY(), address(capabilityFactory));
        assertEq(capability.version(), capabilityFactory.lastVersion());
        assertEq(capability.owner(), adapterOwner);
    }

    function test_MigratePreservesConfigurationAndActiveRequestAccounting() public {
        _setLimits(20_000, 10e6, 200_000e6);
        _fundAndApprove(PRINCIPAL);
        _mint(request, PRINCIPAL, YIELD);
        capabilityFactory.whitelist(
            address(new ThreeFCapability(address(capabilityFactory), address(whitelist), address(facility)))
        );
        uint64 newVersion = capabilityFactory.lastVersion();

        vm.prank(adapterOwner);
        capabilityFactory.migrate(address(capability), newVersion, bytes(""));

        assertEq(capability.version(), newVersion);
        assertEq(capability.owner(), adapterOwner);
        assertEq(capability.adapter(), address(adapter));
        _assertLimits(capability, underlying, 20_000, 10e6, 200_000e6);
        assertEq(capability.requestsLength(), 1);
        assertEq(capability.requests(0), address(request));
        assertEq(capability.requestIndex(address(request)), 1);
        assertEq(capability.pendingAssets(address(request)), PRINCIPAL);
        assertEq(capability.totalAssets(), PRINCIPAL);
    }

    function test_MigrateRejectsNonEmptyDataAndKeepsVersion() public {
        capabilityFactory.whitelist(
            address(new ThreeFCapability(address(capabilityFactory), address(whitelist), address(facility)))
        );
        uint64 newVersion = capabilityFactory.lastVersion();

        vm.prank(adapterOwner);
        vm.expectRevert(IThreeFCapability.InvalidMigrationData.selector);
        capabilityFactory.migrate(address(capability), newVersion, hex"01");

        assertEq(capability.version(), 1);
    }

    function test_SetLimitsPerRequestStoresValuesAndRejectsNonAdapter() public {
        vm.expectEmit(false, false, false, true, address(capability));
        emit IThreeFCapability.SetLimitsPerRequest(underlying, 10, 20, 30);
        _setLimits(10, 20, 30);
        _assertLimits(capability, underlying, 10, 20, 30);

        vm.expectRevert(IThreeFCapability.InvalidCaller.selector);
        capability.setLimitsPerRequest(underlying, 0, 1, type(uint256).max);
    }

    function test_GetMaxAssetsSelectorIsUnavailable() public {
        (bool success,) = address(capability).call(abi.encodeWithSelector(bytes4(keccak256("getMaxAssets()"))));

        assertFalse(success);
    }

    function test_MintRequestPullsPrincipalFromAdapterAndTracksRequest() public {
        _fundAndApprove(PRINCIPAL);

        _mint(request, PRINCIPAL, YIELD);

        assertEq(asset.balanceOf(address(request)), PRINCIPAL);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(address(capability)), 0);
        assertEq(capability.totalAssets(), PRINCIPAL);
        assertEq(capability.requestsLength(), 1);
        assertEq(capability.requests(0), address(request));
        assertEq(capability.requestIndex(address(request)), 1);
        assertEq(capability.pendingAssets(address(request)), PRINCIPAL);
    }

    /// @dev A ready push authorization must fund and track a position through an adapter-initiated mint.
    function test_MintRequestFundsAuthorizedPrincipalFromAdapter() public {
        _fundAndApprove(PRINCIPAL);
        request.authorizeMinting(address(capability), uint128(PRINCIPAL), uint128(YIELD));

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
        assertEq(asset.balanceOf(address(capability)), 0);
        assertEq(capability.pendingAssets(address(request)), PRINCIPAL);
        assertEq(capability.totalAssets(), PRINCIPAL);
        (uint256 principalShares, uint256 yieldShares) = request.balancesOf(address(capability));
        assertEq(principalShares, PRINCIPAL);
        assertEq(yieldShares, YIELD);
    }

    function test_TotalAssetsUsesPendingPrincipalBeforeWithdrawable() public {
        _fundAndApprove(PRINCIPAL);
        _mint(request, PRINCIPAL, YIELD);
        request.pull(makeAddr("borrower"), PRINCIPAL - 1);
        request.setRevertBalancesOf(true);

        assertEq(asset.balanceOf(address(request)), 1);
        assertEq(capability.totalAssets(), PRINCIPAL);
    }

    function test_TotalAssetsUsesLiveConversionWhenWithdrawable() public {
        _fundAndApprove(PRINCIPAL);
        _mint(request, PRINCIPAL, YIELD);
        request.pull(makeAddr("loss"), 10_000e6);
        request.setCanWithdraw(true);

        assertEq(capability.totalAssets(), PRINCIPAL - 10_000e6);

        asset.mint(address(request), YIELD);
        assertEq(capability.totalAssets(), PRINCIPAL - 10_000e6 + YIELD);
    }

    function test_MintRequestRejectsDuplicateAndMoreThanMaximumRequests() public {
        asset.mint(address(adapter), PRINCIPAL + MAX_REQUESTS * 1e6);
        adapter.approve(address(asset), address(capability), type(uint256).max);
        _mint(request, PRINCIPAL, YIELD);

        _expectConsumeRevert(IThreeFCapability.AlreadyRequest.selector, request, PRINCIPAL, YIELD);

        for (uint256 i = 1; i < MAX_REQUESTS; ++i) {
            _mint(_newRequest(address(asset)), 1e6, 1);
        }
        _expectConsumeRevert(IThreeFCapability.TooManyRequests.selector, _newRequest(address(asset)), 1e6, 1);
    }

    function test_MintRequestRejectsUnknownPausedAndWrongAssetRequests() public {
        whitelist.set(address(request), IThreeFWhitelist.WhitelistStatus.NotWhitelisted);
        _expectConsumeRevert(IThreeFCapability.NotRequest.selector, request, PRINCIPAL, YIELD);

        whitelist.set(address(request), IThreeFWhitelist.WhitelistStatus.PausedWhitelisted);
        _expectConsumeRevert(IThreeFCapability.NotRequest.selector, request, PRINCIPAL, YIELD);

        ThreeFCapabilityRequestMock wrongRequest = _newRequest(address(new ThreeFCapabilityTokenMock()));
        _expectConsumeRevert(IThreeFCapability.WrongAsset.selector, wrongRequest, PRINCIPAL, YIELD);
    }

    function test_MintRequestRejectsSmallLargeAndLowYieldRequests() public {
        _setLimits(0, PRINCIPAL + 1, type(uint256).max);
        _expectConsumeRevert(IThreeFCapability.TooSmallRequest.selector, request, PRINCIPAL, YIELD);

        _setLimits(0, 1, PRINCIPAL - 1);
        _expectConsumeRevert(IThreeFCapability.TooLargeRequest.selector, request, PRINCIPAL, YIELD);

        _setLimits(30_000, 1, type(uint256).max);
        _expectConsumeRevert(IThreeFCapability.TooLowYield.selector, request, PRINCIPAL, YIELD);
    }

    function test_MintRequestPropagatesAdapterAllowanceAndBalanceFailures() public {
        asset.mint(address(adapter), PRINCIPAL);
        request.authorizeMinting(address(capability), uint128(PRINCIPAL), uint128(YIELD));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(capability), uint256(0), PRINCIPAL
            )
        );
        _mintWithBounds(request, PRINCIPAL, YIELD, block.timestamp);

        adapter.approve(address(asset), address(capability), type(uint256).max);
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
        capability.finalizeRequest(address(request));

        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL + YIELD);
        assertEq(asset.balanceOf(address(capability)), 0);
        assertEq(capability.requestsLength(), 0);
        assertEq(capability.requestIndex(address(request)), 0);
        assertEq(capability.pendingAssets(address(request)), 0);
    }

    function test_FinalizeRequestKeepsUnrelatedCapabilityAssets() public {
        _fundAndApprove(PRINCIPAL);
        _mint(request, PRINCIPAL, YIELD);
        asset.mint(address(request), YIELD);
        asset.mint(address(capability), 1);
        request.setCanWithdraw(true);

        capability.finalizeRequest(address(request));

        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL + YIELD);
        assertEq(asset.balanceOf(address(capability)), 1);
    }

    function test_FinalizeRequestKeepsMovedRequestIndex() public {
        ThreeFCapabilityRequestMock secondRequest = _newRequest(address(asset));
        _fundAndApprove(PRINCIPAL + PRINCIPAL / 2);
        _mint(request, PRINCIPAL, YIELD);
        _mint(secondRequest, PRINCIPAL / 2, YIELD / 2);
        asset.mint(address(request), YIELD);
        asset.mint(address(secondRequest), YIELD / 2);
        request.setCanWithdraw(true);
        secondRequest.setCanWithdraw(true);

        capability.finalizeRequest(address(request));
        assertEq(capability.requestIndex(address(secondRequest)), 1);
        assertEq(capability.requests(0), address(secondRequest));

        capability.finalizeRequest(address(secondRequest));
        assertEq(capability.requestsLength(), 0);
        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL + YIELD + PRINCIPAL / 2 + YIELD / 2);
    }

    function test_FinalizeRequestRejectsUnknownRequest() public {
        vm.expectRevert(IThreeFCapability.NotRequest.selector);
        capability.finalizeRequest(makeAddr("unknownRequest"));
    }

    function _fundAndApprove(uint256 amount) internal {
        asset.mint(address(adapter), amount);
        adapter.approve(address(asset), address(capability), type(uint256).max);
    }

    function _execute(bytes memory data) internal returns (bytes memory result) {
        result = adapter.execute(address(capability), data);
    }

    function _expectExecuteRevert(bytes4 selector, bytes memory data) internal {
        vm.expectRevert(selector);
        _execute(data);
    }

    function _setLimits(uint256 minYield, uint256 minAssets, uint256 maxAssets) internal {
        _execute(abi.encodeCall(IThreeFCapability.setLimitsPerRequest, (underlying, minYield, minAssets, maxAssets)));
    }

    function _newRequest(address requestAsset) internal returns (ThreeFCapabilityRequestMock) {
        return _newRequestForUnderlying(requestAsset, underlying);
    }

    function _newRequestForUnderlying(address requestAsset, address riskAsset)
        internal
        returns (ThreeFCapabilityRequestMock newRequest)
    {
        uint256 id = ++nextIntentId;
        newRequest = new ThreeFCapabilityRequestMock(requestAsset, string.concat("request-", vm.toString(id)));
        ThreeFCapabilityCollateralMock collateral = new ThreeFCapabilityCollateralMock(riskAsset);
        ThreeFCapabilityPositionManagerMock positionManager =
            new ThreeFCapabilityPositionManagerMock(address(collateral));
        facility.setIntent(id, address(newRequest), address(positionManager), true);
        intentIds[address(newRequest)] = id;
        positionManagers[address(newRequest)] = address(positionManager);
        whitelist.set(address(newRequest), IThreeFWhitelist.WhitelistStatus.Whitelisted);
    }

    function _mint(ThreeFCapabilityRequestMock targetRequest, uint256 principal, uint256 yieldAmount) internal {
        targetRequest.authorizeMinting(address(capability), uint128(principal), uint128(yieldAmount));
        _mintWithBounds(targetRequest, principal, yieldAmount, block.timestamp);
    }

    function _mintWithBounds(
        ThreeFCapabilityRequestMock targetRequest,
        uint256 maxPrincipal,
        uint256 minYield,
        uint256 deadline
    ) internal {
        _execute(_mintData(targetRequest, maxPrincipal, minYield, deadline));
    }

    function _mintData(
        ThreeFCapabilityRequestMock targetRequest,
        uint256 maxPrincipal,
        uint256 minYield,
        uint256 deadline
    ) internal pure returns (bytes memory) {
        return abi.encodeCall(
            IThreeFCapability.mintRequest, (address(targetRequest), uint128(maxPrincipal), uint128(minYield), deadline)
        );
    }

    function _expectConsumeRevert(
        bytes4 selector,
        ThreeFCapabilityRequestMock targetRequest,
        uint256 principal,
        uint256 yieldAmount
    ) internal {
        targetRequest.authorizeMinting(address(capability), uint128(principal), uint128(yieldAmount));
        _expectMintRevert(selector, targetRequest, principal, yieldAmount, block.timestamp);
    }

    function _expectMintRevert(
        bytes4 selector,
        ThreeFCapabilityRequestMock targetRequest,
        uint256 maxPrincipal,
        uint256 minYield,
        uint256 deadline
    ) internal {
        vm.expectRevert(selector);
        _mintWithBounds(targetRequest, maxPrincipal, minYield, deadline);
    }

    function _assertLimits(
        ThreeFCapability target,
        address riskAsset,
        uint256 minYield,
        uint256 minPrincipal,
        uint256 maxPrincipal
    ) internal view {
        (uint256 actualYield, uint256 actualMin, uint256 actualMax) = target.limits(riskAsset);
        assertEq(actualYield, minYield);
        assertEq(actualMin, minPrincipal);
        assertEq(actualMax, maxPrincipal);
    }

    function _setAssetLimits(address riskAsset, uint256 minYield, uint256 minPrincipal, uint256 maxPrincipal) internal {
        _execute(
            abi.encodeCall(IThreeFCapability.setLimitsPerRequest, (riskAsset, minYield, minPrincipal, maxPrincipal))
        );
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
        request.authorizeMinting(address(capability), uint128(PRINCIPAL), uint128(YIELD));
        request.authorizeMinting(address(adapter), 1, 1);
        vm.expectEmit(true, true, false, true, address(capability));
        emit IThreeFCapability.MintRequest(address(request), underlying, PRINCIPAL, YIELD);

        _mintWithBounds(request, PRINCIPAL * 2, YIELD / 2, block.timestamp);

        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL);
        assertEq(request.mintCaller(), address(capability));
        assertEq(request.principalCapAtMint(), PRINCIPAL);
        assertEq(request.yieldFloorAtMint(), YIELD);
        assertEq(request.allowanceAtMint(), PRINCIPAL);
        assertEq(request.mintCalls(), 1);
        _assertAuthorization(request, address(capability), 0, 0);
        _assertAuthorization(request, address(adapter), 1, 1);
        _assertPosition(request, address(capability), PRINCIPAL, YIELD);
    }

    function test_MintRequestAndLimitsRejectOwnerAsCaller() public {
        _fundAndApprove(PRINCIPAL);
        request.authorizeMinting(address(capability), uint128(PRINCIPAL), uint128(YIELD));
        vm.expectRevert(IThreeFCapability.InvalidCaller.selector);
        capability.mintRequest(address(request), uint128(PRINCIPAL), uint128(YIELD), block.timestamp);
        vm.prank(adapterOwner);
        vm.expectRevert(IThreeFCapability.InvalidCaller.selector);
        capability.mintRequest(address(request), uint128(PRINCIPAL), uint128(YIELD), block.timestamp);
        vm.prank(adapterOwner);
        vm.expectRevert(IThreeFCapability.InvalidCaller.selector);
        capability.setLimitsPerRequest(underlying, 0, 1, PRINCIPAL);
        _assertUnminted(request, PRINCIPAL, PRINCIPAL, YIELD);
    }

    function test_MintRequestRejectsMissingAndZeroAuthorization() public {
        _fundAndApprove(PRINCIPAL);
        _expectMintRevert(IThreeFCapability.InvalidMintAuthorization.selector, request, PRINCIPAL, 0, block.timestamp);
        request.authorizeMinting(address(capability), 0, uint128(YIELD));
        _expectMintRevert(IThreeFCapability.InvalidMintAuthorization.selector, request, PRINCIPAL, 0, block.timestamp);
        request.authorizeMinting(address(capability), uint128(PRINCIPAL), 0);
        _expectMintRevert(IThreeFCapability.InvalidMintAuthorization.selector, request, PRINCIPAL, 0, block.timestamp);
        _assertUnminted(request, PRINCIPAL, PRINCIPAL, 0);
    }

    function test_MintRequestDoesNotUseAuthorizationForAdapterOrCaller() public {
        _fundAndApprove(PRINCIPAL);
        request.authorizeMinting(address(adapter), uint128(PRINCIPAL), uint128(YIELD));
        request.authorizeMinting(address(this), uint128(PRINCIPAL), uint128(YIELD));
        _expectMintRevert(
            IThreeFCapability.InvalidMintAuthorization.selector, request, PRINCIPAL, YIELD, block.timestamp
        );
        _assertUnminted(request, PRINCIPAL, 0, 0);
    }

    function test_MintRequestRejectsExpiredDeadlineAndAcceptsEquality() public {
        vm.warp(100);
        _fundAndApprove(PRINCIPAL);
        request.authorizeMinting(address(capability), uint128(PRINCIPAL), uint128(YIELD));
        _expectMintRevert(
            IThreeFCapability.MintDeadlineExpired.selector, request, PRINCIPAL, YIELD, block.timestamp - 1
        );
        _assertUnminted(request, PRINCIPAL, PRINCIPAL, YIELD);
        _mintWithBounds(request, PRINCIPAL, YIELD, block.timestamp);
        assertEq(capability.pendingAssets(address(request)), PRINCIPAL);
    }

    function test_MintRequestRejectsAuthorizationOutsideCallerBounds() public {
        _fundAndApprove(PRINCIPAL);
        request.authorizeMinting(address(capability), uint128(PRINCIPAL), uint128(YIELD));
        _expectMintRevert(IThreeFCapability.SlippageExceeded.selector, request, PRINCIPAL - 1, YIELD, block.timestamp);
        _expectMintRevert(IThreeFCapability.SlippageExceeded.selector, request, PRINCIPAL, YIELD + 1, block.timestamp);
        _assertUnminted(request, PRINCIPAL, PRINCIPAL, YIELD);
    }

    function test_MintRequestChecksOverwrittenAuthorizationAgainstCallerBounds() public {
        _fundAndApprove(PRINCIPAL * 2);
        request.authorizeMinting(address(capability), uint128(PRINCIPAL), uint128(YIELD));
        request.authorizeMinting(address(capability), uint128(PRINCIPAL + 1), uint128(YIELD));
        _expectMintRevert(IThreeFCapability.SlippageExceeded.selector, request, PRINCIPAL, YIELD, block.timestamp);
        request.authorizeMinting(address(capability), uint128(PRINCIPAL), uint128(YIELD - 1));
        _expectMintRevert(IThreeFCapability.SlippageExceeded.selector, request, PRINCIPAL, YIELD, block.timestamp);
        _assertUnminted(request, PRINCIPAL * 2, PRINCIPAL, YIELD - 1);
    }

    function test_PerAssetLimitsKeepDifferentUnderlyingRisksIndependent() public {
        address secondUnderlying = makeAddr("secondUnderlying");
        _setLimits(20_000, 10e6, PRINCIPAL);
        _setAssetLimits(secondUnderlying, 10_000, 1e6, PRINCIPAL / 2);
        _assertLimits(capability, underlying, 20_000, 10e6, PRINCIPAL);
        _assertLimits(capability, secondUnderlying, 10_000, 1e6, PRINCIPAL / 2);
        _assertLimits(capability, address(asset), 0, 0, 0);
        ThreeFCapabilityRequestMock secondRequest = _newRequestForUnderlying(address(asset), secondUnderlying);
        _fundAndApprove(PRINCIPAL * 2);
        _mint(request, PRINCIPAL, YIELD);
        _expectConsumeRevert(IThreeFCapability.TooLargeRequest.selector, secondRequest, PRINCIPAL, YIELD);
        _mint(secondRequest, PRINCIPAL / 2, YIELD / 2);
        assertEq(capability.requestsLength(), 2);
    }

    function test_MintRequestRejectsUnconfiguredUnderlyingDespiteConfiguredFundingAsset() public {
        ThreeFCapabilityRequestMock unknown = _newRequestForUnderlying(address(asset), makeAddr("unknownUnderlying"));
        _setAssetLimits(address(asset), 0, 0, type(uint256).max);
        _fundAndApprove(PRINCIPAL);
        _expectConsumeRevert(IThreeFCapability.UnconfiguredAsset.selector, unknown, PRINCIPAL, YIELD);
        _assertUnminted(unknown, PRINCIPAL, PRINCIPAL, YIELD);
    }

    function test_DisablingAssetBlocksNewMintButPreservesFinalization() public {
        _fundAndApprove(PRINCIPAL);
        _mint(request, PRINCIPAL, YIELD);
        _setLimits(0, 0, 0);
        _expectConsumeRevert(IThreeFCapability.UnconfiguredAsset.selector, _newRequest(address(asset)), 1, 1);
        asset.mint(address(request), YIELD);
        request.setCanWithdraw(true);
        capability.finalizeRequest(address(request));
        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL + YIELD);
        assertEq(capability.requestsLength(), 0);
    }

    function test_MintRequestChecksYieldPpmWithFloorRounding() public {
        _setLimits(1, 1, type(uint256).max);
        _expectConsumeRevert(IThreeFCapability.TooLowYield.selector, request, 1_000_001, 1);
        _fundAndApprove(1_000_000);
        _mint(request, 1_000_000, 1);
        assertEq(capability.pendingAssets(address(request)), 1_000_000);
    }

    function testFuzz_MintRequestAcceptsExactLimitsAndPreservesDust(uint128 principal, uint128 yieldAmount, uint96 dust)
        public
    {
        principal = uint128(bound(principal, 1, 1e30));
        yieldAmount = uint128(bound(yieldAmount, 1, principal));
        _setLimits(uint256(yieldAmount) * 1_000_000 / principal, principal, principal);
        _fundAndApprove(principal);
        asset.mint(address(capability), dust);
        _mint(request, principal, yieldAmount);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(address(capability)), dust);
        assertEq(asset.allowance(address(capability), address(request)), 0);
        assertEq(capability.pendingAssets(address(request)), principal);
        assertEq(capability.totalAssets(), uint256(principal) + dust);
        _assertPosition(request, address(capability), principal, yieldAmount);
    }

    function test_MintRequestRejectsMalformedRequestNames() public {
        string[8] memory names =
            ["", "request", "request-", "Request-1", "request--1", "request-1x", "request- 1", "other-1"];
        for (uint256 i; i < names.length; ++i) {
            request.setName(names[i]);
            _expectConsumeRevert(IThreeFCapability.InvalidRequestName.selector, request, PRINCIPAL, YIELD);
        }
    }

    function testFuzz_MintRequestRejectsNonDigitSuffix(bytes1 nonDigit) public {
        vm.assume(nonDigit < bytes1("0") || nonDigit > bytes1("9"));
        request.setName(string(abi.encodePacked("request-1", nonDigit, "2")));
        _expectConsumeRevert(IThreeFCapability.InvalidRequestName.selector, request, PRINCIPAL, YIELD);
    }

    function test_MintRequestRejectsOverflowingRequestId() public {
        request.setName("request-115792089237316195423570985008687907853269984665640564039457584007913129639936");
        request.authorizeMinting(address(capability), uint128(PRINCIPAL), uint128(YIELD));
        vm.expectRevert();
        _mintWithBounds(request, PRINCIPAL, YIELD, block.timestamp);
        assertEq(capability.requestsLength(), 0);
    }

    function testFuzz_MintRequestResolvesEntireDecimalRequestId(uint256 id) public {
        request.setName(string.concat("request-", vm.toString(id)));
        facility.setIntent(id, address(request), positionManagers[address(request)], true);
        _fundAndApprove(PRINCIPAL);
        _mint(request, PRINCIPAL, YIELD);
        assertEq(capability.pendingAssets(address(request)), PRINCIPAL);
    }

    function test_MintRequestRejectsFacilityRequestMismatchAndMissingIntent() public {
        facility.setIntent(
            intentIds[address(request)], makeAddr("otherRequest"), positionManagers[address(request)], true
        );
        _expectConsumeRevert(IThreeFCapability.RequestMismatch.selector, request, PRINCIPAL, YIELD);
        request.setName("request-999");
        _expectConsumeRevert(IThreeFCapability.RequestMismatch.selector, request, PRINCIPAL, YIELD);
    }

    function test_MintRequestRejectsNonPositionManagerTarget() public {
        facility.setIntent(intentIds[address(request)], address(request), positionManagers[address(request)], false);
        _expectConsumeRevert(IThreeFCapability.UnsupportedTarget.selector, request, PRINCIPAL, YIELD);
    }

    function test_MintRequestUsesCollateralUnderlyingFromTrustedFacilityTarget() public {
        address nextUnderlying = makeAddr("nextUnderlying");
        ThreeFCapabilityCollateralMock collateral = new ThreeFCapabilityCollateralMock(nextUnderlying);
        ThreeFCapabilityPositionManagerMock(positionManagers[address(request)]).setCollateral(address(collateral));
        _fundAndApprove(PRINCIPAL);
        _expectConsumeRevert(IThreeFCapability.UnconfiguredAsset.selector, request, PRINCIPAL, YIELD);
        _setAssetLimits(nextUnderlying, 20_000, PRINCIPAL, PRINCIPAL);
        _mint(request, PRINCIPAL, YIELD);
        assertEq(capability.pendingAssets(address(request)), PRINCIPAL);
    }

    function test_MintRequestUsesExactAllowanceAndKeepsDust() public {
        _fundAndApprove(PRINCIPAL);
        asset.mint(address(capability), 17);
        vm.prank(address(capability));
        asset.approve(address(request), type(uint256).max);
        _mint(request, PRINCIPAL, YIELD);
        assertEq(request.allowanceAtMint(), PRINCIPAL);
        assertEq(asset.allowance(address(capability), address(request)), 0);
        assertEq(asset.balanceOf(address(capability)), 17);
        assertEq(asset.balanceOf(address(adapter)), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(request), 0, 1)
        );
        request.pullFrom(address(capability), address(request), 1);
    }

    function test_MintRequestDoesNotUseDustToCoverUnfundedAdapter() public {
        asset.mint(address(capability), PRINCIPAL);
        adapter.approve(address(asset), address(capability), PRINCIPAL);
        request.authorizeMinting(address(capability), uint128(PRINCIPAL), uint128(YIELD));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(adapter), 0, PRINCIPAL)
        );
        _mintWithBounds(request, PRINCIPAL, YIELD, block.timestamp);
        assertEq(asset.balanceOf(address(capability)), PRINCIPAL);
        assertEq(capability.requestsLength(), 0);
    }

    function test_MintRequestRevertsFundingSharesAuthorizationAndAllowanceWhenMintFails() public {
        _fundAndApprove(PRINCIPAL);
        asset.mint(address(capability), 13);
        request.authorizeMinting(address(capability), uint128(PRINCIPAL), uint128(YIELD));
        request.setFailMint(true);
        _expectMintRevert(ThreeFCapabilityRequestMock.MintFailed.selector, request, PRINCIPAL, YIELD, block.timestamp);
        _assertUnminted(request, PRINCIPAL, PRINCIPAL, YIELD);
        assertEq(asset.balanceOf(address(capability)), 13);
        request.setFailMint(false);
        _mintWithBounds(request, PRINCIPAL, YIELD, block.timestamp);
        assertEq(capability.pendingAssets(address(request)), PRINCIPAL);
    }

    function test_MintRequestRejectsAuthorizationRevokedDuringFunding() public {
        _fundAndApprove(PRINCIPAL);
        request.authorizeMinting(address(capability), uint128(PRINCIPAL), uint128(YIELD));
        _replaceAuthorizationDuringFunding(0, 0);
        _expectMintRevert(
            IThreeFCapability.InvalidMintAuthorization.selector, request, PRINCIPAL, YIELD, block.timestamp
        );
        _assertUnminted(request, PRINCIPAL, PRINCIPAL, YIELD);
    }

    function test_MintRequestRejectsReducedPrincipalDuringFunding() public {
        _fundAndApprove(PRINCIPAL);
        request.authorizeMinting(address(capability), uint128(PRINCIPAL), uint128(YIELD));
        _replaceAuthorizationDuringFunding(PRINCIPAL - 1, YIELD);
        _expectMintRevert(
            IThreeFCapability.InvalidMintAuthorization.selector, request, PRINCIPAL, YIELD, block.timestamp
        );
        _assertUnminted(request, PRINCIPAL, PRINCIPAL, YIELD);
    }

    function test_MintRequestPinsPrincipalAndYieldAgainstFundingCallback() public {
        _fundAndApprove(PRINCIPAL * 2);
        request.authorizeMinting(address(capability), uint128(PRINCIPAL), uint128(YIELD));
        _replaceAuthorizationDuringFunding(PRINCIPAL + 1, YIELD);
        _expectMintRevert(
            ThreeFCapabilityRequestMock.SlippageExceeded.selector, request, PRINCIPAL * 2, 1, block.timestamp
        );
        _assertUnminted(request, PRINCIPAL * 2, PRINCIPAL, YIELD);
        _replaceAuthorizationDuringFunding(PRINCIPAL, YIELD - 1);
        _expectMintRevert(
            ThreeFCapabilityRequestMock.SlippageExceeded.selector, request, PRINCIPAL * 2, 1, block.timestamp
        );
        _assertUnminted(request, PRINCIPAL * 2, PRINCIPAL, YIELD);
    }

    function test_MintRequestRejectsLostDustDuringMint() public {
        _fundAndApprove(PRINCIPAL);
        asset.mint(address(capability), 1);
        request.setMintCallback(
            address(asset), abi.encodeCall(ThreeFCapabilityTokenMock.burn, (address(capability), 1))
        );
        _expectConsumeRevert(IThreeFCapability.InvalidMintAuthorization.selector, request, PRINCIPAL, YIELD);
        _assertUnminted(request, PRINCIPAL, PRINCIPAL, YIELD);
        assertEq(asset.balanceOf(address(capability)), 1);
    }

    function test_MintRequestBlocksReentryThroughBoundAdapter() public {
        _fundAndApprove(PRINCIPAL);
        request.setMintCallback(
            address(adapter),
            abi.encodeCall(
                ThreeFCapabilityAdapterMock.execute,
                (address(capability), _mintData(request, PRINCIPAL, YIELD, block.timestamp))
            )
        );
        _mint(request, PRINCIPAL, YIELD);
        assertFalse(request.callbackSuccess());
        assertEq(
            request.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(capability.requestsLength(), 1);
        assertEq(request.mintCalls(), 1);
    }

    function test_MintRequestBlocksReentrantFinalization() public {
        ThreeFCapabilityRequestMock second = _newRequest(address(asset));
        _fundAndApprove(PRINCIPAL * 2);
        _mint(request, PRINCIPAL, YIELD);
        request.setCanWithdraw(true);
        second.setMintCallback(
            address(capability), abi.encodeCall(IThreeFCapability.finalizeRequest, (address(request)))
        );
        _mint(second, PRINCIPAL, YIELD);
        assertFalse(second.callbackSuccess());
        assertEq(
            second.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(capability.requestsLength(), 2);
        _assertPosition(request, address(capability), PRINCIPAL, YIELD);
    }

    function test_FinalizeRequestBurnFailurePreservesTrackedPosition() public {
        _fundAndApprove(PRINCIPAL);
        _mint(request, PRINCIPAL, YIELD);
        vm.expectRevert(ThreeFCapabilityRequestMock.NotWithdrawable.selector);
        capability.finalizeRequest(address(request));
        assertEq(capability.requestsLength(), 1);
        assertEq(capability.pendingAssets(address(request)), PRINCIPAL);
        _assertPosition(request, address(capability), PRINCIPAL, YIELD);
    }

    function test_MigratePreservesMultiplePerAssetLimits() public {
        address secondUnderlying = makeAddr("secondUnderlying");
        _setLimits(20_000, 1e6, PRINCIPAL);
        _setAssetLimits(secondUnderlying, 30_000, 2e6, PRINCIPAL * 2);
        capabilityFactory.whitelist(
            address(new ThreeFCapability(address(capabilityFactory), address(whitelist), address(facility)))
        );
        uint64 version = capabilityFactory.lastVersion();
        vm.prank(adapterOwner);
        capabilityFactory.migrate(address(capability), version, "");
        _assertLimits(capability, underlying, 20_000, 1e6, PRINCIPAL);
        _assertLimits(capability, secondUnderlying, 30_000, 2e6, PRINCIPAL * 2);
    }

    function test_LegacyMigrationPreservesStoragePositionsAndStartsAssetLimitsClosed() public {
        ThreeFCapabilityV1 legacy = _newLegacyCapability();
        ThreeFCapabilityRequestMock second = _newRequest(address(asset));
        _legacyConsume(legacy, request, PRINCIPAL, YIELD);
        _legacyConsume(legacy, second, PRINCIPAL / 2, YIELD / 2);
        asset.mint(address(legacy), 9);
        bytes32[8] memory oldSlots;
        for (uint256 i; i < oldSlots.length; ++i) {
            oldSlots[i] = vm.load(address(legacy), bytes32(i + 10));
        }
        ThreeFCapability upgraded = _upgradeLegacy(legacy);
        assertEq(upgraded.adapter(), address(adapter));
        assertEq(upgraded.owner(), adapterOwner);
        assertEq(upgraded.FACILITY(), address(facility));
        for (uint256 i; i < oldSlots.length; ++i) {
            assertEq(vm.load(address(upgraded), bytes32(i + 10)), oldSlots[i]);
        }
        _assertLimits(upgraded, underlying, 0, 0, 0);
        _assertLimits(upgraded, address(asset), 0, 0, 0);
        assertEq(upgraded.requestsLength(), 2);
        assertEq(upgraded.requests(0), address(request));
        assertEq(upgraded.requests(1), address(second));
        assertEq(upgraded.requestIndex(address(request)), 1);
        assertEq(upgraded.requestIndex(address(second)), 2);
        assertEq(upgraded.pendingAssets(address(request)), PRINCIPAL);
        assertEq(upgraded.pendingAssets(address(second)), PRINCIPAL / 2);
        assertEq(upgraded.totalAssets(), PRINCIPAL + PRINCIPAL / 2 + 9);
        ThreeFCapabilityRequestMock next = _newRequest(address(asset));
        next.authorizeMinting(address(upgraded), uint128(PRINCIPAL), uint128(YIELD));
        vm.expectRevert(IThreeFCapability.UnconfiguredAsset.selector);
        adapter.execute(address(upgraded), _mintData(next, PRINCIPAL, YIELD, block.timestamp));
        asset.mint(address(request), YIELD);
        request.setCanWithdraw(true);
        upgraded.finalizeRequest(address(request));
        assertEq(upgraded.requests(0), address(second));
        assertEq(upgraded.requestIndex(address(second)), 1);
        assertEq(asset.balanceOf(address(adapter)), PRINCIPAL + YIELD);
        assertEq(upgraded.totalAssets(), PRINCIPAL / 2 + 9);
        adapter.execute(
            address(upgraded), abi.encodeCall(IThreeFCapability.setLimitsPerRequest, (underlying, 20_000, 1, PRINCIPAL))
        );
        adapter.execute(address(upgraded), _mintData(next, PRINCIPAL, YIELD, block.timestamp));
        assertEq(upgraded.requestsLength(), 2);
        assertEq(upgraded.pendingAssets(address(next)), PRINCIPAL);
        assertEq(asset.balanceOf(address(upgraded)), 9);
    }

    function test_LegacyMigrationDisablesPullSignerAndNonceSelectors() public {
        ThreeFCapability upgraded = _upgradeLegacy(_newLegacyCapability());
        _assertLegacySelectorsRemoved(address(upgraded));
        Offer memory offer = _offer(address(upgraded), PRINCIPAL, YIELD, type(uint256).max);
        vm.expectRevert();
        request.consume(address(upgraded), offer, "", PRINCIPAL, YIELD);
        assertEq(upgraded.requestsLength(), 0);
    }

    function test_PushImplementationDisablesPullSignerAndNonceSelectors() public {
        _assertLegacySelectorsRemoved(address(capability));
        Offer memory offer = _offer(address(capability), PRINCIPAL, YIELD, type(uint256).max);
        vm.expectRevert();
        request.consume(address(capability), offer, "", PRINCIPAL, YIELD);
    }

    function _replaceAuthorizationDuringFunding(uint256 principal, uint256 yieldAmount) internal {
        asset.setTransferFromCallback(
            address(adapter),
            address(request),
            abi.encodeCall(
                ThreeFCapabilityRequestMock.authorizeMinting,
                (address(capability), uint128(principal), uint128(yieldAmount))
            )
        );
    }

    function _assertAuthorization(
        ThreeFCapabilityRequestMock target,
        address account,
        uint256 principal,
        uint256 yieldAmount
    ) internal view {
        (uint128 actualPrincipal, uint128 actualYield) = target.mintAuthorization(account);
        assertEq(actualPrincipal, principal);
        assertEq(actualYield, yieldAmount);
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

    function _assertUnminted(
        ThreeFCapabilityRequestMock target,
        uint256 adapterBalance,
        uint256 principal,
        uint256 yieldAmount
    ) internal view {
        assertEq(asset.balanceOf(address(adapter)), adapterBalance);
        assertEq(asset.balanceOf(address(target)), 0);
        assertEq(asset.allowance(address(capability), address(target)), 0);
        assertEq(capability.requestIndex(address(target)), 0);
        assertEq(capability.pendingAssets(address(target)), 0);
        assertEq(target.mintCalls(), 0);
        _assertPosition(target, address(capability), 0, 0);
        _assertAuthorization(target, address(capability), principal, yieldAmount);
    }

    function _newLegacyCapability() internal returns (ThreeFCapabilityV1 legacy) {
        capabilityFactory.whitelist(address(new ThreeFCapabilityV1(address(capabilityFactory), address(whitelist))));
        legacy = ThreeFCapabilityV1(
            capabilityFactory.create(capabilityFactory.lastVersion(), adapterOwner, abi.encode(address(adapter)))
        );
        adapter.execute(address(legacy), abi.encodeCall(IThreeFCapabilityV1.setOfferSigner, (makeAddr("legacySigner"))));
        adapter.execute(
            address(legacy), abi.encodeCall(IThreeFCapabilityV1.setLimitsPerRequest, (20_000, 1, PRINCIPAL * 2))
        );
        adapter.approve(address(asset), address(legacy), type(uint256).max);
    }

    function _upgradeLegacy(ThreeFCapabilityV1 legacy) internal returns (ThreeFCapability upgraded) {
        capabilityFactory.whitelist(
            address(new ThreeFCapability(address(capabilityFactory), address(whitelist), address(facility)))
        );
        uint64 version = capabilityFactory.lastVersion();
        vm.prank(adapterOwner);
        capabilityFactory.migrate(address(legacy), version, "");
        upgraded = ThreeFCapability(address(legacy));
        assertEq(upgraded.version(), version);
    }

    function _legacyConsume(
        ThreeFCapabilityV1 legacy,
        ThreeFCapabilityRequestMock target,
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
