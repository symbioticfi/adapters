// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ActionAdapterMock, ActionOracleMock, ActionTokenMock} from "./LiquidLaneConnector.t.sol";
import {LiquidLaneConnector} from "../../../src/contracts/merkle-adapter/connectors/LiquidLaneConnector.sol";
import {OracleRegistry} from "../../../src/contracts/merkle-adapter/oracle/OracleRegistry.sol";

import {
    DISCOUNT_PRECISION,
    DISCOUNT_SWAP_TYPEHASH,
    DISCOUNT_TYPEHASH,
    ILiquidLaneAdapter
} from "../../../src/interfaces/ILiquidLaneAdapter.sol";
import {IAssetRateLimits} from "../../../src/interfaces/merkle-adapter/IAssetRateLimits.sol";
import {ILiquidLaneConnector} from "../../../src/interfaces/merkle-adapter/connectors/ILiquidLaneConnector.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

contract LiquidLaneConnectorDiscountTest is Test {
    LiquidLaneConnector internal connector;
    MigratablesFactory internal factory;
    OracleRegistry internal registry;
    ActionAdapterMock internal adapter;
    ActionTokenMock internal asset;
    ActionTokenMock internal rwa;
    address internal curator;
    address internal signer;
    address internal protocol;
    address internal recipient;
    uint256 internal curatorKey;
    uint256 internal signerKey;
    uint256 internal protocolKey;

    function setUp() public {
        (curator, curatorKey) = makeAddrAndKey("curator");
        (signer, signerKey) = makeAddrAndKey("signer");
        (protocol, protocolKey) = makeAddrAndKey("protocol");
        recipient = makeAddr("recipient");
        asset = new ActionTokenMock("USDC", "USDC", 6);
        rwa = new ActionTokenMock("RWA", "RWA", 18);
        adapter = new ActionAdapterMock(address(0), curator);
        registry = new OracleRegistry(address(this));
        factory = new MigratablesFactory(address(this));
        factory.whitelist(address(new LiquidLaneConnector(address(factory), address(registry))));
        connector = LiquidLaneConnector(
            factory.create(1, curator, abi.encode(address(adapter), address(asset), new address[](0)))
        );
        registry.setOracle(address(connector), address(rwa), address(new ActionOracleMock(address(0), 2e18)));
        vm.startPrank(address(adapter));
        connector.addTokenToRedeem(address(rwa));
        connector.setMaxAssetsPerDuration(address(rwa), 1000e6, 1 days);
        vm.stopPrank();
        vm.prank(curator);
        connector.setSigner(signer);
        rwa.mint(address(connector), 500e18);
        asset.mint(address(adapter), 1000e6);
        adapter.approve(address(asset), address(connector), type(uint256).max);
    }

    function testFuzz_SignedSwapPaysDiscountedOracleValue(uint256 amount, uint256 discount, bool byOwner) public {
        amount = bound(amount, 1, 500e18);
        discount = bound(discount, 0, DISCOUNT_PRECISION);
        ILiquidLaneAdapter.DiscountSwap memory request = _request(byOwner ? curator : signer, discount);
        uint256 expected = (amount * 2e6 / 1e18) * (DISCOUNT_PRECISION - discount) / DISCOUNT_PRECISION;
        bytes memory protocolSignature;
        (request, protocolSignature) = _sign(request, byOwner ? curatorKey : signerKey);
        vm.expectEmit(false, false, false, true, address(connector));
        emit ILiquidLaneConnector.DoSwap(ILiquidLaneConnector.Swap(recipient, address(rwa), amount, expected));
        vm.prank(address(adapter));
        assertEq(connector.swap(request, protocolSignature, recipient, amount), expected);
        assertEq(rwa.balanceOf(address(adapter)), amount);
        assertEq(rwa.balanceOf(address(connector)), 500e18 - amount);
        assertEq(asset.balanceOf(recipient), expected);
        assertEq(asset.balanceOf(address(adapter)), 1000e6 - expected);
        assertEq(connector.remainingAssets(address(rwa)), 1000e6 - expected);
        assertFalse(connector.isUsedNonce(address(rwa), request.discount.nonce));
    }

    function test_ProtocolAndOwnerCanUseERC1271Signatures() public {
        address ownerWallet = address(new ConnectorSignatureWallet(curator));
        address protocolWallet = address(new ConnectorSignatureWallet(protocol));
        vm.prank(curator);
        connector.transferOwnership(ownerWallet);
        ILiquidLaneAdapter.DiscountSwap memory request = _request(ownerWallet, 50_000);
        request.discount.protocol = protocolWallet;
        bytes memory protocolSignature;
        (request, protocolSignature) = _sign(request, curatorKey);
        vm.prank(address(adapter));
        assertEq(connector.swap(request, protocolSignature, recipient, 100e18), 190e6);
    }

    function test_ConfiguredSignerCanUseERC1271Signatures() public {
        address signerWallet = address(new ConnectorSignatureWallet(signer));
        vm.prank(curator);
        connector.setSigner(signerWallet);
        ILiquidLaneAdapter.DiscountSwap memory request = _request(signerWallet, 50_000);
        bytes memory protocolSignature;
        (request, protocolSignature) = _sign(request, signerKey);
        vm.prank(address(adapter));
        assertEq(connector.swap(request, protocolSignature, recipient, 100e18), 190e6);
    }

    function test_ERC1271RevocationIsCheckedAtExecution() public {
        ConnectorSignatureWallet signerWallet = new ConnectorSignatureWallet(signer);
        vm.prank(curator);
        connector.setSigner(address(signerWallet));
        ILiquidLaneAdapter.DiscountSwap memory request = _request(address(signerWallet), 50_000);
        bytes memory protocolSignature;
        (request, protocolSignature) = _sign(request, signerKey);
        signerWallet.revoke();
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.InvalidSignature.selector);
    }

    function test_SignedSwapRequiresAdapterEvenWithValidSignatures() public {
        (ILiquidLaneAdapter.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(curator, 50_000), curatorKey);
        vm.prank(curator);
        vm.expectRevert(ILiquidLaneConnector.InvalidCaller.selector);
        connector.swap(request, protocolSignature, recipient, 100e18);
    }

    function test_OwnerCanConfigureSignerAndMinimum() public {
        vm.startPrank(curator);
        vm.expectEmit(true, false, false, true, address(connector));
        emit ILiquidLaneConnector.SetSigner(address(0));
        connector.setSigner(address(0));
        vm.expectEmit(true, false, false, true, address(connector));
        emit ILiquidLaneConnector.SetMinDiscount(address(rwa), 50_000);
        connector.setMinDiscount(address(rwa), 50_000);
        vm.stopPrank();
        assertEq(connector.signer(), address(0));
        assertEq(connector.minDiscount(address(rwa)), 50_000);
    }

    function test_ConfigurationRejectsNonOwnerAndExcessiveMinimum() public {
        vm.startPrank(signer);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, signer));
        connector.setSigner(signer);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, signer));
        connector.setMinDiscount(address(rwa), 10);
        vm.stopPrank();
        vm.prank(curator);
        vm.expectRevert(ILiquidLaneConnector.InvalidDiscount.selector);
        connector.setMinDiscount(address(rwa), DISCOUNT_PRECISION + 1);
    }

    function test_UnknownSignerCannotAuthorizeDiscount() public {
        (ILiquidLaneAdapter.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(protocol, 50_000), protocolKey);
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.InvalidSigner.selector);
    }

    function test_ReplacingSignerRevokesPreviouslySignedDiscount() public {
        (ILiquidLaneAdapter.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 50_000), signerKey);
        vm.prank(curator);
        connector.setSigner(address(0));
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.InvalidSigner.selector);
    }

    function test_TransferringOwnershipRevokesPreviousOwnerDiscount() public {
        (ILiquidLaneAdapter.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(curator, 50_000), curatorKey);
        vm.prank(curator);
        connector.transferOwnership(makeAddr("newOwner"));
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.InvalidSigner.selector);
    }

    function testFuzz_InvalidatedNonceCannotSwap(bool byOwner) public {
        (ILiquidLaneAdapter.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 50_000), signerKey);
        vm.prank(byOwner ? curator : signer);
        vm.expectEmit(true, false, false, true, address(connector));
        emit ILiquidLaneConnector.InvalidateNonce(address(rwa), request.discount.nonce);
        connector.invalidateNonce(address(rwa), request.discount.nonce);
        assertTrue(connector.isUsedNonce(address(rwa), request.discount.nonce));
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.AlreadyUsedNonce.selector);
    }

    function test_NonceInvalidationRejectsStrangerAndFormerSigner() public {
        vm.expectRevert(ILiquidLaneConnector.InvalidCaller.selector);
        connector.invalidateNonce(address(rwa), 1);
        vm.prank(curator);
        connector.setSigner(address(0));
        vm.prank(signer);
        vm.expectRevert(ILiquidLaneConnector.InvalidCaller.selector);
        connector.invalidateNonce(address(rwa), 1);
    }

    function test_NonceInvalidationIsTokenScoped() public {
        (ILiquidLaneAdapter.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 50_000), signerKey);
        vm.prank(signer);
        connector.invalidateNonce(address(asset), request.discount.nonce);
        vm.prank(address(adapter));
        connector.swap(request, protocolSignature, recipient, 100e18);
    }

    function test_DiscountIsReusableUntilInvalidated() public {
        (ILiquidLaneAdapter.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 50_000), signerKey);
        vm.startPrank(address(adapter));
        connector.swap(request, protocolSignature, recipient, 100e18);
        connector.swap(request, protocolSignature, recipient, 100e18);
        vm.stopPrank();
        assertEq(asset.balanceOf(recipient), 380e6);
        assertFalse(connector.isUsedNonce(address(rwa), request.discount.nonce));
    }

    function testFuzz_ExpiredSignerOrProtocolDeadlineReverts(bool signerExpired) public {
        ILiquidLaneAdapter.DiscountSwap memory request = _request(signer, 50_000);
        if (signerExpired) request.discount.deadline = uint48(block.timestamp - 1);
        else request.protocolDeadline = uint48(block.timestamp - 1);
        bytes memory protocolSignature;
        (request, protocolSignature) = _sign(request, signerKey);
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.ExpiredSwap.selector);
    }

    function test_ExactDeadlineRemainsValid() public {
        ILiquidLaneAdapter.DiscountSwap memory request = _request(signer, 50_000);
        request.discount.deadline = uint48(block.timestamp);
        request.protocolDeadline = uint48(block.timestamp);
        bytes memory protocolSignature;
        (request, protocolSignature) = _sign(request, signerKey);
        vm.prank(address(adapter));
        connector.swap(request, protocolSignature, recipient, 100e18);
    }

    function testFuzz_DiscountOutsideConfiguredBoundsReverts(bool tooLarge) public {
        vm.prank(curator);
        connector.setMinDiscount(address(rwa), 50_000);
        ILiquidLaneAdapter.DiscountSwap memory request = _request(signer, tooLarge ? 1_000_001 : 49_999);
        bytes memory protocolSignature;
        (request, protocolSignature) = _sign(request, signerKey);
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.InvalidDiscount.selector);
    }

    function test_UpdatedMinimumAppliesToPreviouslySignedDiscount() public {
        (ILiquidLaneAdapter.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 50_000), signerKey);
        vm.prank(curator);
        connector.setMinDiscount(address(rwa), 50_001);
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.InvalidDiscount.selector);
    }

    function test_InvalidSignerSignatureReverts() public {
        (ILiquidLaneAdapter.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 50_000), curatorKey);
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.InvalidSignature.selector);
    }

    function test_InvalidProtocolCounterSignatureReverts() public {
        (ILiquidLaneAdapter.DiscountSwap memory request,) = _sign(_request(signer, 50_000), signerKey);
        _expectFailure(request, request.signerSignature, ILiquidLaneConnector.InvalidSignature.selector);
    }

    function test_ProtocolCounterSignatureCommitsSignerSignatureAndDeadline() public {
        (ILiquidLaneAdapter.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 50_000), signerKey);
        ++request.protocolDeadline;
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.InvalidSignature.selector);
    }

    function test_DiscountSignatureCannotBeReplayedOnAnotherConnectorOrChain() public {
        (ILiquidLaneAdapter.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 50_000), signerKey);
        vm.chainId(block.chainid + 1);
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.InvalidSignature.selector);
        vm.chainId(block.chainid - 1);
        connector = LiquidLaneConnector(
            factory.create(1, curator, abi.encode(address(adapter), address(asset), new address[](0)))
        );
        vm.prank(curator);
        connector.setSigner(signer);
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.InvalidSignature.selector);
    }

    function test_EIP712DomainUsesProxyRatherThanImplementation() public view {
        (, string memory name, string memory domainVersion, uint256 chainId, address verifyingContract,,) =
            connector.eip712Domain();
        assertEq(name, "LiquidLaneConnector");
        assertEq(domainVersion, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(connector));
        assertNotEq(verifyingContract, factory.implementation(1));
    }

    function test_SignedSwapSharesBudgetWithPlainSwapAndRollsBack() public {
        (ILiquidLaneAdapter.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 50_000), signerKey);
        vm.startPrank(address(adapter));
        connector.setMaxAssetsPerDuration(address(rwa), 200e6, 1 days);
        connector.swap(ILiquidLaneConnector.Swap(recipient, address(rwa), 5e18, 10e6));
        connector.swap(request, protocolSignature, recipient, 100e18);
        vm.expectRevert(IAssetRateLimits.AssetLimitExceeded.selector);
        connector.swap(request, protocolSignature, recipient, 100e18);
        vm.stopPrank();
        assertEq(asset.balanceOf(recipient), 200e6);
        assertEq(rwa.balanceOf(address(adapter)), 105e18);
        assertEq(connector.remainingAssets(address(rwa)), 0);
    }

    function test_SignedSwapRejectsUnknownToken() public {
        ILiquidLaneAdapter.DiscountSwap memory request = _request(signer, 50_000);
        request.discount.tokenToRedeem = address(asset);
        bytes memory protocolSignature;
        (request, protocolSignature) = _sign(request, signerKey);
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.InvalidTokenToRedeem.selector);
    }

    function test_SignedSwapRejectsInsufficientInventory() public {
        (ILiquidLaneAdapter.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 50_000), signerKey);
        vm.prank(address(adapter));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(connector), uint256(500e18), uint256(501e18)
            )
        );
        connector.swap(request, protocolSignature, recipient, 501e18);

        assertEq(connector.remainingAssets(address(rwa)), 1000e6);
        assertEq(rwa.balanceOf(address(connector)), 500e18);
        assertEq(rwa.balanceOf(address(adapter)), 0);
        assertEq(asset.balanceOf(address(adapter)), 1000e6);
        assertEq(asset.balanceOf(recipient), 0);
    }

    function testFuzz_TokenCallbackCannotChangeSignedSwapPolicy(uint8 operation) public {
        operation = uint8(bound(operation, 0, 2));
        (ILiquidLaneAdapter.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 50_000), signerKey);
        vm.prank(curator);
        connector.transferOwnership(address(adapter));
        bytes memory mutation = operation == 0
            ? abi.encodeCall(ILiquidLaneConnector.setSigner, (address(0)))
            : operation == 1
                ? abi.encodeCall(ILiquidLaneConnector.setMinDiscount, (address(rwa), 1_000_000))
                : abi.encodeCall(ILiquidLaneConnector.invalidateNonce, (address(rwa), request.discount.nonce));
        rwa.setCallback(address(adapter), abi.encodeCall(adapter.execute, (address(connector), mutation)));
        _expectFailure(request, protocolSignature, ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(connector.signer(), signer);
        assertEq(connector.minDiscount(address(rwa)), 0);
        assertFalse(connector.isUsedNonce(address(rwa), request.discount.nonce));
        assertEq(connector.remainingAssets(address(rwa)), 1000e6);
    }

    function test_MigrationPreservesSignerPolicyAndInvalidatedNonces() public {
        vm.startPrank(curator);
        connector.setMinDiscount(address(rwa), 50_000);
        connector.invalidateNonce(address(rwa), 7);
        vm.stopPrank();
        factory.whitelist(address(new LiquidLaneConnector(address(factory), address(registry))));
        vm.prank(curator);
        factory.migrate(address(connector), 2, "");
        assertEq(connector.signer(), signer);
        assertEq(connector.minDiscount(address(rwa)), 50_000);
        assertTrue(connector.isUsedNonce(address(rwa), 7));
        (ILiquidLaneAdapter.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 50_000), signerKey);
        vm.prank(address(adapter));
        connector.swap(request, protocolSignature, recipient, 100e18);
    }

    function _request(address discountSigner, uint256 discount)
        internal
        view
        returns (ILiquidLaneAdapter.DiscountSwap memory)
    {
        return ILiquidLaneAdapter.DiscountSwap({
            discount: ILiquidLaneAdapter.Discount({
                tokenToRedeem: address(rwa),
                discount: discount,
                signer: discountSigner,
                protocol: protocol,
                nonce: 42,
                deadline: uint48(block.timestamp + 1 days)
            }),
            signerSignature: "",
            protocolDeadline: uint48(block.timestamp + 1 hours)
        });
    }

    function _sign(ILiquidLaneAdapter.DiscountSwap memory request, uint256 privateKey)
        internal
        view
        returns (ILiquidLaneAdapter.DiscountSwap memory, bytes memory)
    {
        bytes32 discountHash = keccak256(abi.encode(DISCOUNT_TYPEHASH, request.discount));
        request.signerSignature = _signature(privateKey, discountHash);
        return (
            request,
            _signature(
                protocolKey,
                keccak256(
                    abi.encode(
                        DISCOUNT_SWAP_TYPEHASH,
                        discountHash,
                        keccak256(request.signerSignature),
                        request.protocolDeadline
                    )
                )
            )
        );
    }

    function _signature(uint256 privateKey, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("LiquidLaneConnector"),
                keccak256("1"),
                block.chainid,
                address(connector)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(privateKey, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _expectFailure(
        ILiquidLaneAdapter.DiscountSwap memory request,
        bytes memory protocolSignature,
        bytes4 errorSelector
    ) internal {
        vm.prank(address(adapter));
        vm.expectRevert(errorSelector);
        connector.swap(request, protocolSignature, recipient, 100e18);
        assertEq(asset.balanceOf(recipient), 0);
        assertEq(rwa.balanceOf(address(adapter)), 0);
    }
}

contract ConnectorSignatureWallet is IERC1271 {
    address internal immutable _signer;
    bool internal _revoked;

    constructor(address newSigner) {
        _signer = newSigner;
    }

    function revoke() external {
        _revoked = true;
    }

    function isValidSignature(bytes32 digest, bytes memory signature) external view returns (bytes4) {
        return !_revoked && ECDSA.recover(digest, signature) == _signer ? IERC1271.isValidSignature.selector : bytes4(0);
    }
}
