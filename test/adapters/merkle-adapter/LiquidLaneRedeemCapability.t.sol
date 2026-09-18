// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CapabilitiesRegistry} from "src/contracts/merkle_adapter/CapabilitiesRegistry.sol";
import {CapabilitiesRegistryProposer} from "src/contracts/merkle_adapter/CapabilitiesRegistryProposer.sol";
import {ICapability} from "src/interfaces/merkle_adapter/ICapability.sol";
import {Test} from "forge-std/Test.sol";

import {AdapterFactory} from "../../../src/contracts/AdapterFactory.sol";
import {LiquidLaneAdapter} from "../../../src/contracts/LiquidLaneAdapter.sol";
import {MerkleAdapter} from "../../../src/contracts/MerkleAdapter.sol";
import {AccountRegistry} from "../../../src/contracts/ll-adapter/AccountRegistry.sol";
import {LiquidLaneRedeemCapability} from "../../../src/contracts/merkle_adapter/LiquidLaneRedeemCapability.sol";
import {RootRegistry} from "../../../src/contracts/merkle_adapter/RootRegistry.sol";

import {ILiquidLaneAdapter} from "../../../src/interfaces/ILiquidLaneAdapter.sol";
import {IMerkleAdapter} from "../../../src/interfaces/IMerkleAdapter.sol";
import {ILiquidLaneReactor} from "../../../src/interfaces/merkle_adapter/ILiquidLaneReactor.sol";
import {ILiquidLaneRedeemCapability} from "../../../src/interfaces/merkle_adapter/ILiquidLaneRedeemCapability.sol";

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
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

contract LiquidLaneRedeemCapabilityTest is Test {
    /// @dev Deterministic test-only protocol signing key; never used outside this fixture.
    uint256 internal constant PROTOCOL_KEY = 0xA11CE;
    bytes internal constant SIGNATURE = hex"112233445566778899";

    MockERC20 internal asset;
    LiquidLaneRedeemTokenMock internal rwa;
    MerkleAdapter internal adapter;
    RootRegistry internal rootRegistry;
    LiquidLaneAdapter internal liquidLane;
    AdapterFactory internal liquidLaneFactory;
    LiquidLaneReactorReference internal reactor;
    LiquidLaneRedeemFiller internal filler;
    LiquidLaneRedeemCapability internal implementation;
    LiquidLaneRedeemCapability internal capability;

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
                    address(
                        new CapabilitiesRegistry(
                            address(this), address(new CapabilitiesRegistryProposer(address(this)))
                        )
                    )
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
        implementation = new LiquidLaneRedeemCapability(address(reactor), protocol);
        _install(implementation);
        capability = LiquidLaneRedeemCapability(address(adapter));
        rwa.mint(address(adapter), 1000e18);
    }

    function test_SignAndFillRedeemsThroughReactorAndLiquidLaneToMerkleAdapter() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        assertEq(digest, _requestDigest(request));

        _fill(request, SIGNATURE, 90e18);

        assertEq(asset.balanceOf(address(adapter)), 90e18);
        assertEq(rwa.balanceOf(supplierReceiver), 100e18);
        assertEq(rwa.balanceOf(address(adapter)), 900e18);
        assertEq(rwa.balanceOf(address(implementation)), 0);
        assertEq(rwa.allowance(address(capability), address(reactor)), 0);
        assertTrue(reactor.isUsedNonce(address(capability), request.nonce));
        assertEq(capability.isValidSignature(digest, SIGNATURE), bytes4(0xffffffff));

        _manage(address(capability), abi.encodeCall(ILiquidLaneRedeemCapability.finalizeRequest, (digest)));
        assertEq(capability.activeRequest(address(rwa)), bytes32(0));
        assertEq(capability.signatures(digest), bytes(""));
    }

    function test_SignRequestPersistsOnlyExactSignature() public {
        bytes32 digest = _sign(_request());

        assertEq(capability.signatures(digest), SIGNATURE);
        assertEq(capability.activeRequest(address(rwa)), digest);
        assertEq(rwa.balanceOf(address(adapter)), 1000e18);
        assertEq(rwa.balanceOf(address(adapter)), 1000e18);
        assertEq(rwa.allowance(address(capability), address(reactor)), 100e18);
        assertEq(capability.isValidSignature(digest, SIGNATURE), IERC1271.isValidSignature.selector);
        assertEq(capability.isValidSignature(digest, hex"112233445566778800"), bytes4(0xffffffff));
        assertEq(capability.isValidSignature(digest, bytes("")), bytes4(0xffffffff));
        assertEq(capability.isValidSignature(keccak256("unknown"), SIGNATURE), bytes4(0xffffffff));
        assertEq(capability.isValidSignature(keccak256("unknown"), bytes("")), bytes4(0xffffffff));
    }

    function testFuzz_SignatureBindsEveryRequestField(uint8 field, uint128 difference) public {
        field = uint8(bound(field, 0, 7));
        uint256 delta = bound(difference, 1, type(uint128).max);
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 original = _sign(request);

        if (field == 0) request.tokenIn = address(uint160(uint256(uint160(request.tokenIn)) ^ delta));
        else if (field == 1) request.amountIn += delta;
        else if (field == 2) request.outputs[0].amount += delta;
        else if (field == 3) request.outputs[0].recipient = address(uint160(uint256(uint160(address(adapter))) ^ delta));
        else if (field == 4) request.outputs[0].token = address(uint160(uint256(uint160(address(asset))) ^ delta));
        else if (field == 5) request.deadline += delta;
        else if (field == 6) request.nonce += delta;
        else request.protocol = address(uint160(uint256(uint160(protocol)) ^ delta));

        bytes32 mutated = _requestDigest(request);
        assertNotEq(original, mutated);
        assertEq(capability.isValidSignature(original, SIGNATURE), IERC1271.isValidSignature.selector);
        assertEq(capability.isValidSignature(mutated, SIGNATURE), bytes4(0xffffffff));
    }

    function test_SignatureRejectsDifferentReactorChainAndCapability() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        LiquidLaneReactorReference otherReactor = new LiquidLaneReactorReference(address(liquidLaneFactory));
        bytes32 otherDomain = otherReactor.requestDigest(_asReferenceRequest(request));
        assertNotEq(digest, otherDomain);
        assertEq(capability.isValidSignature(otherDomain, SIGNATURE), bytes4(0xffffffff));

        LiquidLaneRedeemCapability otherCapability = new LiquidLaneRedeemCapability(address(reactor), protocol);
        assertEq(otherCapability.isValidSignature(digest, SIGNATURE), bytes4(0xffffffff));

        vm.chainId(block.chainid + 1);
        assertNotEq(capability.hashRequest(request), digest);
        assertEq(capability.isValidSignature(digest, SIGNATURE), bytes4(0xffffffff));
    }

    function test_RevokeAndFinalizeWorkWhenTokenOperationsArePaused() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        rwa.setPaused(true);
        _manage(address(adapter), abi.encodeCall(ILiquidLaneRedeemCapability.revokeRequest, (digest)));
        assertEq(capability.signatures(digest), bytes(""));
        assertEq(capability.isValidSignature(digest, SIGNATURE), bytes4(0xffffffff));
        assertTrue(reactor.isUsedNonce(address(adapter), request.nonce));
        _fill(request, SIGNATURE, 90e18, abi.encodePacked(IReactor.NonceUsed.selector));
        _manage(address(adapter), abi.encodeCall(ILiquidLaneRedeemCapability.finalizeRequest, (digest)));
        assertEq(rwa.balanceOf(address(adapter)), 1000e18);
        assertEq(rwa.allowance(address(adapter), address(reactor)), 100e18);
        assertEq(capability.activeRequest(address(rwa)), bytes32(0));
    }

    function test_ExpiredRequestFinalizationLeavesBalancesAndAllowanceUntouched() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        rwa.mint(address(adapter), 7e18);
        vm.warp(request.deadline + 1);
        assertEq(capability.isValidSignature(digest, SIGNATURE), bytes4(0xffffffff));
        _manage(address(adapter), abi.encodeCall(ILiquidLaneRedeemCapability.finalizeRequest, (digest)));
        assertEq(rwa.balanceOf(address(adapter)), 1007e18);
        assertEq(rwa.allowance(address(adapter), address(reactor)), 100e18);
        assertEq(capability.signatures(digest), bytes(""));
    }

    function test_ExactDeadlineRemainsValidAndCannotBeFinalized() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        vm.warp(request.deadline);

        assertEq(capability.isValidSignature(digest, SIGNATURE), IERC1271.isValidSignature.selector);
        _expectManageRevert(
            address(capability),
            abi.encodeCall(ILiquidLaneRedeemCapability.finalizeRequest, (digest)),
            ILiquidLaneRedeemCapability.RequestNotFinished.selector
        );
        _fill(request, SIGNATURE, 90e18);
        assertEq(asset.balanceOf(address(adapter)), 90e18);
    }

    function test_OnlyAdapterCanSignRevokeAndFinalize() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);

        vm.expectRevert(ICapability.InvalidCaller.selector);
        capability.signRequest(request, SIGNATURE);
        vm.expectRevert(ICapability.InvalidCaller.selector);
        capability.revokeRequest(digest);
        vm.expectRevert(ICapability.InvalidCaller.selector);
        capability.finalizeRequest(digest);
    }

    function test_RequestValidationRejectsInvalidAmountsTokenAndSignature() public {
        ILiquidLaneReactor.Request memory request = _request();
        request.amountIn = 0;
        _expectSignRevert(request, SIGNATURE, ILiquidLaneRedeemCapability.InvalidRequest.selector);
        request.amountIn = 100e18;
        request.tokenIn = address(0);
        _expectSignRevert(request, SIGNATURE, ILiquidLaneRedeemCapability.InvalidRequest.selector);
        request.tokenIn = address(rwa);
        request.deadline = block.timestamp - 1;
        _expectSignRevert(request, SIGNATURE, ILiquidLaneRedeemCapability.InvalidRequest.selector);
        request.deadline = block.timestamp;
        _expectSignRevert(request, bytes(""), ILiquidLaneRedeemCapability.InvalidSignature.selector);
    }

    function test_RequestValidationRejectsOtherProtocolAndOutputRecipients() public {
        ILiquidLaneReactor.Request memory request = _request();
        request.protocol = address(this);
        _expectSignRevert(request, SIGNATURE, ILiquidLaneRedeemCapability.InvalidProtocol.selector);
        request.protocol = protocol;
        request.outputs[0].recipient = address(implementation);
        _expectSignRevert(request, SIGNATURE, ILiquidLaneRedeemCapability.InvalidOutput.selector);
        request.outputs[0].recipient = address(adapter);
        request.outputs[0].amount = 0;
        _expectSignRevert(request, SIGNATURE, ILiquidLaneRedeemCapability.InvalidOutput.selector);
        request.outputs = new ILiquidLaneReactor.Output[](0);
        _expectSignRevert(request, SIGNATURE, ILiquidLaneRedeemCapability.InvalidOutput.selector);
    }

    function test_ActiveInputTokenMustBeFinalizedBeforeReuse() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        request.nonce += 1;
        _expectSignRevert(request, SIGNATURE, ILiquidLaneRedeemCapability.ActiveRequest.selector);

        _manage(address(capability), abi.encodeCall(ILiquidLaneRedeemCapability.revokeRequest, (digest)));
        _expectSignRevert(request, SIGNATURE, ILiquidLaneRedeemCapability.ActiveRequest.selector);
        _manage(address(capability), abi.encodeCall(ILiquidLaneRedeemCapability.finalizeRequest, (digest)));

        bytes32 nextDigest = _sign(request);
        assertNotEq(nextDigest, digest);
        assertEq(capability.isValidSignature(nextDigest, SIGNATURE), IERC1271.isValidSignature.selector);
        assertEq(capability.isValidSignature(digest, SIGNATURE), bytes4(0xffffffff));
    }

    function test_ConsumedNonceCannotBeSignedAgainAfterFinalization() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        _fill(request, SIGNATURE, 90e18);
        _manage(address(capability), abi.encodeCall(ILiquidLaneRedeemCapability.finalizeRequest, (digest)));

        _expectSignRevert(request, SIGNATURE, ILiquidLaneRedeemCapability.NonceUsed.selector);
        assertEq(rwa.balanceOf(address(adapter)), 900e18);
    }

    function test_SigningDoesNotRequireFundingOrApprovalAndCuratorApprovesSeparately() public {
        ILiquidLaneReactor.Request memory request = _request();
        vm.prank(address(adapter));
        rwa.transfer(address(this), 1000e18);
        _manage(address(adapter), abi.encodeCall(ILiquidLaneRedeemCapability.signRequest, (request, SIGNATURE)));
        assertEq(capability.isValidSignature(_requestDigest(request), SIGNATURE), IERC1271.isValidSignature.selector);
        assertEq(rwa.balanceOf(address(adapter)), 0);
        assertEq(rwa.allowance(address(adapter), address(reactor)), 0);
        rwa.mint(address(adapter), 100e18);
        _fill(
            request,
            SIGNATURE,
            90e18,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(reactor), 0, 100e18)
        );
        _manage(address(rwa), abi.encodeCall(IERC20.approve, (address(reactor), 100e18)));
        _fill(request, SIGNATURE, 90e18);
        assertEq(asset.balanceOf(address(adapter)), 90e18);
    }

    function test_FailedSettlementRollsBackConsumedNonceAndFunding() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);

        _fill(
            request,
            SIGNATURE,
            89e18,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(filler), 89e18, 90e18)
        );

        assertFalse(reactor.isUsedNonce(address(capability), request.nonce));
        assertEq(capability.isValidSignature(digest, SIGNATURE), IERC1271.isValidSignature.selector);
        assertEq(rwa.balanceOf(address(adapter)), 1000e18);
        assertEq(rwa.allowance(address(capability), address(reactor)), 100e18);
        assertEq(rwa.balanceOf(supplierReceiver), 0);
        assertEq(asset.balanceOf(address(adapter)), 0);
        _fill(request, SIGNATURE, 90e18);
        assertEq(asset.balanceOf(address(adapter)), 90e18);
    }

    function test_MultipleOutputsUseReactorArrayHashAndDeliverEveryOutput() public {
        ILiquidLaneReactor.Request memory request = _request();
        request.outputs = new ILiquidLaneReactor.Output[](2);
        request.outputs[0] = ILiquidLaneReactor.Output(address(asset), 60e18, address(adapter));
        request.outputs[1] = ILiquidLaneReactor.Output(address(asset), 30e18, address(adapter));
        bytes32 digest = _sign(request);
        assertEq(digest, _requestDigest(request));

        _fill(request, SIGNATURE, 90e18);
        assertEq(asset.balanceOf(address(adapter)), 90e18);
    }

    function test_DifferentInputTokensKeepFundingAndRevocationSeparate() public {
        ILiquidLaneReactor.Request memory first = _request();
        bytes32 firstDigest = _sign(first);
        LiquidLaneRedeemTokenMock secondToken = new LiquidLaneRedeemTokenMock();
        secondToken.mint(address(adapter), 100e18);
        ILiquidLaneReactor.Request memory second = _request();
        second.tokenIn = address(secondToken);
        second.nonce += 1;
        bytes32 secondDigest = _sign(second);

        _manage(address(capability), abi.encodeCall(ILiquidLaneRedeemCapability.revokeRequest, (firstDigest)));
        _manage(address(capability), abi.encodeCall(ILiquidLaneRedeemCapability.finalizeRequest, (firstDigest)));

        assertEq(capability.activeRequest(address(rwa)), bytes32(0));
        assertEq(capability.activeRequest(address(secondToken)), secondDigest);
        assertEq(capability.isValidSignature(secondDigest, SIGNATURE), IERC1271.isValidSignature.selector);
        assertEq(secondToken.balanceOf(address(capability)), 100e18);
        assertEq(secondToken.allowance(address(capability), address(reactor)), 100e18);
    }

    function test_DifferentInputTokensCannotShareAnActiveNonce() public {
        ILiquidLaneReactor.Request memory request = _request();
        _sign(request);
        LiquidLaneRedeemTokenMock secondToken = new LiquidLaneRedeemTokenMock();
        secondToken.mint(address(adapter), 100e18);
        request.tokenIn = address(secondToken);

        _expectSignRevert(request, SIGNATURE, ILiquidLaneRedeemCapability.ActiveRequest.selector);
        assertEq(secondToken.balanceOf(address(adapter)), 100e18);
        assertEq(secondToken.balanceOf(address(implementation)), 0);
    }

    function testFuzz_SignRevokeFinalizeNeverChangeFundsOrAllowances(uint96 amount) public {
        uint256 amountIn = bound(amount, 1, type(uint96).max);
        ILiquidLaneReactor.Request memory request = _request();
        request.amountIn = amountIn;
        bytes32 digest = _sign(request);
        assertEq(rwa.balanceOf(address(adapter)), 1000e18);
        assertEq(rwa.allowance(address(adapter), address(reactor)), amountIn);
        _manage(address(adapter), abi.encodeCall(ILiquidLaneRedeemCapability.revokeRequest, (digest)));
        _manage(address(adapter), abi.encodeCall(ILiquidLaneRedeemCapability.finalizeRequest, (digest)));
        assertEq(rwa.balanceOf(address(adapter)), 1000e18);
        assertEq(rwa.balanceOf(address(implementation)), 0);
        assertEq(rwa.allowance(address(adapter), address(reactor)), amountIn);
        _manage(address(rwa), abi.encodeCall(IERC20.approve, (address(reactor), 0)));
        assertEq(rwa.allowance(address(adapter), address(reactor)), 0);
    }

    function test_ConstructorStoresUncheckedDependencies() public {
        LiquidLaneRedeemCapability uncheckedCapability = new LiquidLaneRedeemCapability(address(0), address(0));
        assertEq(uncheckedCapability.REACTOR(), address(0));
        assertEq(uncheckedCapability.PROTOCOL(), address(0));
    }

    function test_ReplacementPreservesSignatureAndAdapterState() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        address originalOracle = adapter.oracle();
        adapter.removeCapability(address(implementation));
        implementation = new LiquidLaneRedeemCapability(address(reactor), protocol);
        _install(implementation);
        assertEq(adapter.oracle(), originalOracle);
        assertEq(adapter.owner(), address(this));
        assertEq(capability.PROTOCOL(), protocol);
        assertEq(capability.signatures(digest), SIGNATURE);
        assertEq(capability.isValidSignature(digest, SIGNATURE), IERC1271.isValidSignature.selector);
        _fill(request, SIGNATURE, 90e18);
        assertEq(asset.balanceOf(address(adapter)), 90e18);
    }

    function test_StorageUsesLiquidLaneNamespace() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        uint256 base = 0x4fe893ee3d5507262d3fa46ac0b3202265dbeb5f49c84de2df615d9340d0c600;
        assertEq(vm.load(address(adapter), keccak256(abi.encode(request.tokenIn, base))), digest);
        assertEq(
            vm.load(address(adapter), keccak256(abi.encode(digest, base + 1))),
            bytes32(SIGNATURE) | bytes32(uint256(SIGNATURE.length * 2))
        );
        uint256 authorization = uint256(keccak256(abi.encode(digest, base + 2)));
        assertEq(uint256(vm.load(address(adapter), bytes32(authorization))), uint160(request.tokenIn));
        assertEq(uint256(vm.load(address(adapter), bytes32(authorization + 1))), uint160(address(reactor)));
        assertEq(uint256(vm.load(address(adapter), bytes32(authorization + 2))), uint160(protocol));
        assertEq(uint256(vm.load(address(adapter), bytes32(authorization + 3))), block.chainid);
        assertEq(uint256(vm.load(address(adapter), bytes32(authorization + 4))), request.nonce);
        assertEq(uint256(vm.load(address(adapter), bytes32(authorization + 5))), request.deadline);
        assertEq(uint256(vm.load(address(adapter), keccak256(abi.encode(request.nonce, base + 3)))), 1);
    }

    function test_RemovalMayLeavePendingSignaturesAndApprovals() public {
        bytes32 digest = _sign(_request());
        adapter.removeCapability(address(implementation));
        vm.expectRevert(IMerkleAdapter.UnknownSelector.selector);
        capability.isValidSignature(digest, SIGNATURE);
        assertEq(rwa.balanceOf(address(adapter)), 1000e18);
        assertEq(rwa.allowance(address(adapter), address(reactor)), 100e18);
        adapter.addCapability(address(implementation));
        assertEq(capability.isValidSignature(digest, SIGNATURE), IERC1271.isValidSignature.selector);
    }

    function test_ReplacementWithDifferentReactorCannotValidateOldRequestAndCanRevokeIt() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        adapter.removeCapability(address(implementation));
        LiquidLaneReactorReference otherReactor = new LiquidLaneReactorReference(address(liquidLaneFactory));
        implementation = new LiquidLaneRedeemCapability(address(otherReactor), protocol);
        _install(implementation);
        assertEq(capability.isValidSignature(digest, SIGNATURE), bytes4(0xffffffff));
        _manage(address(adapter), abi.encodeCall(ILiquidLaneRedeemCapability.revokeRequest, (digest)));
        assertTrue(reactor.isUsedNonce(address(adapter), request.nonce));
        assertFalse(otherReactor.isUsedNonce(address(adapter), request.nonce));
        _manage(address(adapter), abi.encodeCall(ILiquidLaneRedeemCapability.finalizeRequest, (digest)));
        assertEq(capability.signatures(digest), bytes(""));
    }

    function test_UnknownRequestsCannotBeRevokedOrFinalized() public {
        bytes32 digest = keccak256("unknown");
        _expectManageRevert(
            address(capability),
            abi.encodeCall(ILiquidLaneRedeemCapability.revokeRequest, (digest)),
            ILiquidLaneRedeemCapability.UnknownRequest.selector
        );
        _expectManageRevert(
            address(capability),
            abi.encodeCall(ILiquidLaneRedeemCapability.finalizeRequest, (digest)),
            ILiquidLaneRedeemCapability.UnknownRequest.selector
        );
    }

    function _install(LiquidLaneRedeemCapability module) internal {
        CapabilitiesRegistry registry = CapabilitiesRegistry(adapter.CAPABILITIES_REGISTRY());
        CapabilitiesRegistryProposer proposer = CapabilitiesRegistryProposer(registry.PROPOSER());
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = ILiquidLaneRedeemCapability.REACTOR.selector;
        selectors[1] = ILiquidLaneRedeemCapability.PROTOCOL.selector;
        selectors[2] = ILiquidLaneRedeemCapability.activeRequest.selector;
        selectors[3] = ILiquidLaneRedeemCapability.signatures.selector;
        selectors[4] = ILiquidLaneRedeemCapability.hashRequest.selector;
        selectors[5] = ILiquidLaneRedeemCapability.signRequest.selector;
        selectors[6] = ILiquidLaneRedeemCapability.revokeRequest.selector;
        selectors[7] = ILiquidLaneRedeemCapability.finalizeRequest.selector;
        selectors[8] = IERC1271.isValidSignature.selector;
        proposer.initCapability(address(module), selectors);
        proposer.setProposedStatus(address(registry), address(adapter), address(module), true);
        registry.acceptCapability(address(adapter), address(module));
        adapter.addCapability(address(module));
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
        bytes memory result =
            _manage(address(capability), abi.encodeCall(ILiquidLaneRedeemCapability.signRequest, (request, SIGNATURE)));
        digest = abi.decode(result, (bytes32));
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
            swapper: address(capability),
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

    function _expectSignRevert(ILiquidLaneReactor.Request memory request, bytes memory signature, bytes4 selector)
        internal
    {
        _expectManageRevert(
            address(capability), abi.encodeCall(ILiquidLaneRedeemCapability.signRequest, (request, signature)), selector
        );
    }

    function _expectManageRevert(address target, bytes memory data, bytes4 selector) internal {
        IMerkleAdapter.Action[] memory actions = _authorize(target, data);
        vm.prank(keeper);
        vm.expectRevert(selector);
        adapter.manage(actions);
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
