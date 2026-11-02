// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {merkleAdapterInitParams} from "test/helpers/MerkleInitialization.sol";

import {AccountRegistry} from "../../../src/contracts/ll-adapter/AccountRegistry.sol";
import {AdapterFactory} from "../../../src/contracts/AdapterFactory.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {IReactor} from "../../mocks/liquid-lane-redeem/IReactor.sol";
import {LiquidLaneAdapter} from "../../../src/contracts/LiquidLaneAdapter.sol";
import {
    LiquidLaneReactorReference,
    LiquidLaneRedeemFiller,
    LiquidLaneRedeemTokenMock
} from "../../mocks/liquid-lane-redeem/LiquidLaneRedeemMocks.sol";
import {MerkleAccount} from "src/contracts/merkle-adapter/MerkleAccount.sol";
import {MerkleAdapterOracleMock} from "../MerkleAdapter.t.sol";
import {MerkleAdapter} from "../../../src/contracts/MerkleAdapter.sol";
import {
    MockERC20,
    MockLiquidLaneAccount,
    MockLiquidLaneOracle,
    MockLiquidLaneVault,
    MockVaultRegistry
} from "../LiquidLaneAdapter.t.sol";
import {RootRegistry} from "../../../src/contracts/merkle-adapter/RootRegistry.sol";

import {ActionMasker} from "../../../src/contracts/merkle-adapter/libraries/ActionMasker.sol";

import {ILiquidLaneAdapter} from "../../../src/interfaces/ILiquidLaneAdapter.sol";
import {
    ILiquidLaneReactor,
    LIQUID_LANE_REQUEST_TYPEHASH,
    LIQUID_LANE_OUTPUT_TYPEHASH
} from "../../../src/interfaces/merkle-adapter/ILiquidLaneReactor.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {IMerkleAdapter} from "../../../src/interfaces/IMerkleAdapter.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

import {createMerkleAccountFactory} from "test/helpers/MerkleAccountFactory.sol";

contract MerkleAdapterLiquidLaneSignaturesTest is Test {
    /// @dev Deterministic test-only protocol signing key; never used outside this fixture.
    uint256 internal constant PROTOCOL_KEY = 0xA11CE;

    MockERC20 internal asset;
    LiquidLaneRedeemTokenMock internal rwa;
    MerkleAdapter internal adapter;
    address internal account;
    RootRegistry internal rootRegistry;
    LiquidLaneAdapter internal liquidLane;
    AdapterFactory internal liquidLaneFactory;
    LiquidLaneReactorReference internal reactor;
    LiquidLaneRedeemFiller internal filler;

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
                    createMerkleAccountFactory(
                        address(this),
                        address(merkleFactory),
                        address(rootRegistry),
                        address(new CapabilitiesRegistry(address(this)))
                    )
                )
            )
        );
        adapter = MerkleAdapter(
            payable(merkleFactory.create(
                    1,
                    address(this),
                    abi.encode(address(consumerVault), abi.encode(merkleAdapterInitParams(address(this))))
                ))
        );

        account = adapter.account();
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
        rwa.mint(account, 1000e18);
    }

    function test_SignAndFillThroughReactorWithoutInstallingCapability() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        assertEq(MerkleAccount(payable(account)).getCapabilities().length, 0);
        assertTrue(IMerkleAccount(account).signatures(digest));
        assertEq(IMerkleAccount(account).isValidSignature(digest, ""), IERC1271.isValidSignature.selector);
        _fill(request, hex"00", 90e18);
        assertEq(asset.balanceOf(account), 90e18);
        assertEq(rwa.balanceOf(supplierReceiver), 100e18);
        assertEq(rwa.balanceOf(account), 900e18);
        assertEq(rwa.allowance(account, address(reactor)), 0);
        assertTrue(reactor.isUsedNonce(account, request.nonce));
        // Approval remains stored; the Reactor owns nonce replay protection.
        assertTrue(IMerkleAccount(account).signatures(digest));
        _fill(request, "", 90e18, abi.encodePacked(IReactor.NonceUsed.selector));
    }

    function test_UnsignedRequestCannotSpendAndEmptySignatureWorksAfterApproval() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _requestDigest(request);
        assertEq(IMerkleAccount(account).isValidSignature(digest, ""), bytes4(0xffffffff));
        _fill(request, "", 90e18, abi.encodePacked(IReactor.InvalidProtocolSignature.selector));
        _sign(request);
        _fill(request, "", 90e18);
    }

    function testFuzz_ChangedRequestCannotUseApprovedDigest(uint8 field, uint128 difference) public {
        field = uint8(bound(field, 0, 7));
        uint256 delta = bound(difference, 1, type(uint128).max);
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        if (field == 0) request.tokenIn = address(uint160(uint256(uint160(request.tokenIn)) ^ delta));
        else if (field == 1) request.amountIn += delta;
        else if (field == 2) request.outputs[0].amount += delta;
        else if (field == 3) request.outputs[0].recipient = address(uint160(uint256(uint160(account)) ^ delta));
        else if (field == 4) request.outputs[0].token = address(uint160(uint256(uint160(address(asset))) ^ delta));
        else if (field == 5) request.deadline += delta;
        else if (field == 6) request.nonce += delta;
        else request.protocol = address(uint160(uint256(uint160(protocol)) ^ delta));
        assertNotEq(digest, _requestDigest(request));
        assertEq(IMerkleAccount(account).isValidSignature(_requestDigest(request), ""), bytes4(0xffffffff));
    }

    function test_MaskAllowsAmountsAndTimingButPinsPairRecipientProtocolAndDomain() public {
        ILiquidLaneReactor.Request memory request = _request();
        _manage(request.tokenIn, abi.encodeCall(IERC20.approve, (address(reactor), uint256(120e18))));
        bytes memory data = abi.encodeCall(IMerkleAccount.sign, (_domain(), _signature(request), _hashes()));
        bytes memory mask = new bytes(data.length);
        // Buffer words: 0 typehash, 1 tokenIn, 2 amountIn, 3 outputs hash, 4 deadline, 5 nonce,
        // 6 protocol, then the scratch output. Calldata words are those plus the four-word header.
        uint256[4] memory free = [uint256(6), 8, 9, 13];
        for (uint256 i; i < free.length; ++i) {
            for (uint256 j; j < 32; ++j) {
                mask[4 + free[i] * 32 + j] = 0xff;
            }
        }
        bytes32 leaf = ActionMasker.mask(account, 0, data, mask);
        rootRegistry.setRoot(account, leaf);
        MerkleAccount(payable(account)).acceptRoot(leaf);
        MerkleAccount(payable(account)).grantRole(leaf, keeper);
        request.amountIn = 120e18;
        request.outputs[0].amount = 110e18;
        request.deadline++;
        request.nonce++;
        IMerkleAccount.Action[] memory actions = new IMerkleAccount.Action[](1);
        data = abi.encodeCall(IMerkleAccount.sign, (_domain(), _signature(request), _hashes()));
        actions[0] =
            IMerkleAccount.Action({target: account, value: 0, data: data, dataMask: mask, proof: new bytes32[](0)});
        vm.prank(keeper);
        MerkleAccount(payable(account)).manage(actions);
        assertEq(
            IMerkleAccount(account).isValidSignature(_requestDigest(request), ""), IERC1271.isValidSignature.selector
        );
        // Every other byte, including pair, recipient, protocol, type/domain and all ABI offsets, is fixed.
        for (uint256 i; i < data.length; ++i) {
            if (mask[i] == 0xff) continue;
            data[i] ^= 0x01;
            assertNotEq(ActionMasker.mask(account, 0, data, mask), leaf);
            data[i] ^= 0x01;
        }
        request.outputs[0].recipient = keeper;
        actions[0].data = abi.encodeCall(IMerkleAccount.sign, (_domain(), _signature(request), _hashes()));
        vm.prank(keeper);
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        MerkleAccount(payable(account)).manage(actions);
        request.outputs[0].recipient = account;
        request.outputs[0].token = address(rwa);
        actions[0].data = abi.encodeCall(IMerkleAccount.sign, (_domain(), _signature(request), _hashes()));
        vm.prank(keeper);
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        MerkleAccount(payable(account)).manage(actions);
        request.outputs[0].token = address(asset);
        _fill(request, "", 110e18);
        assertEq(asset.balanceOf(account), 110e18);
    }

    function testFuzz_HashMatchesReactorForSingleOutput(
        uint128 amount,
        uint128 minimumOutput,
        uint256 nonce,
        address recipient
    ) public {
        ILiquidLaneReactor.Request memory request = _request();
        request.amountIn = amount;
        request.outputs[0].amount = minimumOutput;
        request.outputs[0].recipient = recipient;
        request.nonce = nonce;
        _manage(account, abi.encodeCall(IMerkleAccount.sign, (_domain(), _signature(request), _hashes())));
        assertEq(
            IMerkleAccount(account).isValidSignature(_requestDigest(request), ""), IERC1271.isValidSignature.selector
        );
    }

    function test_RecipientChosenByTheLeafReceivesTheOutput() public {
        ILiquidLaneReactor.Request memory request = _request();
        request.outputs[0].recipient = keeper;
        _sign(request);
        _fill(request, "", 90e18);
        assertEq(asset.balanceOf(keeper), 90e18);
        assertEq(asset.balanceOf(account), 0);
    }

    function test_AdditionalOrMissingOutputCannotUseSingleOutputApproval() public {
        ILiquidLaneReactor.Request memory request = _request();
        _sign(request);
        request.outputs = new ILiquidLaneReactor.Output[](0);
        assertEq(IMerkleAccount(account).isValidSignature(_requestDigest(request), ""), bytes4(0xffffffff));
        request.outputs = new ILiquidLaneReactor.Output[](2);
        request.outputs[0] = ILiquidLaneReactor.Output({token: address(asset), amount: 90e18, recipient: account});
        request.outputs[1] = ILiquidLaneReactor.Output({token: address(asset), amount: 1, recipient: keeper});
        _fill(request, "", 90e18, abi.encodePacked(IReactor.InvalidProtocolSignature.selector));
    }

    function test_HashProgramAndOutputShapeCannotBeChangedThroughTheLeaf() public {
        ILiquidLaneReactor.Request memory request = _request();
        IMerkleAccount.Action[] memory actions =
            _authorize(account, abi.encodeCall(IMerkleAccount.sign, (_domain(), _signature(request), _hashes())));
        IMerkleAccount.Hash[] memory hashes = _hashes();
        hashes[1].length = 64;
        actions[0].data = abi.encodeCall(IMerkleAccount.sign, (_domain(), _signature(request), hashes));
        vm.prank(keeper);
        vm.expectRevert(IMerkleAccount.InvalidMerkleProof.selector);
        MerkleAccount(payable(account)).manage(actions);
        actions[0].data = abi.encodeCall(
            IMerkleAccount.sign,
            (_domain(), bytes.concat(_signature(request), abi.encode(request.outputs[0])), _hashes())
        );
        vm.prank(keeper);
        vm.expectRevert();
        MerkleAccount(payable(account)).manage(actions);
    }

    function test_ChangedChainOrReactorUsesAnUnapprovedDigest() public {
        ILiquidLaneReactor.Request memory request = _request();
        _sign(request);
        vm.chainId(block.chainid + 1);
        assertEq(IMerkleAccount(account).isValidSignature(_requestDigest(request), ""), bytes4(0xffffffff));
        vm.chainId(block.chainid - 1);
        reactor = new LiquidLaneReactorReference(address(liquidLaneFactory));
        assertEq(IMerkleAccount(account).isValidSignature(_requestDigest(request), ""), bytes4(0xffffffff));
    }

    function test_ReactorEnforcesDeadlineAtSettlement() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        vm.warp(request.deadline + 1);
        assertTrue(IMerkleAccount(account).signatures(digest));
        _fill(request, "", 90e18, abi.encodePacked(IReactor.ExpiredRequest.selector));
    }

    function test_RevocationBlocksSettlementWithoutTouchingFundsOrNonce() public {
        ILiquidLaneReactor.Request memory request = _request();
        bytes32 digest = _sign(request);
        IMerkleAccount(account).revokeSignature(digest);
        assertFalse(IMerkleAccount(account).signatures(digest));
        _fill(request, "", 90e18, abi.encodePacked(IReactor.InvalidProtocolSignature.selector));
        assertFalse(reactor.isUsedNonce(account, request.nonce));
        assertEq(rwa.balanceOf(account), 1000e18);
        assertEq(rwa.allowance(account, address(reactor)), 100e18);
    }

    function test_NonceCancellationBlocksAllApprovedRequestsSharingNonce() public {
        ILiquidLaneReactor.Request memory first = _request();
        _sign(first);
        ILiquidLaneReactor.Request memory second = _request();
        second.amountIn = 200e18;
        _sign(second);
        _manage(address(reactor), abi.encodeCall(ILiquidLaneReactor.invalidateNonce, (first.nonce)));
        _fill(first, "", 90e18, abi.encodePacked(IReactor.NonceUsed.selector));
        _fill(second, "", 90e18, abi.encodePacked(IReactor.NonceUsed.selector));
    }

    /// @dev Words 0-6 are the request struct, with word 3 reserved for the outputs array hash.
    /// Words 7-10 are the scratch encoding of the single output.
    function _signature(ILiquidLaneReactor.Request memory request) internal pure returns (bytes memory) {
        return abi.encode(
            LIQUID_LANE_REQUEST_TYPEHASH,
            request.tokenIn,
            request.amountIn,
            bytes32(0),
            request.deadline,
            request.nonce,
            request.protocol,
            LIQUID_LANE_OUTPUT_TYPEHASH,
            request.outputs[0]
        );
    }

    function _hashes() internal pure returns (IMerkleAccount.Hash[] memory hashes) {
        hashes = new IMerkleAccount.Hash[](3);
        hashes[0] = IMerkleAccount.Hash({offset: 224, length: 128, destination: 224});
        hashes[1] = IMerkleAccount.Hash({offset: 224, length: 32, destination: 96});
        hashes[2] = IMerkleAccount.Hash({offset: 0, length: 224, destination: 0});
    }

    function _domain() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Reactor"),
                keccak256("1"),
                block.chainid,
                address(reactor)
            )
        );
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
        request.outputs[0] = ILiquidLaneReactor.Output({token: address(asset), amount: 90e18, recipient: account});
    }

    function _sign(ILiquidLaneReactor.Request memory request) internal returns (bytes32 digest) {
        _manage(request.tokenIn, abi.encodeCall(IERC20.approve, (address(reactor), request.amountIn)));
        digest = _requestDigest(request);
        _manage(account, abi.encodeCall(IMerkleAccount.sign, (_domain(), _signature(request), _hashes())));
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
            swapper: account,
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
        IMerkleAccount.Action[] memory actions = _authorize(target, data);
        vm.prank(keeper);
        bytes[] memory results = MerkleAccount(payable(account)).manage(actions);
        result = results[0];
    }

    function _authorize(address target, bytes memory data) internal returns (IMerkleAccount.Action[] memory actions) {
        bytes memory mask = new bytes(data.length);
        bytes32 leaf =
            keccak256(bytes.concat(keccak256(abi.encode(target, bytes1(0), keccak256(mask), keccak256(data)))));
        rootRegistry.setRoot(account, leaf);
        MerkleAccount(payable(account)).acceptRoot(leaf);
        MerkleAccount(payable(account)).grantRole(leaf, keeper);
        actions = new IMerkleAccount.Action[](1);
        actions[0] =
            IMerkleAccount.Action({target: target, value: 0, data: data, dataMask: mask, proof: new bytes32[](0)});
    }
}
