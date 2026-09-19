// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {Test} from "forge-std/Test.sol";

import {AdapterFactory} from "../../../src/contracts/AdapterFactory.sol";
import {LiquidLaneAdapter} from "../../../src/contracts/LiquidLaneAdapter.sol";
import {MerkleAdapter} from "../../../src/contracts/MerkleAdapter.sol";
import {AccountRegistry} from "../../../src/contracts/ll-adapter/AccountRegistry.sol";
import {
    LiquidLaneSignatureValidator
} from "../../../src/contracts/merkle-adapter/signature-validators/LiquidLaneSignatureValidator.sol";
import {RootRegistry} from "../../../src/contracts/merkle-adapter/RootRegistry.sol";

import {MerkleAdapterVerifier} from "../../../src/contracts/merkle-adapter/libraries/MerkleAdapterVerifier.sol";

import {ILiquidLaneAdapter} from "../../../src/interfaces/ILiquidLaneAdapter.sol";
import {IMerkleAdapter} from "../../../src/interfaces/IMerkleAdapter.sol";
import {ILiquidLaneReactor} from "../../../src/interfaces/merkle-adapter/capabilities/ILiquidLaneReactor.sol";

import {
    MockERC20,
    MockLiquidLaneAccount,
    MockLiquidLaneOracle,
    MockLiquidLaneVault,
    MockVaultRegistry
} from "../LiquidLaneAdapter.t.sol";
import {MerkleAdapterOracleMock} from "../MerkleAdapter.t.sol";
import {
    LiquidLaneReactorReference,
    LiquidLaneRedeemFiller,
    LiquidLaneRedeemTokenMock
} from "../../mocks/liquid-lane-redeem/LiquidLaneRedeemMocks.sol";
import {IReactor} from "../../mocks/liquid-lane-redeem/IReactor.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

contract LiquidLaneSignatureValidatorTest is Test {
    /// @dev Deterministic test-only protocol signing key; never used outside this fixture.
    uint256 internal constant PROTOCOL_KEY = 0xA11CE;

    MockERC20 internal asset;
    LiquidLaneRedeemTokenMock internal rwa;
    MerkleAdapter internal adapter;
    RootRegistry internal rootRegistry;
    LiquidLaneAdapter internal liquidLane;
    AdapterFactory internal liquidLaneFactory;
    LiquidLaneReactorReference internal reactor;
    LiquidLaneRedeemFiller internal filler;
    LiquidLaneSignatureValidator internal validator;

    address internal keeper = makeAddr("keeper");
    address internal protocol;
    address internal supplierReceiver = makeAddr("supplierReceiver");

    function setUp() public {
        vm.warp(1_000_000);
        protocol = vm.addr(PROTOCOL_KEY);
        asset = new MockERC20("USD", "USD");
        rwa = new LiquidLaneRedeemTokenMock();
        MockVaultRegistry vaultFactory = new MockVaultRegistry();
        MockLiquidLaneVault consumerVault = new MockLiquidLaneVault(address(asset));
        MockLiquidLaneVault supplierVault = new MockLiquidLaneVault(address(asset));
        vaultFactory.add(address(consumerVault));
        vaultFactory.add(address(supplierVault));

        AdapterFactory merkleFactory = new AdapterFactory(address(this));
        MigratablesFactory oracleFactory = new MigratablesFactory(address(this));
        oracleFactory.whitelist(address(new MerkleAdapterOracleMock(address(oracleFactory))));
        rootRegistry = new RootRegistry(address(this));
        merkleFactory.whitelist(
            address(
                new MerkleAdapter(
                    address(vaultFactory),
                    address(merkleFactory),
                    address(oracleFactory),
                    address(rootRegistry),
                    address(new CapabilitiesRegistry(address(this)))
                )
            )
        );
        adapter = MerkleAdapter(
            payable(merkleFactory.create(
                    1,
                    address(this),
                    abi.encode(
                        address(consumerVault),
                        abi.encode(IMerkleAdapter.InitParams({defaultAdminRoleHolder: address(this)}))
                    )
                ))
        );

        liquidLaneFactory = new AdapterFactory(address(this));
        AccountRegistry accountRegistry = new AccountRegistry(address(this));
        MigratablesFactory accountFactory = new MigratablesFactory(address(this));
        accountFactory.whitelist(
            address(
                new MockLiquidLaneAccount(
                    address(accountFactory), address(asset), address(new MockLiquidLaneOracle(1e18)), address(rwa)
                )
            )
        );
        accountRegistry.setAccountFactory(address(asset), address(rwa), address(accountFactory));
        liquidLaneFactory.whitelist(
            address(new LiquidLaneAdapter(address(vaultFactory), address(liquidLaneFactory), address(accountRegistry)))
        );
        liquidLane = LiquidLaneAdapter(
            liquidLaneFactory.create(
                1,
                address(this),
                abi.encode(
                    address(supplierVault),
                    abi.encode(ILiquidLaneAdapter.InitParams({pauser: address(this), unpauser: address(this)}))
                )
            )
        );
        liquidLane.addTokenToRedeem(address(rwa));
        liquidLane.setReceiver(supplierReceiver);
        asset.mint(address(this), 1000e18);
        asset.approve(address(liquidLane), 1000e18);
        liquidLane.depositToAcquire(address(rwa), 1000e18);

        reactor = new LiquidLaneReactorReference(address(liquidLaneFactory));
        filler = new LiquidLaneRedeemFiller(address(reactor));
        liquidLane.setFiller(address(filler), true);
        validator = new LiquidLaneSignatureValidator(address(reactor), protocol);
        rwa.mint(address(adapter), 1000e18);
    }

    function test_SignAndFillThroughReactorWithoutInstallingCapability() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        bytes memory signature = _envelope(request);
        assertEq(digest, _requestDigest(request));
        assertEq(adapter.getCapabilities().length, 0);
        assertEq(adapter.signatures(digest), signature);
        assertEq(adapter.isValidSignature(digest, signature), IERC1271.isValidSignature.selector);

        _fill(request, signature, 90e18);

        assertEq(asset.balanceOf(address(adapter)), 90e18);
        assertEq(rwa.balanceOf(supplierReceiver), 100e18);
        assertEq(rwa.balanceOf(address(adapter)), 900e18);
        assertEq(rwa.balanceOf(address(validator)), 0);
        assertEq(rwa.allowance(address(adapter), address(reactor)), 0);
        assertTrue(reactor.isUsedNonce(address(adapter), request.nonce));
        assertEq(adapter.isValidSignature(digest, signature), bytes4(0xffffffff));
        assertEq(adapter.signatures(digest), signature);
        _fill(request, signature, 90e18, abi.encodePacked(IReactor.NonceUsed.selector));
    }

    function test_ValidationRequiresSavedExactEnvelope() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = validator.hashRequest(request);
        bytes memory signature = _envelope(request);
        assertEq(adapter.isValidSignature(digest, signature), bytes4(0xffffffff));
        _sign(request);
        assertEq(adapter.isValidSignature(digest, signature), IERC1271.isValidSignature.selector);
        assertEq(adapter.isValidSignature(digest, bytes.concat(signature, hex"00")), bytes4(0xffffffff));
        assertEq(adapter.isValidSignature(digest, bytes("")), bytes4(0xffffffff));
        assertEq(adapter.isValidSignature(keccak256("unknown"), signature), bytes4(0xffffffff));
    }

    function testFuzz_SavedEnvelopeCannotAuthorizeMismatchedRequestHash(uint8 field, uint128 difference) public {
        field = uint8(bound(field, 0, 7));
        uint256 delta = bound(difference, 1, type(uint128).max);
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);

        if (field == 0) request.tokenIn = address(uint160(uint256(uint160(request.tokenIn)) ^ delta));
        else if (field == 1) request.amountIn += delta;
        else if (field == 2) request.outputs[0].amount += delta;
        else if (field == 3) request.outputs[0].recipient = address(uint160(uint256(uint160(address(adapter))) ^ delta));
        else if (field == 4) request.outputs[0].token = address(uint160(uint256(uint160(address(asset))) ^ delta));
        else if (field == 5) request.deadline += delta;
        else if (field == 6) request.nonce += delta;
        else request.protocol = address(uint160(uint256(uint160(protocol)) ^ delta));

        assertNotEq(digest, _requestDigest(request));
        bytes memory changed = _envelope(request);
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (digest, changed)));
        assertEq(adapter.isValidSignature(digest, changed), bytes4(0xffffffff));
    }

    function test_MerkleMaskAllowsAmountsButPinsValidatorAndRequestPolicy() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes memory data =
            abi.encodeCall(IMerkleAdapter.setSignature, (validator.hashRequest(request), _envelope(request)));
        bytes memory mask = new bytes(data.length);
        // setSignature(bytes32,bytes) wraps (validator, abi.encode(Request)): vary only digest, input amount, deadline and nonce.
        for (uint256 i; i < 32; ++i) {
            mask[4 + i] = 0xff;
            mask[260 + i] = 0xff;
            mask[324 + i] = 0xff;
            mask[356 + i] = 0xff;
        }
        bytes32 leaf = MerkleAdapterVerifier.leaf(address(adapter), 0, data, mask);
        rootRegistry.setRoot(address(adapter), leaf);
        adapter.acceptRoot(leaf);
        adapter.grantRole(leaf, keeper);
        IMerkleAdapter.Action[] memory actions = new IMerkleAdapter.Action[](1);
        request.amountIn = 120e18;
        request.deadline++;
        request.nonce++;
        bytes32 digest = validator.hashRequest(request);
        actions[0] = IMerkleAdapter.Action(
            address(adapter),
            0,
            abi.encodeCall(IMerkleAdapter.setSignature, (digest, _envelope(request))),
            mask,
            new bytes32[](0)
        );
        vm.prank(keeper);
        adapter.manage(actions);
        assertEq(adapter.isValidSignature(digest, _envelope(request)), IERC1271.isValidSignature.selector);

        request.tokenIn = address(asset);
        actions[0].data =
            abi.encodeCall(IMerkleAdapter.setSignature, (validator.hashRequest(request), _envelope(request)));
        vm.prank(keeper);
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        adapter.manage(actions);

        request.tokenIn = address(rwa);
        request.outputs[0].recipient = keeper;
        actions[0].data =
            abi.encodeCall(IMerkleAdapter.setSignature, (validator.hashRequest(request), _envelope(request)));
        vm.prank(keeper);
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        adapter.manage(actions);

        request.outputs[0].recipient = address(adapter);
        actions[0].data = abi.encodeCall(
            IMerkleAdapter.setSignature, (digest, abi.encode(makeAddr("unapproved validator"), abi.encode(request)))
        );
        vm.prank(keeper);
        vm.expectRevert(IMerkleAdapter.InvalidMerkleProof.selector);
        adapter.manage(actions);
    }

    function testFuzz_HashMatchesReactorAcrossOutputs(uint128 amount, uint256 nonce, uint8 outputCount) public view {
        ILiquidLaneReactor.Request memory request = _request();
        request.amountIn = amount;
        request.nonce = nonce;
        request.outputs = new ILiquidLaneReactor.Output[](bound(outputCount, 0, 5));
        for (uint256 i; i < request.outputs.length; ++i) {
            request.outputs[i] = ILiquidLaneReactor.Output(address(uint160(i)), uint256(amount) + i, address(adapter));
        }
        assertEq(validator.hashRequest(request), _requestDigest(request));
    }

    function test_ChainChangeInvalidatesApprovedDigest() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        vm.chainId(block.chainid + 1);
        assertNotEq(validator.hashRequest(request), digest);
        assertEq(adapter.isValidSignature(digest, _envelope(request)), bytes4(0xffffffff));
    }

    function test_DifferentReactorCannotValidateSavedDigest() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        validator = new LiquidLaneSignatureValidator(
            address(new LiquidLaneReactorReference(address(liquidLaneFactory))), protocol
        );
        bytes memory signature = _envelope(request);
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (digest, signature)));
        assertNotEq(validator.hashRequest(request), digest);
        assertEq(adapter.isValidSignature(digest, signature), bytes4(0xffffffff));
    }

    function test_ProtocolMustMatchValidator() public {
        ILiquidLaneReactor.Request memory request = _request();
        request.protocol = makeAddr("other protocol");
        _assertInvalid(request);
    }

    function test_ZeroInputTokenIsInvalid() public {
        ILiquidLaneReactor.Request memory request = _request();
        request.tokenIn = address(0);
        _assertInvalid(request);
    }

    function test_ZeroInputAmountIsInvalid() public {
        ILiquidLaneReactor.Request memory request = _request();
        request.amountIn = 0;
        _assertInvalid(request);
    }

    function test_EmptyOutputsAreInvalid() public {
        ILiquidLaneReactor.Request memory request = _request();
        request.outputs = new ILiquidLaneReactor.Output[](0);
        _assertInvalid(request);
    }

    function test_ZeroOutputAmountIsInvalid() public {
        ILiquidLaneReactor.Request memory request = _request();
        request.outputs[0].amount = 0;
        _assertInvalid(request);
    }

    function test_EveryOutputMustBelongToCallingAdapter() public {
        ILiquidLaneReactor.Request memory request = _request();
        request.outputs = new ILiquidLaneReactor.Output[](2);
        request.outputs[0] = ILiquidLaneReactor.Output(address(asset), 90e18, address(adapter));
        request.outputs[1] = ILiquidLaneReactor.Output(address(asset), 1e18, makeAddr("other adapter"));
        _assertInvalid(request);
    }

    function test_OtherCallerCannotReuseAdapterRequest() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        vm.prank(address(adapter));
        assertEq(validator.isValidSignature(digest, abi.encode(request)), IERC1271.isValidSignature.selector);
        vm.prank(makeAddr("other adapter"));
        assertEq(validator.isValidSignature(digest, abi.encode(request)), bytes4(0xffffffff));
    }

    function test_ExactDeadlineValidThenExpires() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        vm.warp(request.deadline);
        assertEq(adapter.isValidSignature(digest, _envelope(request)), IERC1271.isValidSignature.selector);
        vm.warp(request.deadline + 1);
        assertEq(adapter.isValidSignature(digest, _envelope(request)), bytes4(0xffffffff));
    }

    function test_ClearingEnvelopeRevokesWithoutTouchingFundsOrNonce() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        rwa.setPaused(true);
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (digest, bytes(""))));
        assertEq(adapter.signatures(digest), bytes(""));
        assertEq(adapter.isValidSignature(digest, _envelope(request)), bytes4(0xffffffff));
        assertFalse(reactor.isUsedNonce(address(adapter), request.nonce));
        assertEq(rwa.balanceOf(address(adapter)), 1000e18);
        assertEq(rwa.allowance(address(adapter), address(reactor)), 100e18);
    }

    function test_DirectNonceLeafInvalidatesAllApprovedRequestsSharingNonce() public {
        ILiquidLaneReactor.Request memory first = _request();
        bytes32 firstDigest = _sign(first);
        bytes memory firstSignature = _envelope(first);
        ILiquidLaneReactor.Request memory second = _request();
        second.amountIn = 200e18;
        bytes32 secondDigest = _sign(second);
        bytes memory secondSignature = _envelope(second);
        assertEq(adapter.isValidSignature(firstDigest, firstSignature), IERC1271.isValidSignature.selector);
        assertEq(adapter.isValidSignature(secondDigest, secondSignature), IERC1271.isValidSignature.selector);
        rwa.setPaused(true);
        _manage(address(reactor), abi.encodeCall(ILiquidLaneReactor.invalidateNonce, (first.nonce)));
        assertEq(adapter.isValidSignature(firstDigest, firstSignature), bytes4(0xffffffff));
        assertEq(adapter.isValidSignature(secondDigest, secondSignature), bytes4(0xffffffff));
    }

    function test_MultipleRequestsForSameTokenAreIndependentlyValid() public {
        ILiquidLaneReactor.Request memory first = _request();
        bytes32 firstDigest = _sign(first);
        bytes memory firstSignature = _envelope(first);
        ILiquidLaneReactor.Request memory second = _request();
        second.nonce++;
        bytes32 secondDigest = _sign(second);
        assertEq(adapter.isValidSignature(firstDigest, firstSignature), IERC1271.isValidSignature.selector);
        assertEq(adapter.isValidSignature(secondDigest, _envelope(second)), IERC1271.isValidSignature.selector);
    }

    function test_SigningDoesNotRequireFundingOrAllowance() public {
        ILiquidLaneReactor.Request memory request = _request();
        request.amountIn = type(uint256).max;
        bytes32 digest = validator.hashRequest(request);
        bytes memory signature = _envelope(request);
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (digest, signature)));
        assertEq(adapter.isValidSignature(digest, signature), IERC1271.isValidSignature.selector);
        assertEq(rwa.allowance(address(adapter), address(reactor)), 0);
    }

    function test_MalformedOrEmptyValidatorDataIsInvalidThroughAdapter() public {
        bytes32 digest = keccak256("malformed");
        bytes memory signature = abi.encode(address(validator), hex"01");
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (digest, signature)));
        assertEq(adapter.isValidSignature(digest, signature), bytes4(0xffffffff));
        signature = abi.encode(address(validator), bytes(""));
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (digest, signature)));
        assertEq(adapter.isValidSignature(digest, signature), bytes4(0xffffffff));
    }

    function test_ConstructorOnlyPinsDependencies() public {
        assertEq(validator.REACTOR(), address(reactor));
        assertEq(validator.PROTOCOL(), protocol);
        LiquidLaneSignatureValidator empty = new LiquidLaneSignatureValidator(address(0), address(0));
        assertEq(empty.REACTOR(), address(0));
        assertEq(empty.PROTOCOL(), address(0));
    }

    /// forge-config: default.isolate = true
    function test_Gas_ValidSignature() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        assertEq(adapter.isValidSignature(digest, _envelope(request)), IERC1271.isValidSignature.selector);
        vm.snapshotGasLastCall("LiquidLaneSignatureValidator", "validSignature");
    }

    /// forge-config: default.isolate = true
    function test_Gas_InvalidSignature() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        vm.warp(request.deadline + 1);
        assertEq(adapter.isValidSignature(digest, _envelope(request)), bytes4(0xffffffff));
        vm.snapshotGasLastCall("LiquidLaneSignatureValidator", "invalidSignature");
    }

    /// forge-config: default.isolate = true
    function test_Gas_HashRequest() public {
        validator.hashRequest(_request());
        vm.snapshotGasLastCall("LiquidLaneSignatureValidator", "hashRequest");
    }

    function _assertInvalid(ILiquidLaneReactor.Request memory request) internal {
        bytes32 digest = validator.hashRequest(request);
        bytes memory signature = _envelope(request);
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (digest, signature)));
        assertEq(adapter.isValidSignature(digest, signature), bytes4(0xffffffff));
    }

    function _envelope(ILiquidLaneReactor.Request memory request) internal view returns (bytes memory) {
        return abi.encode(address(validator), abi.encode(request));
    }

    function _request() internal view returns (ILiquidLaneReactor.Request memory request) {
        request = ILiquidLaneReactor.Request({
            tokenIn: address(rwa),
            amountIn: 100e18,
            outputs: new ILiquidLaneReactor.Output[](1),
            deadline: block.timestamp + 1 hours,
            nonce: 7,
            protocol: protocol
        });
        request.outputs[0] = ILiquidLaneReactor.Output(address(asset), 90e18, address(adapter));
    }

    function _sign(ILiquidLaneReactor.Request memory request) internal returns (bytes32 digest) {
        _manage(request.tokenIn, abi.encodeCall(IERC20.approve, (address(reactor), request.amountIn)));
        digest = validator.hashRequest(request);
        _manage(address(adapter), abi.encodeCall(IMerkleAdapter.setSignature, (digest, _envelope(request))));
    }

    function _fill(ILiquidLaneReactor.Request memory request, bytes memory signature, uint256 swapOutput) internal {
        _fill(request, signature, swapOutput, bytes(""));
    }

    function _fill(
        ILiquidLaneReactor.Request memory request,
        bytes memory signature,
        uint256 swapOutput,
        bytes memory expectedError
    ) internal {
        IReactor.Order memory order = IReactor.Order({
            request: _asReferenceRequest(request),
            swapperSignature: signature,
            swapper: address(adapter),
            filler: address(filler),
            outputs: abi.decode(abi.encode(request.outputs), (IReactor.Output[]))
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PROTOCOL_KEY, reactor.orderDigest(order));
        IReactor.SwapInput memory swapInput = IReactor.SwapInput({
            adapter: address(liquidLane),
            swap: ILiquidLaneAdapter.Swap({
                recipient: address(filler), tokenIn: request.tokenIn, amountIn: request.amountIn, amountOut: swapOutput
            })
        });
        if (expectedError.length > 0) {
            vm.expectRevert(expectedError);
        }
        filler.fill(order, abi.encodePacked(r, s, v), swapInput);
    }

    function _requestDigest(ILiquidLaneReactor.Request memory request) internal view returns (bytes32) {
        return reactor.requestDigest(_asReferenceRequest(request));
    }

    function _asReferenceRequest(ILiquidLaneReactor.Request memory request)
        internal
        pure
        returns (IReactor.Request memory)
    {
        return abi.decode(abi.encode(request), (IReactor.Request));
    }

    function _manage(address target, bytes memory data) internal returns (bytes memory result) {
        IMerkleAdapter.Action[] memory actions = _authorize(target, data);
        vm.prank(keeper);
        bytes[] memory results = adapter.manage(actions);
        result = results[0];
    }

    function _authorize(address target, bytes memory data) internal returns (IMerkleAdapter.Action[] memory actions) {
        bytes memory mask = new bytes(data.length);
        bytes32 leaf =
            keccak256(bytes.concat(keccak256(abi.encode(target, bytes1(0), keccak256(mask), keccak256(data)))));
        rootRegistry.setRoot(address(adapter), leaf);
        adapter.acceptRoot(leaf);
        adapter.grantRole(leaf, keeper);
        actions = new IMerkleAdapter.Action[](1);
        actions[0] =
            IMerkleAdapter.Action({target: target, value: 0, data: data, dataMask: mask, proof: new bytes32[](0)});
    }
}
