// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {ThreeFAdapter} from "src/contracts/ThreeFAdapter.sol";

import {IAdapter} from "src/interfaces/IAdapter.sol";
import {IThreeFAdapter} from "src/interfaces/IThreeFAdapter.sol";
import {Offer} from "src/interfaces/3f-adapter/ThreeFTypes.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Test} from "forge-std/Test.sol";

import {TestnetThreeFFacility, TestnetThreeFRequest} from "script/deploy/testnet/protocols/TestnetThreeF.sol";
import {TestnetToken} from "script/deploy/testnet/protocols/TestnetAssets.sol";

/// @title ThreeFModelVaultFactory
/// @notice Supplies the registry boundary for a factory-created production ThreeF adapter.
contract ThreeFModelVaultFactory {
    mapping(address entity => bool registered) public isEntity;

    constructor(address newVault) {
        isEntity[newVault] = true;
    }
}

/// @title ThreeFModelVault
/// @notice Holds real test assets and permits the fixture delegator to allocate them.
contract ThreeFModelVault {
    error InvalidCaller();

    address public immutable asset;
    address public delegator;

    constructor(address newAsset) {
        asset = newAsset;
    }

    function setDelegator(address newDelegator) public {
        delegator = newDelegator;
    }

    function pull(address recipient, uint256 amount) public {
        if (delegator != msg.sender) revert InvalidCaller();
        IERC20(asset).transfer(recipient, amount);
    }
}

/// @title ThreeFModelDelegator
/// @notice Enforces actual cash, adapter capacity, and a limit during just-in-time allocation.
contract ThreeFModelDelegator {
    address public immutable vault;
    uint256 public limit;

    constructor(address newVault, uint256 newLimit) {
        vault = newVault;
        limit = newLimit;
    }

    function setLimit(uint256 newLimit) public {
        limit = newLimit;
    }

    function allocateExact(address adapter, uint256 amount) public returns (uint256 allocated) {
        uint256 total = IAdapter(adapter).totalAssets();
        uint256 available = limit > total ? limit - total : 0;
        if (amount > available) amount = available;
        available = IERC20(ThreeFModelVault(vault).asset()).balanceOf(vault);
        if (amount > available) amount = available;
        available = IAdapter(adapter).allocatable();
        if (amount > available) amount = available;
        if (amount == 0) return 0;
        ThreeFModelVault(vault).pull(adapter, amount);
        allocated = IAdapter(adapter).allocate(amount);
    }
}

/// @title ThreeFModelTestBase
/// @notice Common funding fixtures and an independent EIP712 encoding for native ThreeF requests.
abstract contract ThreeFModelTestBase is Test {
    address internal _asset;
    address internal _request;
    address internal _alice;
    address internal _bob;
    uint256 internal _aliceKey;
    uint256 internal _bobKey;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        (_alice, _aliceKey) = makeAddrAndKey("ThreeF principal supplier Alice");
        (_bob, _bobKey) = makeAddrAndKey("ThreeF principal supplier Bob");
        _asset = address(new TestnetToken("ThreeF funded asset", "3FA", 6, address(this)));
        _request = address(new TestnetThreeFRequest(address(this), _asset, uint48(block.timestamp + 7 days), 1));
        TestnetToken(_asset).mint(address(this), 1_000_000e6);
        TestnetToken(_asset).mint(_alice, 1_000_000e6);
        TestnetToken(_asset).mint(_bob, 1_000_000e6);
        IERC20(_asset).approve(_request, type(uint256).max);
        vm.prank(_alice);
        IERC20(_asset).approve(_request, type(uint256).max);
        vm.prank(_bob);
        IERC20(_asset).approve(_request, type(uint256).max);
    }

    function _offer(address maker, uint256 principal, uint256 yieldAssets) internal view returns (Offer memory) {
        return Offer({
            maker: maker,
            amount: principal,
            expectedReturn: yieldAssets,
            nonce: TestnetThreeFRequest(_request).nonce(maker),
            expiration: block.timestamp + 1 days,
            useCallback: false
        });
    }

    function _digest(address request, Offer memory offer) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("TestnetThreeFRequest"),
                keccak256("1"),
                block.chainid,
                request
            )
        );
        bytes32 order = keccak256(
            abi.encode(
                keccak256(
                    "Offer(address maker,uint256 amount,uint256 expectedReturn,uint256 nonce,uint256 expiration,bool useCallback)"
                ),
                offer.maker,
                offer.amount,
                offer.expectedReturn,
                offer.nonce,
                offer.expiration,
                offer.useCallback
            )
        );
        return keccak256(abi.encodePacked(bytes2(0x1901), domain, order));
    }

    function _sign(address request, Offer memory offer, uint256 key) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(request, offer));
        return abi.encodePacked(r, s, v);
    }
}

/// @title ThreeFRequestModelsTest
/// @notice Verifies signed offers, authorization, atomic funding, expiry, replay, and principal-first payouts.
contract ThreeFRequestModelsTest is ThreeFModelTestBase {
    function testIndependentDigestAndPermissionlessEOAConsumption() public {
        Offer memory offer = _offer(_alice, 100e6, 10e6);
        assertEq(TestnetThreeFRequest(_request).offerDigest(offer), _digest(_request, offer));
        bytes memory signature = _sign(_request, offer, _aliceKey);
        IERC20(_asset).transfer(_request, offer.expectedReturn);
        vm.prank(_bob);
        TestnetThreeFRequest(_request).consume(offer, signature);
        assertEq(IERC20(_asset).balanceOf(_request), 110e6);
        assertEq(IERC20(_asset).balanceOf(_alice), 1_000_000e6 - 100e6);
        assertEq(TestnetThreeFRequest(_request).ptBalance(_alice), 100e6);
        assertEq(TestnetThreeFRequest(_request).ytBalance(_alice), 10e6);
        assertEq(TestnetThreeFRequest(_request).nonce(_alice), 1);
        assertEq(TestnetThreeFRequest(_request).nonce(_bob), 0);
        vm.expectRevert(TestnetThreeFRequest.InvalidOffer.selector);
        TestnetThreeFRequest(_request).consume(offer, signature);
        assertEq(IERC20(_asset).balanceOf(_request), 110e6);
    }

    function testEverySignedFieldAndDomainIsBound() public {
        Offer memory offer = _offer(_alice, 100e6, 10e6);
        bytes memory signature = _sign(_request, offer, _aliceKey);
        for (uint256 i; i < 6; ++i) {
            Offer memory changed = _offer(_alice, 100e6, 10e6);
            if (i == 0) changed.maker = _bob;
            else if (i == 1) changed.amount += 1;
            else if (i == 2) changed.expectedReturn += 1;
            else if (i == 3) changed.nonce += 1;
            else if (i == 4) changed.expiration += 1;
            else changed.useCallback = true;
            vm.expectRevert(TestnetThreeFRequest.InvalidOffer.selector);
            TestnetThreeFRequest(_request).fundAndConsume(changed, signature);
        }
        address other = address(new TestnetThreeFRequest(address(this), _asset, uint48(block.timestamp + 7 days), 2));
        IERC20(_asset).approve(other, offer.expectedReturn);
        vm.expectRevert(TestnetThreeFRequest.InvalidOffer.selector);
        TestnetThreeFRequest(other).fundAndConsume(offer, signature);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(TestnetThreeFRequest.InvalidOffer.selector);
        TestnetThreeFRequest(_request).fundAndConsume(offer, signature);
        assertEq(IERC20(_asset).balanceOf(_request), 0);
        assertEq(IERC20(_asset).balanceOf(other), 0);
        assertEq(IERC20(_asset).balanceOf(address(this)), 1_000_000e6);
        assertEq(TestnetThreeFRequest(_request).nonce(_alice), 0);
    }

    function testWrongSignatureAndMissingPrincipalRollbackFixtureYield() public {
        Offer memory offer = _offer(_alice, 100e6, 10e6);
        bytes memory wrong = _sign(_request, offer, _bobKey);
        IERC20(_asset).approve(_request, offer.expectedReturn);
        vm.expectRevert(TestnetThreeFRequest.InvalidOffer.selector);
        TestnetThreeFRequest(_request).fundAndConsume(offer, wrong);
        assertEq(IERC20(_asset).allowance(address(this), _request), offer.expectedReturn);
        bytes memory signature = _sign(_request, offer, _aliceKey);
        vm.prank(_alice);
        IERC20(_asset).approve(_request, 0);
        vm.expectRevert();
        TestnetThreeFRequest(_request).fundAndConsume(offer, signature);
        assertEq(IERC20(_asset).balanceOf(_request), 0);
        assertEq(IERC20(_asset).balanceOf(address(this)), 1_000_000e6);
        assertEq(IERC20(_asset).allowance(address(this), _request), offer.expectedReturn);
        assertEq(TestnetThreeFRequest(_request).nonce(_alice), 0);
        assertEq(TestnetThreeFRequest(_request).ptSupply(), 0);
        assertEq(TestnetThreeFRequest(_request).ytSupply(), 0);
    }

    function testExpiryAllowsExactSecondAndRejectsFollowingSecond() public {
        Offer memory offer = _offer(_alice, 100e6, 10e6);
        bytes memory signature = _sign(_request, offer, _aliceKey);
        vm.warp(offer.expiration);
        TestnetThreeFRequest(_request).fundAndConsume(offer, signature);
        offer = _offer(_bob, 100e6, 10e6);
        signature = _sign(_request, offer, _bobKey);
        vm.warp(offer.expiration + 1);
        vm.expectRevert(TestnetThreeFRequest.InvalidOffer.selector);
        TestnetThreeFRequest(_request).fundAndConsume(offer, signature);
        assertEq(TestnetThreeFRequest(_request).nonce(_bob), 0);
        assertEq(IERC20(_asset).balanceOf(_request), 110e6);
    }

    function testAdvancingMakerNonceInvalidatesPriorAuthorization() public {
        Offer memory oldOffer = _offer(_alice, 100e6, 10e6);
        bytes memory oldSignature = _sign(_request, oldOffer, _aliceKey);
        vm.prank(_alice);
        TestnetThreeFRequest(_request).setNonce(3);
        vm.expectRevert(TestnetThreeFRequest.InvalidOffer.selector);
        TestnetThreeFRequest(_request).fundAndConsume(oldOffer, oldSignature);
        for (uint256 i; i < 4; ++i) {
            vm.expectRevert(TestnetThreeFRequest.InvalidOffer.selector);
            vm.prank(_alice);
            TestnetThreeFRequest(_request).setNonce(i);
        }
        Offer memory newOffer = _offer(_alice, 100e6, 10e6);
        TestnetThreeFRequest(_request).fundAndConsume(newOffer, _sign(_request, newOffer, _aliceKey));
        assertEq(TestnetThreeFRequest(_request).nonce(_alice), 4);
        assertEq(TestnetThreeFRequest(_request).nonce(_bob), 0);
    }

    function testOwnerFundingAndMintAuthorizationRoles() public {
        Offer memory offer = _offer(_alice, 100e6, 10e6);
        bytes memory signature = _sign(_request, offer, _aliceKey);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _bob));
        vm.prank(_bob);
        TestnetThreeFRequest(_request).fundAndConsume(offer, signature);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _bob));
        vm.prank(_bob);
        TestnetThreeFRequest(_request).authorizeMinting(_bob, 100e6, 10e6);
        assertEq(IERC20(_asset).balanceOf(_request), 0);
    }

    function testAuthorizedMintBoundsCustodyAndOneUse() public {
        TestnetThreeFRequest(_request).authorizeMinting(_alice, 100e6, 10e6);
        IERC20(_asset).transfer(_request, 10e6);
        vm.expectRevert(TestnetThreeFRequest.InvalidOffer.selector);
        vm.prank(_alice);
        TestnetThreeFRequest(_request).mint(99e6, 10e6);
        vm.expectRevert(TestnetThreeFRequest.InvalidOffer.selector);
        vm.prank(_alice);
        TestnetThreeFRequest(_request).mint(100e6, 10e6 + 1);
        vm.prank(_alice);
        IERC20(_asset).approve(_request, 0);
        vm.expectRevert();
        vm.prank(_alice);
        TestnetThreeFRequest(_request).mint(100e6, 10e6);
        (uint128 principal, uint128 yieldAssets) = TestnetThreeFRequest(_request).mintAuthorization(_alice);
        assertEq(principal, 100e6);
        assertEq(yieldAssets, 10e6);
        vm.prank(_alice);
        IERC20(_asset).approve(_request, 100e6);
        vm.prank(_alice);
        TestnetThreeFRequest(_request).mint(100e6, 10e6);
        (principal, yieldAssets) = TestnetThreeFRequest(_request).mintAuthorization(_alice);
        assertEq(principal, 0);
        assertEq(yieldAssets, 0);
        vm.prank(_alice);
        TestnetThreeFRequest(_request).mint(100e6, 10e6);
        assertEq(TestnetThreeFRequest(_request).ptSupply(), 100e6);
        assertEq(TestnetThreeFRequest(_request).ytSupply(), 10e6);
        assertEq(IERC20(_asset).balanceOf(_request), 110e6);
    }

    function testMaturityRejectsNewFundingAndRequiresPositionOwnerForBurn() public {
        Offer memory offer = _offer(_alice, 100e6, 10e6);
        TestnetThreeFRequest(_request).fundAndConsume(offer, _sign(_request, offer, _aliceKey));
        vm.expectRevert(TestnetThreeFRequest.NotReady.selector);
        vm.prank(_alice);
        TestnetThreeFRequest(_request).burnAll(_alice, _alice);
        TestnetThreeFRequest(_request).authorizeMinting(_bob, 100e6, 10e6);
        offer = _offer(_bob, 100e6, 10e6);
        offer.expiration = TestnetThreeFRequest(_request).maturity() + 1 days;
        bytes memory signature = _sign(_request, offer, _bobKey);
        vm.warp(TestnetThreeFRequest(_request).maturity());
        assertTrue(TestnetThreeFRequest(_request).canWithdraw());
        vm.expectRevert(TestnetThreeFRequest.InvalidOffer.selector);
        TestnetThreeFRequest(_request).fundAndConsume(offer, signature);
        vm.expectRevert(TestnetThreeFRequest.InvalidOffer.selector);
        vm.prank(_bob);
        TestnetThreeFRequest(_request).mint(100e6, 10e6);
        vm.expectRevert(TestnetThreeFRequest.InvalidOffer.selector);
        TestnetThreeFRequest(_request).authorizeMinting(_bob, 1, 1);
        vm.expectRevert(TestnetThreeFRequest.NotReady.selector);
        vm.prank(_bob);
        TestnetThreeFRequest(_request).burnAll(_alice, _bob);
        address recipient = makeAddr("ThreeF payout receiver");
        vm.prank(_alice);
        (uint256 pt, uint256 yt, uint256 principal, uint256 yieldAssets) =
            TestnetThreeFRequest(_request).burnAll(_alice, recipient);
        assertEq(pt, 100e6);
        assertEq(yt, 10e6);
        assertEq(principal, 100e6);
        assertEq(yieldAssets, 10e6);
        assertEq(IERC20(_asset).balanceOf(recipient), 110e6);
        assertEq(TestnetThreeFRequest(_request).ptSupply(), 0);
        assertEq(TestnetThreeFRequest(_request).ytSupply(), 0);
        vm.prank(_alice);
        (pt, yt, principal, yieldAssets) = TestnetThreeFRequest(_request).burnAll(_alice, recipient);
        assertEq(pt + yt + principal + yieldAssets, 0);
        assertEq(IERC20(_asset).balanceOf(recipient), 110e6);
    }

    function testPrincipalIsSeniorAndYieldReceivesOnlyRemainingCash() public {
        for (uint256 i; i < 3; ++i) {
            address request =
                address(new TestnetThreeFRequest(address(this), _asset, uint48(block.timestamp + 7 days), i + 2));
            TestnetThreeFRequest(request).authorizeMinting(_alice, 100e6, 10e6);
            TestnetThreeFRequest(request).authorizeMinting(_bob, 200e6, 40e6);
            vm.prank(_alice);
            IERC20(_asset).approve(request, 100e6);
            vm.prank(_alice);
            TestnetThreeFRequest(request).mint(100e6, 10e6);
            vm.prank(_bob);
            IERC20(_asset).approve(request, 200e6);
            vm.prank(_bob);
            TestnetThreeFRequest(request).mint(200e6, 40e6);
            if (i == 0) {
                IERC20(_asset).transfer(request, 100e6);
            } else if (i == 1) {
                IERC20(_asset).transfer(request, 20e6);
            } else {
                vm.prank(request);
                TestnetToken(_asset).burn(60e6);
            }
            (uint256 principal, uint256 yieldAssets) = TestnetThreeFRequest(request).convertToAssets(100e6, 10e6);
            assertEq(principal, i == 2 ? 80e6 : 100e6);
            assertEq(yieldAssets, i == 0 ? 20e6 : i == 1 ? 4e6 : 0);
            (principal, yieldAssets) = TestnetThreeFRequest(request).convertToAssets(200e6, 40e6);
            assertEq(principal, i == 2 ? 160e6 : 200e6);
            assertEq(yieldAssets, i == 0 ? 80e6 : i == 1 ? 16e6 : 0);
        }
    }

    function testFuzzMaturityPayoutsConserveCashWithRounding(uint96 rawPrincipal, uint96 rawYield, uint96 rawCash)
        public
    {
        uint256 principal = bound(uint256(rawPrincipal), 10, 100_000e6);
        uint256 yieldAssets = bound(uint256(rawYield), 1, 10_000e6);
        Offer memory aliceOffer = _offer(_alice, principal, yieldAssets);
        TestnetThreeFRequest(_request).fundAndConsume(aliceOffer, _sign(_request, aliceOffer, _aliceKey));
        Offer memory bobOffer = _offer(_bob, principal * 2, yieldAssets * 3);
        TestnetThreeFRequest(_request).fundAndConsume(bobOffer, _sign(_request, bobOffer, _bobKey));
        uint256 cash = bound(uint256(rawCash), 0, 2 * (3 * principal + 4 * yieldAssets));
        uint256 backing = IERC20(_asset).balanceOf(_request);
        if (cash > backing) {
            IERC20(_asset).transfer(_request, cash - backing);
        } else {
            vm.prank(_request);
            TestnetToken(_asset).burn(backing - cash);
        }
        uint256 senior = cash < 3 * principal ? cash : 3 * principal;
        uint256 expectedPrincipal = senior * principal / (3 * principal);
        uint256 expectedYield = (cash - senior) * yieldAssets / (4 * yieldAssets);
        vm.warp(TestnetThreeFRequest(_request).maturity());
        address recipient = makeAddr("ThreeF proportional claims");
        vm.prank(_alice);
        (,, uint256 paidPrincipal, uint256 paidYield) = TestnetThreeFRequest(_request).burnAll(_alice, recipient);
        assertEq(paidPrincipal, expectedPrincipal);
        assertEq(paidYield, expectedYield);
        vm.prank(_bob);
        TestnetThreeFRequest(_request).burnAll(_bob, recipient);
        assertEq(IERC20(_asset).balanceOf(recipient), cash);
        assertEq(IERC20(_asset).balanceOf(_request), 0);
        assertEq(TestnetThreeFRequest(_request).ptSupply(), 0);
        assertEq(TestnetThreeFRequest(_request).ytSupply(), 0);
    }
}

/// @title ThreeFAdapterModelsTest
/// @notice Exercises native signed callbacks and atomic rollback using the production ThreeF adapter.
contract ThreeFAdapterModelsTest is ThreeFModelTestBase {
    struct Fixture {
        address request;
        address adapter;
        address vault;
        address delegator;
    }

    function testSignedProductionCallbackAllocatesRealCashAndFinalizesAtMaturity() public {
        Fixture memory f = _callbackFixture();
        Offer memory offer = _callbackOffer(f);
        bytes memory signature = _sign(f.request, offer, _aliceKey);
        assertEq(
            IThreeFAdapter(f.adapter).isValidSignature(_digest(f.request, offer), signature),
            IERC1271.isValidSignature.selector
        );
        assertEq(ThreeFModelDelegator(f.delegator).allocateExact(f.adapter, 100e6), 0);
        assertEq(IERC20(_asset).balanceOf(f.vault), 1000e6);
        TestnetThreeFRequest(f.request).fundAndConsume(offer, signature);
        assertEq(IERC20(_asset).balanceOf(f.request), 110e6);
        assertEq(IERC20(_asset).balanceOf(f.vault), 900e6);
        assertEq(IERC20(_asset).balanceOf(f.adapter), 0);
        assertEq(IERC20(_asset).allowance(f.adapter, f.request), 0);
        assertEq(IThreeFAdapter(f.adapter).requestsLength(), 1);
        assertEq(IThreeFAdapter(f.adapter).requestIndex(f.request), 1);
        assertEq(IThreeFAdapter(f.adapter).pendingAssets(f.request), 100e6);
        assertEq(IThreeFAdapter(f.adapter).totalAssets(), 100e6);
        vm.expectRevert(TestnetThreeFRequest.NotReady.selector);
        IThreeFAdapter(f.adapter).finalizeRequest(f.request);
        vm.warp(TestnetThreeFRequest(f.request).maturity());
        assertEq(IThreeFAdapter(f.adapter).totalAssets(), 110e6);
        IThreeFAdapter(f.adapter).finalizeRequest(f.request);
        assertEq(IERC20(_asset).balanceOf(f.adapter), 110e6);
        assertEq(IThreeFAdapter(f.adapter).requestIndex(f.request), 0);
        assertEq(IThreeFAdapter(f.adapter).pendingAssets(f.request), 0);
        assertEq(IThreeFAdapter(f.adapter).requestsLength(), 0);
        assertEq(TestnetThreeFRequest(f.request).ptSupply(), 0);
        assertEq(TestnetThreeFRequest(f.request).ytSupply(), 0);
    }

    function testProductionCallbackWrongSignerAndPartialAllocationRollbackAllCash() public {
        Fixture memory f = _callbackFixture();
        Offer memory offer = _callbackOffer(f);
        bytes memory signature = _sign(f.request, offer, _bobKey);
        vm.expectRevert(TestnetThreeFRequest.InvalidOffer.selector);
        TestnetThreeFRequest(f.request).fundAndConsume(offer, signature);
        _assertUnchanged(f);
        signature = _sign(f.request, offer, _aliceKey);
        ThreeFModelDelegator(f.delegator).setLimit(25e6);
        vm.expectRevert(IThreeFAdapter.InsufficientAllocate.selector);
        TestnetThreeFRequest(f.request).fundAndConsume(offer, signature);
        _assertUnchanged(f);
        ThreeFModelDelegator(f.delegator).setLimit(1000e6);
        TestnetThreeFRequest(f.request).fundAndConsume(offer, signature);
        assertEq(TestnetThreeFRequest(f.request).nonce(f.adapter), 1);
        assertEq(IERC20(_asset).balanceOf(address(this)), 1_000_000e6 - 10e6);
    }

    function testProductionCallbackYieldFailureAndReplayRollbackFixtureFunding() public {
        Fixture memory f = _callbackFixture();
        Offer memory offer = _callbackOffer(f);
        bytes memory signature = _sign(f.request, offer, _aliceKey);
        IThreeFAdapter(f.adapter).setLimitsPerRequest(100_001, 1, 1000e6);
        vm.expectRevert(IThreeFAdapter.TooLowYield.selector);
        TestnetThreeFRequest(f.request).fundAndConsume(offer, signature);
        _assertUnchanged(f);
        IThreeFAdapter(f.adapter).setLimitsPerRequest(100_000, 1, 1000e6);
        TestnetThreeFRequest(f.request).fundAndConsume(offer, signature);
        IERC20(_asset).approve(f.request, 10e6);
        vm.expectRevert(TestnetThreeFRequest.InvalidOffer.selector);
        TestnetThreeFRequest(f.request).fundAndConsume(offer, signature);
        offer.nonce = 1;
        signature = _sign(f.request, offer, _aliceKey);
        vm.expectRevert(IThreeFAdapter.AlreadyRequest.selector);
        TestnetThreeFRequest(f.request).fundAndConsume(offer, signature);
        assertEq(IERC20(_asset).balanceOf(address(this)), 1_000_000e6 - 10e6);
        assertEq(IERC20(_asset).balanceOf(f.request), 110e6);
        assertEq(IERC20(_asset).balanceOf(f.vault), 900e6);
        assertEq(IERC20(_asset).allowance(address(this), f.request), 10e6);
        assertEq(TestnetThreeFRequest(f.request).nonce(f.adapter), 1);
        assertEq(IThreeFAdapter(f.adapter).requestsLength(), 1);
    }

    function _callbackFixture() internal returns (Fixture memory f) {
        address facility = address(new TestnetThreeFFacility(address(this), _asset, _asset));
        f.request = TestnetThreeFFacility(facility).createRequest(uint48(block.timestamp + 7 days));
        f.vault = address(new ThreeFModelVault(_asset));
        f.delegator = address(new ThreeFModelDelegator(f.vault, 1000e6));
        ThreeFModelVault(f.vault).setDelegator(f.delegator);
        address vaultFactory = address(new ThreeFModelVaultFactory(f.vault));
        address adapterFactory = address(new AdapterFactory(address(this)));
        AdapterFactory(adapterFactory).whitelist(address(new ThreeFAdapter(vaultFactory, adapterFactory, facility)));
        f.adapter = AdapterFactory(adapterFactory).create(1, address(this), abi.encode(f.vault, bytes("")));
        IThreeFAdapter(f.adapter).setOfferSigner(_alice);
        IThreeFAdapter(f.adapter).setLimitsPerRequest(100_000, 1, 1000e6);
        TestnetToken(_asset).mint(f.vault, 1000e6);
        IERC20(_asset).approve(f.request, 10e6);
    }

    function _callbackOffer(Fixture memory f) internal view returns (Offer memory) {
        return Offer({
            maker: f.adapter,
            amount: 100e6,
            expectedReturn: 10e6,
            nonce: 0,
            expiration: TestnetThreeFRequest(f.request).maturity(),
            useCallback: true
        });
    }

    function _assertUnchanged(Fixture memory f) internal view {
        assertEq(IERC20(_asset).balanceOf(address(this)), 1_000_000e6);
        assertEq(IERC20(_asset).balanceOf(f.request), 0);
        assertEq(IERC20(_asset).balanceOf(f.vault), 1000e6);
        assertEq(IERC20(_asset).balanceOf(f.adapter), 0);
        assertEq(IERC20(_asset).allowance(address(this), f.request), 10e6);
        assertEq(IERC20(_asset).allowance(f.adapter, f.request), 0);
        assertEq(TestnetThreeFRequest(f.request).nonce(f.adapter), 0);
        assertEq(TestnetThreeFRequest(f.request).ptSupply(), 0);
        assertEq(TestnetThreeFRequest(f.request).ytSupply(), 0);
        assertEq(IThreeFAdapter(f.adapter).requestsLength(), 0);
        assertEq(IThreeFAdapter(f.adapter).pendingAssets(f.request), 0);
    }
}
