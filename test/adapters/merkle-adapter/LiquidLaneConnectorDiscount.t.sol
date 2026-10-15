// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {AssetRateLimits} from "src/contracts/merkle-adapter/libraries/AssetRateLimits.sol";

import {ActionAccountMock, ActionOracleMock, ActionTokenMock} from "./LiquidLaneConnector.t.sol";
import {LiquidLaneConnector} from "../../../src/contracts/merkle-adapter/connectors/LiquidLaneConnector.sol";
import {ImmutableFactory} from "../../../src/contracts/common/ImmutableFactory.sol";
import {OracleRegistry} from "../../../src/contracts/merkle-adapter/connectors/OracleRegistry.sol";

import {
    DISCOUNT_PRECISION,
    DISCOUNT_SWAP_TYPEHASH,
    DISCOUNT_TYPEHASH,
    ILiquidLaneConnector
} from "../../../src/interfaces/merkle-adapter/connectors/ILiquidLaneConnector.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";

contract LiquidLaneConnectorDiscountTest is Test {
    LiquidLaneConnector internal connector;
    MigratablesFactory internal factory;
    ImmutableFactory internal merkleAccountFactory;
    OracleRegistry internal registry;
    ActionAccountMock internal account;
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
        merkleAccountFactory = new ImmutableFactory(type(ActionAccountMock).creationCode);
        account = ActionAccountMock(merkleAccountFactory.create(abi.encode(address(0), curator)));
        registry = new OracleRegistry(address(this));
        factory = new MigratablesFactory(address(this));
        factory.whitelist(
            address(new LiquidLaneConnector(address(factory), address(merkleAccountFactory), address(registry)))
        );
        connector = LiquidLaneConnector(factory.create(1, curator, abi.encode(address(account), address(asset))));
        address reviewedOracle = address(new ActionOracleMock(address(0), 2e18));
        registry.setOracle(address(connector), address(rwa), reviewedOracle);
        vm.startPrank(address(account));
        connector.addTokenToRedeem(address(rwa), reviewedOracle);
        connector.setMaxAssetsPerDuration(address(rwa), 1000e6, 1 days);
        vm.stopPrank();
        vm.prank(curator);
        connector.setSigner(signer);
        rwa.mint(address(connector), 500e18);
        asset.mint(address(account), 1000e6);
        account.approve(address(asset), address(connector), type(uint256).max);
    }

    function testFuzz_DiscountSwapPaysDiscountedOracleValue(uint256 amount, uint256 discount, bool byOwner) public {
        amount = bound(amount, 1, 500e18);
        discount = bound(discount, 0, DISCOUNT_PRECISION);
        ILiquidLaneConnector.DiscountSwap memory request = _request(byOwner ? curator : signer, discount);
        uint256 expected = (amount * 2e6 / 1e18) * (DISCOUNT_PRECISION - discount) / DISCOUNT_PRECISION;
        bytes memory protocolSignature;
        (request, protocolSignature) = _sign(request, byOwner ? curatorKey : signerKey);
        vm.expectEmit(false, false, false, true, address(connector));
        emit ILiquidLaneConnector.DoSwap(ILiquidLaneConnector.Swap({
                recipient: recipient, tokenIn: address(rwa), amountIn: amount, amountOut: expected
            }));
        vm.prank(address(account));
        assertEq(connector.swap(request, protocolSignature, recipient, amount), expected);
        assertEq(rwa.balanceOf(address(account)), amount);
        assertEq(rwa.balanceOf(address(connector)), 500e18 - amount);
        assertEq(asset.balanceOf(recipient), expected);
        assertEq(asset.balanceOf(address(account)), 1000e6 - expected);
        assertEq(connector.remainingAssets(address(rwa)), 1000e6 - expected);
        assertFalse(connector.isUsedNonce(address(rwa), request.discount.nonce));
    }

    /// forge-config: default.isolate = true
    function test_ProtocolAndOwnerCanUseERC1271Signatures() public {
        address ownerWallet = address(new ConnectorSignatureWallet(curator));
        address protocolWallet = address(new ConnectorSignatureWallet(protocol));
        vm.prank(curator);
        connector.transferOwnership(ownerWallet);
        ILiquidLaneConnector.DiscountSwap memory request = _request(ownerWallet, 5_000_000);
        request.discount.protocol = protocolWallet;
        bytes memory protocolSignature;
        (request, protocolSignature) = _sign(request, curatorKey);
        vm.prank(address(account));
        uint256 amountOut = connector.swap(request, protocolSignature, recipient, 100e18);
        vm.snapshotGasLastCall("LiquidLaneConnector", "swapDiscountERC1271");
        assertEq(amountOut, 190e6);
    }

    function test_ConfiguredSignerCanUseERC1271Signatures() public {
        address signerWallet = address(new ConnectorSignatureWallet(signer));
        vm.prank(curator);
        connector.setSigner(signerWallet);
        ILiquidLaneConnector.DiscountSwap memory request = _request(signerWallet, 5_000_000);
        bytes memory protocolSignature;
        (request, protocolSignature) = _sign(request, signerKey);
        vm.prank(address(account));
        assertEq(connector.swap(request, protocolSignature, recipient, 100e18), 190e6);
    }

    function test_ERC1271RevocationIsCheckedAtExecution() public {
        ConnectorSignatureWallet signerWallet = new ConnectorSignatureWallet(signer);
        vm.prank(curator);
        connector.setSigner(address(signerWallet));
        ILiquidLaneConnector.DiscountSwap memory request = _request(address(signerWallet), 5_000_000);
        bytes memory protocolSignature;
        (request, protocolSignature) = _sign(request, signerKey);
        signerWallet.revoke();
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.InvalidSignature.selector);
    }

    function test_DiscountSwapRequiresAccountEvenWithValidSignatures() public {
        (ILiquidLaneConnector.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(curator, 5_000_000), curatorKey);
        vm.prank(curator);
        vm.expectRevert(ILiquidLaneConnector.InvalidCaller.selector);
        connector.swap(request, protocolSignature, recipient, 100e18);
    }

    /// forge-config: default.isolate = true
    function test_OwnerCanConfigureSignerAndMinimum() public {
        vm.startPrank(curator);
        vm.expectEmit(true, false, false, true, address(connector));
        emit ILiquidLaneConnector.SetSigner(address(0));
        connector.setSigner(address(0));
        vm.snapshotGasLastCall("LiquidLaneConnector", "setSignerDisable");
        vm.expectEmit(true, false, false, true, address(connector));
        emit ILiquidLaneConnector.SetMinDiscount(address(rwa), 5_000_000);
        connector.setMinDiscount(address(rwa), 5_000_000);
        vm.snapshotGasLastCall("LiquidLaneConnector", "setMinDiscount");
        vm.stopPrank();
        assertEq(connector.signer(), address(0));
        assertEq(connector.minDiscount(address(rwa)), 5_000_000);
        vm.startPrank(curator);
        connector.setSigner(signer);
        vm.snapshotGasLastCall("LiquidLaneConnector", "setSigner");
        connector.setMinDiscount(address(rwa), 10_000_000);
        vm.snapshotGasLastCall("LiquidLaneConnector", "replaceMinDiscount");
        vm.stopPrank();
        assertEq(connector.signer(), signer);
        assertEq(connector.minDiscount(address(rwa)), 10_000_000);
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
        (ILiquidLaneConnector.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(protocol, 5_000_000), protocolKey);
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.InvalidSigner.selector);
    }

    function test_ReplacingSignerRevokesPreviouslySignedDiscount() public {
        (ILiquidLaneConnector.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 5_000_000), signerKey);
        vm.prank(curator);
        connector.setSigner(address(0));
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.InvalidSigner.selector);
    }

    function test_TransferringOwnershipRevokesPreviousOwnerDiscount() public {
        (ILiquidLaneConnector.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(curator, 5_000_000), curatorKey);
        vm.prank(curator);
        connector.transferOwnership(makeAddr("newOwner"));
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.InvalidSigner.selector);
    }

    function testFuzz_InvalidatedNonceCannotSwap(bool byOwner) public {
        (ILiquidLaneConnector.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 5_000_000), signerKey);
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

    /// forge-config: default.isolate = true
    function test_NonceInvalidationIsTokenScoped() public {
        (ILiquidLaneConnector.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 5_000_000), signerKey);
        vm.prank(signer);
        connector.invalidateNonce(address(asset), request.discount.nonce);
        vm.snapshotGasLastCall("LiquidLaneConnector", "invalidateNonceBySigner");
        vm.prank(address(account));
        connector.swap(request, protocolSignature, recipient, 100e18);
    }

    /// forge-config: default.isolate = true
    function test_DiscountIsReusableUntilInvalidated() public {
        (ILiquidLaneConnector.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 5_000_000), signerKey);
        vm.startPrank(address(account));
        connector.swap(request, protocolSignature, recipient, 100e18);
        connector.swap(request, protocolSignature, recipient, 100e18);
        vm.snapshotGasLastCall("LiquidLaneConnector", "swapDiscountSamePeriod");
        vm.stopPrank();
        assertEq(asset.balanceOf(recipient), 380e6);
        assertFalse(connector.isUsedNonce(address(rwa), request.discount.nonce));
        vm.prank(curator);
        connector.invalidateNonce(address(rwa), request.discount.nonce);
        vm.snapshotGasLastCall("LiquidLaneConnector", "invalidateNonceByOwner");
        assertTrue(connector.isUsedNonce(address(rwa), request.discount.nonce));
        vm.prank(address(account));
        vm.expectRevert(ILiquidLaneConnector.AlreadyUsedNonce.selector);
        connector.swap(request, protocolSignature, recipient, 100e18);
        assertEq(asset.balanceOf(recipient), 380e6);
        assertEq(rwa.balanceOf(address(account)), 200e18);
    }

    function testFuzz_ExpiredSignerOrProtocolDeadlineReverts(bool signerExpired) public {
        ILiquidLaneConnector.DiscountSwap memory request = _request(signer, 5_000_000);
        if (signerExpired) request.discount.deadline = uint48(block.timestamp - 1);
        else request.protocolDeadline = uint48(block.timestamp - 1);
        bytes memory protocolSignature;
        (request, protocolSignature) = _sign(request, signerKey);
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.ExpiredSwap.selector);
    }

    function test_ExactDeadlineRemainsValid() public {
        ILiquidLaneConnector.DiscountSwap memory request = _request(signer, 5_000_000);
        request.discount.deadline = uint48(block.timestamp);
        request.protocolDeadline = uint48(block.timestamp);
        bytes memory protocolSignature;
        (request, protocolSignature) = _sign(request, signerKey);
        vm.prank(address(account));
        connector.swap(request, protocolSignature, recipient, 100e18);
    }

    function testFuzz_DiscountOutsideConfiguredBoundsReverts(bool tooLarge) public {
        vm.prank(curator);
        connector.setMinDiscount(address(rwa), 5_000_000);
        ILiquidLaneConnector.DiscountSwap memory request = _request(signer, tooLarge ? 100_000_001 : 4_999_999);
        bytes memory protocolSignature;
        (request, protocolSignature) = _sign(request, signerKey);
        vm.prank(address(account));
        if (tooLarge) vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        else vm.expectRevert(ILiquidLaneConnector.InvalidDiscount.selector);
        connector.swap(request, protocolSignature, recipient, 100e18);
        assertEq(asset.balanceOf(recipient), 0);
        assertEq(rwa.balanceOf(address(account)), 0);
    }

    function test_UpdatedMinimumAppliesToPreviouslySignedDiscount() public {
        (ILiquidLaneConnector.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 5_000_000), signerKey);
        vm.prank(curator);
        connector.setMinDiscount(address(rwa), 5_000_001);
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.InvalidDiscount.selector);
    }

    function test_InvalidSignerSignatureReverts() public {
        (ILiquidLaneConnector.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 5_000_000), curatorKey);
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.InvalidSignature.selector);
    }

    function test_InvalidProtocolCounterSignatureReverts() public {
        (ILiquidLaneConnector.DiscountSwap memory request,) = _sign(_request(signer, 5_000_000), signerKey);
        _expectFailure(request, request.signerSignature, ILiquidLaneConnector.InvalidSignature.selector);
    }

    function test_ProtocolCounterSignatureCommitsSignerSignatureAndDeadline() public {
        (ILiquidLaneConnector.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 5_000_000), signerKey);
        ++request.protocolDeadline;
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.InvalidSignature.selector);
    }

    function test_DiscountSignatureCannotBeReplayedOnAnotherConnectorOrChain() public {
        (ILiquidLaneConnector.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 5_000_000), signerKey);
        vm.chainId(block.chainid + 1);
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.InvalidSignature.selector);
        vm.chainId(block.chainid - 1);
        connector = LiquidLaneConnector(factory.create(1, curator, abi.encode(address(account), address(asset))));
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

    /// forge-config: default.isolate = true
    function test_DiscountSwapSharesBudgetWithPlainSwapAndRollsBack() public {
        (ILiquidLaneConnector.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 5_000_000), signerKey);
        vm.startPrank(address(account));
        connector.setMaxAssetsPerDuration(address(rwa), 200e6, 1 days);
        connector.swap(
            ILiquidLaneConnector.Swap({recipient: recipient, tokenIn: address(rwa), amountIn: 5e18, amountOut: 10e6})
        );
        connector.swap(request, protocolSignature, recipient, 100e18);
        vm.expectRevert(AssetRateLimits.AssetLimitExceeded.selector);
        vm.startSnapshotGas("LiquidLaneConnector", "swapDiscountBudgetExceeded");
        connector.swap(request, protocolSignature, recipient, 100e18);
        vm.stopSnapshotGas("LiquidLaneConnector", "swapDiscountBudgetExceeded");
        vm.stopPrank();
        assertEq(asset.balanceOf(recipient), 200e6);
        assertEq(rwa.balanceOf(address(account)), 105e18);
        assertEq(connector.remainingAssets(address(rwa)), 0);
    }

    function test_DiscountSwapRejectsUnknownToken() public {
        ILiquidLaneConnector.DiscountSwap memory request = _request(signer, 5_000_000);
        request.discount.tokenToRedeem = address(asset);
        bytes memory protocolSignature;
        (request, protocolSignature) = _sign(request, signerKey);
        _expectFailure(request, protocolSignature, ILiquidLaneConnector.InvalidTokenToRedeem.selector);
    }

    function test_DiscountSwapRejectsInsufficientInventory() public {
        (ILiquidLaneConnector.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 5_000_000), signerKey);
        vm.prank(address(account));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(connector), uint256(500e18), uint256(501e18)
            )
        );
        connector.swap(request, protocolSignature, recipient, 501e18);

        assertEq(connector.remainingAssets(address(rwa)), 1000e6);
        assertEq(rwa.balanceOf(address(connector)), 500e18);
        assertEq(rwa.balanceOf(address(account)), 0);
        assertEq(asset.balanceOf(address(account)), 1000e6);
        assertEq(asset.balanceOf(recipient), 0);
    }

    function testFuzz_OwnerCallbackCanChangeDiscountSwapPolicy(uint8 operation) public {
        operation = uint8(bound(operation, 0, 2));
        (ILiquidLaneConnector.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 5_000_000), signerKey);
        vm.prank(curator);
        connector.transferOwnership(address(account));
        bytes memory mutation = operation == 0
            ? abi.encodeCall(ILiquidLaneConnector.setSigner, (address(0)))
            : operation == 1
                ? abi.encodeCall(ILiquidLaneConnector.setMinDiscount, (address(rwa), 100_000_000))
                : abi.encodeCall(ILiquidLaneConnector.invalidateNonce, (address(rwa), request.discount.nonce));
        rwa.setCallback(address(account), abi.encodeCall(account.execute, (address(connector), mutation)));
        vm.prank(address(account));
        assertEq(connector.swap(request, protocolSignature, recipient, 100e18), 190e6);
        assertEq(connector.signer(), operation == 0 ? address(0) : signer);
        assertEq(connector.minDiscount(address(rwa)), operation == 1 ? 100_000_000 : 0);
        assertEq(connector.isUsedNonce(address(rwa), request.discount.nonce), operation == 2);
        assertEq(connector.remainingAssets(address(rwa)), 810e6);
        assertEq(asset.balanceOf(recipient), 190e6);
        assertEq(rwa.balanceOf(address(account)), 100e18);
    }

    function test_FailedMigrationPreservesSignerPolicyAndInvalidatedNonces() public {
        vm.startPrank(curator);
        connector.setMinDiscount(address(rwa), 5_000_000);
        connector.invalidateNonce(address(rwa), 7);
        vm.stopPrank();
        factory.whitelist(
            address(new LiquidLaneConnector(address(factory), address(merkleAccountFactory), address(registry)))
        );
        vm.prank(curator);
        vm.expectRevert(Errors.FailedCall.selector);
        factory.migrate(address(connector), 2, "");
        assertEq(connector.version(), 1);
        assertEq(connector.signer(), signer);
        assertEq(connector.minDiscount(address(rwa)), 5_000_000);
        assertTrue(connector.isUsedNonce(address(rwa), 7));
        (ILiquidLaneConnector.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 5_000_000), signerKey);
        vm.prank(address(account));
        connector.swap(request, protocolSignature, recipient, 100e18);
    }

    /// forge-config: default.isolate = true
    function test_DiscountSwapGas() public {
        (ILiquidLaneConnector.DiscountSwap memory request, bytes memory protocolSignature) =
            _sign(_request(signer, 5_000_000), signerKey);
        vm.prank(address(account));
        connector.swap(request, protocolSignature, recipient, 100e18);
        vm.snapshotGasLastCall("LiquidLaneConnector", "swapDiscount");
        assertEq(asset.balanceOf(recipient), 190e6);
        assertEq(rwa.balanceOf(address(account)), 100e18);
        assertEq(connector.remainingAssets(address(rwa)), 810e6);
    }

    function _request(address discountSigner, uint256 discount)
        internal
        view
        returns (ILiquidLaneConnector.DiscountSwap memory)
    {
        return ILiquidLaneConnector.DiscountSwap({
            discount: ILiquidLaneConnector.Discount({
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

    function _sign(ILiquidLaneConnector.DiscountSwap memory request, uint256 privateKey)
        internal
        view
        returns (ILiquidLaneConnector.DiscountSwap memory, bytes memory)
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
        ILiquidLaneConnector.DiscountSwap memory request,
        bytes memory protocolSignature,
        bytes4 errorSelector
    ) internal {
        vm.prank(address(account));
        vm.expectRevert(errorSelector);
        connector.swap(request, protocolSignature, recipient, 100e18);
        assertEq(asset.balanceOf(recipient), 0);
        assertEq(rwa.balanceOf(address(account)), 0);
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
