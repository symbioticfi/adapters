// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ThreeFCapability} from "../../../src/contracts/merkle_adapter/ThreeFCapability.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {IThreeFCapability, MAX_REQUESTS} from "../../../src/interfaces/merkle_adapter/IThreeFCapability.sol";
import {IThreeFRequestCallback} from "../../../src/interfaces/3f-adapter/IThreeFRequestCallback.sol";
import {IThreeFWhitelist} from "../../../src/interfaces/3f-adapter/IThreeFWhitelist.sol";
import {Offer} from "../../../src/interfaces/3f-adapter/ThreeFTypes.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

contract ThreeFCapabilityTest is Test {
    uint256 internal constant SIGNER_PK = 0xB0B;
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
    address internal signer;

    function setUp() public {
        signer = vm.addr(SIGNER_PK);
        asset = new ThreeFCapabilityTokenMock();
        vault = new ThreeFCapabilityVaultMock(address(asset));
        adapter = new ThreeFCapabilityAdapterMock(address(vault), adapterOwner);
        whitelist = new ThreeFCapabilityWhitelistMock();
        capabilityFactory = new MigratablesFactory(address(this));
        capabilityFactory.whitelist(address(new ThreeFCapability(address(capabilityFactory), address(whitelist))));
        capability = ThreeFCapability(
            capabilityFactory.create(capabilityFactory.lastVersion(), adapterOwner, abi.encode(address(adapter)))
        );
        request = _newRequest(address(asset));

        _execute(abi.encodeCall(IThreeFCapability.setOfferSigner, (signer)));
        _setLimits(0, 1, type(uint256).max);
    }

    function test_FactoryCreationInitializesAdapterOwnerFactoryAndVersion() public view {
        assertEq(capability.adapter(), address(adapter));
        assertEq(capability.REQUEST_WHITELIST(), address(whitelist));
        assertEq(capability.FACTORY(), address(capabilityFactory));
        assertEq(capability.version(), capabilityFactory.lastVersion());
        assertEq(capability.owner(), adapterOwner);
    }

    function test_MigratePreservesConfigurationAndActiveRequestAccounting() public {
        _setLimits(20_000, 10e6, 200_000e6);
        _fundAndApprove(PRINCIPAL);
        _consume(request, PRINCIPAL, YIELD);
        capabilityFactory.whitelist(address(new ThreeFCapability(address(capabilityFactory), address(whitelist))));
        uint64 newVersion = capabilityFactory.lastVersion();

        vm.prank(adapterOwner);
        capabilityFactory.migrate(address(capability), newVersion, bytes(""));

        assertEq(capability.version(), newVersion);
        assertEq(capability.owner(), adapterOwner);
        assertEq(capability.adapter(), address(adapter));
        assertEq(capability.offerSigner(), signer);
        assertEq(capability.minYieldPerRequest(), 20_000);
        assertEq(capability.minAssetsPerRequest(), 10e6);
        assertEq(capability.maxAssetsPerRequest(), 200_000e6);
        assertEq(capability.requestsLength(), 1);
        assertEq(capability.requests(0), address(request));
        assertEq(capability.requestIndex(address(request)), 1);
        assertEq(capability.pendingAssets(address(request)), PRINCIPAL);
        assertEq(capability.totalAssets(), PRINCIPAL);
    }

    function test_MigrateRejectsNonEmptyDataAndKeepsVersion() public {
        capabilityFactory.whitelist(address(new ThreeFCapability(address(capabilityFactory), address(whitelist))));
        uint64 newVersion = capabilityFactory.lastVersion();

        vm.prank(adapterOwner);
        vm.expectRevert(IThreeFCapability.InvalidMigrationData.selector);
        capabilityFactory.migrate(address(capability), newVersion, hex"01");

        assertEq(capability.version(), 1);
    }

    function test_SetOfferSignerStoresValueAndRejectsNonAdapter() public {
        address newSigner = makeAddr("newSigner");
        vm.expectEmit(true, false, false, true, address(capability));
        emit IThreeFCapability.SetOfferSigner(newSigner);
        _execute(abi.encodeCall(IThreeFCapability.setOfferSigner, (newSigner)));
        assertEq(capability.offerSigner(), newSigner);

        vm.expectRevert(IThreeFCapability.InvalidCaller.selector);
        capability.setOfferSigner(signer);
    }

    function test_SetLimitsPerRequestStoresValuesAndRejectsNonAdapter() public {
        vm.expectEmit(false, false, false, true, address(capability));
        emit IThreeFCapability.SetLimitsPerRequest(10, 20, 30);
        _setLimits(10, 20, 30);
        assertEq(capability.minYieldPerRequest(), 10);
        assertEq(capability.minAssetsPerRequest(), 20);
        assertEq(capability.maxAssetsPerRequest(), 30);

        vm.expectRevert(IThreeFCapability.InvalidCaller.selector);
        capability.setLimitsPerRequest(0, 1, type(uint256).max);
    }

    function test_IsValidSignatureAcceptsConfiguredSignerAndRejectsOthers() public view {
        bytes32 digest = keccak256("3F offer digest");
        (uint8 validV, bytes32 validR, bytes32 validS) = vm.sign(SIGNER_PK, digest);
        (uint8 invalidV, bytes32 invalidR, bytes32 invalidS) = vm.sign(0xDEAD, digest);

        assertEq(
            capability.isValidSignature(digest, abi.encodePacked(validR, validS, validV)),
            IERC1271.isValidSignature.selector
        );
        assertEq(
            capability.isValidSignature(digest, abi.encodePacked(invalidR, invalidS, invalidV)), bytes4(0xffffffff)
        );
    }

    function test_SetRequestNonceForwardsAsCapability() public {
        vm.expectEmit(true, false, false, true, address(capability));
        emit IThreeFCapability.SetRequestNonce(address(request), 7);
        _execute(abi.encodeCall(IThreeFCapability.setRequestNonce, (address(request), 7)));

        assertEq(request.nonce(address(capability)), 7);
    }

    function test_SetRequestNonceRejectsNonAdapterUnknownPausedAndWrongAsset() public {
        vm.expectRevert(IThreeFCapability.InvalidCaller.selector);
        capability.setRequestNonce(address(request), 7);

        whitelist.set(address(request), IThreeFWhitelist.WhitelistStatus.NotWhitelisted);
        _expectExecuteRevert(
            IThreeFCapability.NotRequest.selector,
            abi.encodeCall(IThreeFCapability.setRequestNonce, (address(request), 7))
        );

        whitelist.set(address(request), IThreeFWhitelist.WhitelistStatus.PausedWhitelisted);
        _expectExecuteRevert(
            IThreeFCapability.NotRequest.selector,
            abi.encodeCall(IThreeFCapability.setRequestNonce, (address(request), 7))
        );

        ThreeFCapabilityRequestMock wrongRequest = _newRequest(address(new ThreeFCapabilityTokenMock()));
        _expectExecuteRevert(
            IThreeFCapability.WrongAsset.selector,
            abi.encodeCall(IThreeFCapability.setRequestNonce, (address(wrongRequest), 7))
        );
    }

    function test_GetMaxAssetsSelectorIsUnavailable() public {
        (bool success,) = address(capability).call(abi.encodeWithSelector(bytes4(keccak256("getMaxAssets()"))));

        assertFalse(success);
    }

    function test_ConsumePullsPrincipalFromAdapterAndTracksRequest() public {
        _fundAndApprove(PRINCIPAL);

        _consume(request, PRINCIPAL, YIELD);

        assertEq(asset.balanceOf(address(request)), PRINCIPAL);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(address(capability)), 0);
        assertEq(capability.totalAssets(), PRINCIPAL);
        assertEq(capability.requestsLength(), 1);
        assertEq(capability.requests(0), address(request));
        assertEq(capability.requestIndex(address(request)), 1);
        assertEq(capability.pendingAssets(address(request)), PRINCIPAL);
    }

    function test_TotalAssetsUsesPendingPrincipalBeforeWithdrawable() public {
        _fundAndApprove(PRINCIPAL);
        _consume(request, PRINCIPAL, YIELD);
        request.pull(makeAddr("borrower"), PRINCIPAL - 1);
        request.setRevertBalancesOf(true);

        assertEq(asset.balanceOf(address(request)), 1);
        assertEq(capability.totalAssets(), PRINCIPAL);
    }

    function test_TotalAssetsUsesLiveConversionWhenWithdrawable() public {
        _fundAndApprove(PRINCIPAL);
        _consume(request, PRINCIPAL, YIELD);
        request.pull(makeAddr("loss"), 10_000e6);
        request.setCanWithdraw(true);

        assertEq(capability.totalAssets(), PRINCIPAL - 10_000e6);

        asset.mint(address(request), YIELD);
        assertEq(capability.totalAssets(), PRINCIPAL - 10_000e6 + YIELD);
    }

    function test_ConsumeRejectsDuplicateAndMoreThanMaximumRequests() public {
        asset.mint(address(adapter), PRINCIPAL + MAX_REQUESTS * 1e6);
        adapter.approve(address(asset), address(capability), type(uint256).max);
        _consume(request, PRINCIPAL, YIELD);

        _expectConsumeRevert(IThreeFCapability.AlreadyRequest.selector, request, PRINCIPAL, YIELD);

        for (uint256 i = 1; i < MAX_REQUESTS; ++i) {
            _consume(_newRequest(address(asset)), 1e6, 1);
        }
        _expectConsumeRevert(IThreeFCapability.TooManyRequests.selector, _newRequest(address(asset)), 1e6, 1);
    }

    function test_ConsumeRejectsUnknownPausedAndWrongAssetRequests() public {
        whitelist.set(address(request), IThreeFWhitelist.WhitelistStatus.NotWhitelisted);
        _expectConsumeRevert(IThreeFCapability.NotRequest.selector, request, PRINCIPAL, YIELD);

        whitelist.set(address(request), IThreeFWhitelist.WhitelistStatus.PausedWhitelisted);
        _expectConsumeRevert(IThreeFCapability.NotRequest.selector, request, PRINCIPAL, YIELD);

        ThreeFCapabilityRequestMock wrongRequest = _newRequest(address(new ThreeFCapabilityTokenMock()));
        _expectConsumeRevert(IThreeFCapability.WrongAsset.selector, wrongRequest, PRINCIPAL, YIELD);
    }

    function test_ConsumeRejectsInvalidMakerCallbackFlagZeroReturnAndExpiry() public {
        Offer memory offer = _offer(address(capability), PRINCIPAL, YIELD, type(uint256).max);
        offer.maker = makeAddr("wrongMaker");
        _expectConsumeRevert(IThreeFCapability.InvalidOffer.selector, request, offer, PRINCIPAL, YIELD);

        offer = _offer(address(capability), PRINCIPAL, YIELD, type(uint256).max);
        offer.useCallback = false;
        _expectConsumeRevert(IThreeFCapability.InvalidOffer.selector, request, offer, PRINCIPAL, YIELD);

        offer = _offer(address(capability), PRINCIPAL, 0, type(uint256).max);
        _expectConsumeRevert(IThreeFCapability.InvalidOffer.selector, request, offer, PRINCIPAL, 0);

        offer = _offer(address(capability), PRINCIPAL, YIELD, block.timestamp - 1);
        _expectConsumeRevert(IThreeFCapability.ExpiredOffer.selector, request, offer, PRINCIPAL, YIELD);
    }

    function test_ConsumeRejectsSmallLargeAndLowYieldRequests() public {
        _setLimits(0, PRINCIPAL + 1, type(uint256).max);
        _expectConsumeRevert(IThreeFCapability.TooSmallRequest.selector, request, PRINCIPAL, YIELD);

        _setLimits(0, 1, PRINCIPAL - 1);
        _expectConsumeRevert(IThreeFCapability.TooLargeRequest.selector, request, PRINCIPAL, YIELD);

        _setLimits(30_000, 1, type(uint256).max);
        _expectConsumeRevert(IThreeFCapability.TooLowYield.selector, request, PRINCIPAL, YIELD);
    }

    function test_ConsumePropagatesAdapterAllowanceAndBalanceFailures() public {
        asset.mint(address(adapter), PRINCIPAL);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(capability), uint256(0), PRINCIPAL
            )
        );
        _consume(request, PRINCIPAL, YIELD);

        adapter.approve(address(asset), address(capability), type(uint256).max);
        asset.burn(address(adapter), PRINCIPAL);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(adapter), uint256(0), PRINCIPAL
            )
        );
        _consume(request, PRINCIPAL, YIELD);
    }

    function test_FinalizeRequestTransfersReturnedAssetsToAdapterAndRemovesRequest() public {
        _fundAndApprove(PRINCIPAL);
        _consume(request, PRINCIPAL, YIELD);
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
        _consume(request, PRINCIPAL, YIELD);
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
        _consume(request, PRINCIPAL, YIELD);
        _consume(secondRequest, PRINCIPAL / 2, YIELD / 2);
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
        _execute(abi.encodeCall(IThreeFCapability.setLimitsPerRequest, (minYield, minAssets, maxAssets)));
    }

    function _newRequest(address requestAsset) internal returns (ThreeFCapabilityRequestMock newRequest) {
        newRequest = new ThreeFCapabilityRequestMock(requestAsset);
        whitelist.set(address(newRequest), IThreeFWhitelist.WhitelistStatus.Whitelisted);
    }

    function _consume(ThreeFCapabilityRequestMock targetRequest, uint256 principal, uint256 yieldAmount) internal {
        targetRequest.consume(
            address(capability),
            _offer(address(capability), principal, yieldAmount, type(uint256).max),
            "",
            principal,
            yieldAmount
        );
    }

    function _expectConsumeRevert(
        bytes4 selector,
        ThreeFCapabilityRequestMock targetRequest,
        uint256 principal,
        uint256 yieldAmount
    ) internal {
        _expectConsumeRevert(
            selector,
            targetRequest,
            _offer(address(capability), principal, yieldAmount, type(uint256).max),
            principal,
            yieldAmount
        );
    }

    function _expectConsumeRevert(
        bytes4 selector,
        ThreeFCapabilityRequestMock targetRequest,
        Offer memory offer,
        uint256 principal,
        uint256 yieldAmount
    ) internal {
        vm.expectRevert(selector);
        targetRequest.consume(address(capability), offer, "", principal, yieldAmount);
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
}

contract ThreeFCapabilityAdapterMock {
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

contract ThreeFCapabilityVaultMock {
    address public immutable asset;

    constructor(address asset_) {
        asset = asset_;
    }
}

contract ThreeFCapabilityWhitelistMock is IThreeFWhitelist {
    mapping(address request => WhitelistStatus status) internal _statuses;

    function set(address request, WhitelistStatus status) external {
        _statuses[request] = status;
    }

    function isWhitelisted(address request) external view returns (WhitelistStatus status) {
        status = _statuses[request];
    }
}

contract ThreeFCapabilityTokenMock is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}

contract ThreeFCapabilityRequestMock {
    address public immutable asset;
    bool public canWithdraw;
    bool public revertBalancesOf;
    uint256 public ptSupply;
    uint256 public ytSupply;

    mapping(address account => uint256 balance) internal _ptBalances;
    mapping(address account => uint256 balance) internal _ytBalances;
    mapping(address account => uint256 currentNonce) public nonce;

    constructor(address asset_) {
        asset = asset_;
    }

    function setNonce(uint256 newNonce) external {
        if (nonce[msg.sender] >= newNonce) {
            revert();
        }
        nonce[msg.sender] = newNonce;
    }

    function setCanWithdraw(bool status) external {
        canWithdraw = status;
    }

    function setRevertBalancesOf(bool status) external {
        revertBalancesOf = status;
    }

    function balancesOf(address account) external view returns (uint256 ptShares, uint256 ytShares) {
        if (revertBalancesOf) {
            revert();
        }
        ptShares = _ptBalances[account];
        ytShares = _ytBalances[account];
    }

    function convertToAssets(uint256 ptShares, uint256 ytShares)
        public
        view
        returns (uint256 pAssets, uint256 yAssets)
    {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (ptSupply > 0) {
            pAssets = balance * ptShares / ptSupply;
        }
        if (ytSupply > 0 && balance > pAssets) {
            yAssets = (balance - pAssets) * ytShares / ytSupply;
        }
    }

    function pull(address receiver, uint256 amount) external {
        IERC20(asset).transfer(receiver, amount);
    }

    function consume(
        address capability,
        Offer calldata offer,
        bytes calldata signature,
        uint256 principal,
        uint256 yieldAmount
    ) external {
        IThreeFRequestCallback(capability).onRequestConsumed(offer, signature, principal, yieldAmount);

        IERC20(asset).transferFrom(capability, address(this), principal);
        _ptBalances[capability] += principal;
        _ytBalances[capability] += yieldAmount;
        ptSupply += principal;
        ytSupply += yieldAmount;
    }

    function burnAll(address owner, address receiver)
        external
        returns (uint256 ptShares, uint256 ytShares, uint256 pAssets, uint256 yAssets)
    {
        ptShares = _ptBalances[owner];
        ytShares = _ytBalances[owner];
        (pAssets, yAssets) = convertToAssets(ptShares, ytShares);

        _ptBalances[owner] = 0;
        _ytBalances[owner] = 0;
        ptSupply -= ptShares;
        ytSupply -= ytShares;

        IERC20(asset).transfer(receiver, pAssets + yAssets);
    }
}
