// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {IThreeFAdapter} from "src/interfaces/IThreeFAdapter.sol";
import {
    IThreeFFacility,
    IThreeFPositionManager,
    IThreeFRequestName,
    IThreeFUnderlyingAsset
} from "src/interfaces/3f-adapter/IThreeFAdapterDependencies.sol";
import {IThreeFRequestFactory} from "src/interfaces/3f-adapter/IThreeFRequestFactory.sol";
import {IThreeFRequest} from "src/interfaces/3f-adapter/IThreeFRequest.sol";
import {IThreeFVaultController} from "src/interfaces/3f-adapter/IThreeFVaultController.sol";
import {IThreeFWhitelist} from "src/interfaces/3f-adapter/IThreeFWhitelist.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Test} from "forge-std/Test.sol";

import {DeployRealisticTestnetScript} from "script/deploy/testnet/DeployRealisticTestnet.s.sol";
import {
    IThreeFOfferNonce,
    PrepareSepoliaThreeFOfferScript
} from "script/deploy/testnet/PrepareSepoliaThreeFOffer.s.sol";
import {SepoliaInfrastructure} from "script/deploy/testnet/SepoliaInfrastructure.sol";

/// @title SepoliaThreeFOfferTest
/// @notice Tests native official-request validation and independently checks the unsigned signing payload.
contract SepoliaThreeFOfferTest is Test {
    /* STATE VARIABLES */

    address internal _preparer;
    address internal _request = address(0x1001);
    address internal _maker = address(0x1002);
    address internal _positionManager = address(0x1003);
    address internal _collateral = address(0x1004);
    address internal _riskAsset = address(0x1005);
    DeployRealisticTestnetScript.Deployment internal _deployed;

    /* PUBLIC FUNCTIONS */

    function setUp() public {
        vm.chainId(SepoliaInfrastructure.CHAIN_ID);
        vm.warp(1_000_000);
        _preparer = address(new PrepareSepoliaThreeFOfferScript());
        vm.etch(_request, hex"00");
        vm.etch(_maker, hex"00");
        vm.etch(_positionManager, hex"00");
        vm.etch(_collateral, hex"00");
        vm.etch(SepoliaInfrastructure.REQUESTS_FACTORY, hex"00");
        vm.etch(SepoliaInfrastructure.FACILITY, hex"00");
        vm.etch(SepoliaInfrastructure.WHITELIST, hex"00");
        _deployed.chainId = SepoliaInfrastructure.CHAIN_ID;
        _deployed.markets = new DeployRealisticTestnetScript.Market[](1);
        _deployed.markets[0].threeF = SepoliaInfrastructure.FACILITY;
        _deployed.markets[0].asset = SepoliaInfrastructure.USDC;
        _deployed.markets[0].threeFAdapter = _maker;
        vm.mockCall(
            SepoliaInfrastructure.REQUESTS_FACTORY,
            abi.encodeCall(IThreeFRequestFactory.isRequest, (_request)),
            abi.encode(true)
        );
        vm.mockCall(
            SepoliaInfrastructure.WHITELIST,
            abi.encodeCall(IThreeFWhitelist.isWhitelisted, (_request)),
            abi.encode(IThreeFWhitelist.WhitelistStatus.Whitelisted)
        );
        vm.mockCall(
            _maker, abi.encodeCall(IThreeFAdapter.REQUEST_WHITELIST, ()), abi.encode(SepoliaInfrastructure.WHITELIST)
        );
        vm.mockCall(_request, abi.encodeCall(IThreeFRequest.asset, ()), abi.encode(SepoliaInfrastructure.USDC));
        vm.mockCall(_request, abi.encodeCall(IThreeFVaultController.canWithdraw, ()), abi.encode(false));
        vm.mockCall(_request, abi.encodeCall(IThreeFRequestName.name, ()), abi.encode("request-16393"));
        vm.mockCall(_request, abi.encodeCall(IThreeFOfferNonce.nonce, (_maker)), abi.encode(uint256(7)));
        _mockDomain(0x0f, SepoliaInfrastructure.CHAIN_ID, _request);
        _mockIntent(_request, true);
        vm.mockCall(
            _positionManager,
            abi.encodeCall(IThreeFPositionManager.assets, ()),
            abi.encode(_collateral, SepoliaInfrastructure.USDC)
        );
        vm.mockCall(_collateral, abi.encodeCall(IThreeFUnderlyingAsset.underlying, ()), abi.encode(_riskAsset));
    }

    function test_IndependentEIP712DigestAndEOASignature() public view {
        PrepareSepoliaThreeFOfferScript.PreparedOffer memory prepared = _prepare();
        assertEq(prepared.riskAsset, _riskAsset);
        assertEq(prepared.asset, SepoliaInfrastructure.USDC);
        assertEq(prepared.offer.maker, _maker);
        assertEq(prepared.offer.nonce, 8);
        assertTrue(prepared.offer.useCallback);
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("request-16393"),
                keccak256("0.0.1"),
                uint256(11_155_111),
                _request
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Offer(address maker,uint256 amount,uint256 expectedReturn,uint256 nonce,uint256 expiration,bool useCallback)"
                ),
                _maker,
                uint256(100e6),
                uint256(300_000),
                uint256(8),
                block.timestamp + 1 hours,
                true
            )
        );
        assertEq(prepared.digest, keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x1234, prepared.digest);
        assertEq(ECDSA.recover(prepared.digest, abi.encodePacked(r, s, v)), vm.addr(0x1234));
    }

    function testFuzz_FreshNonceAndExactPrincipal(uint256 lastNonce, uint256 amount) public {
        lastNonce = bound(lastNonce, 0, type(uint256).max - 1);
        amount = bound(amount, 1, type(uint256).max);
        vm.mockCall(_request, abi.encodeCall(IThreeFOfferNonce.nonce, (_maker)), abi.encode(lastNonce));
        PrepareSepoliaThreeFOfferScript.PreparedOffer memory prepared =
            PrepareSepoliaThreeFOfferScript(_preparer).prepareOffer(_deployed, 0, _request, amount, 1, block.timestamp);
        assertEq(prepared.offer.nonce, lastNonce + 1);
        assertEq(prepared.offer.amount, amount);
        assertEq(prepared.offer.expiration, block.timestamp);
    }

    function testFuzz_PreparesRegisteredRequestsWithAnyEightBytePrefix(bytes8 prefix) public {
        string memory name = string(abi.encodePacked(prefix, "16393"));
        vm.mockCall(_request, abi.encodeCall(IThreeFRequestName.name, ()), abi.encode(name));
        vm.mockCall(
            _request,
            abi.encodeCall(IERC5267.eip712Domain, ()),
            abi.encode(bytes1(0x0f), name, "0.0.1", block.chainid, _request, bytes32(0), new uint256[](0))
        );
        PrepareSepoliaThreeFOfferScript.PreparedOffer memory prepared = _prepare();
        assertEq(prepared.name, name);
        assertEq(prepared.riskAsset, _riskAsset);
        assertEq(prepared.offer.maker, _maker);
    }

    function test_RejectsMissingIntentTail() public {
        vm.mockCall(_request, abi.encodeCall(IThreeFRequestName.name, ()), abi.encode("request-"));
        vm.mockCall(
            _request,
            abi.encodeCall(IERC5267.eip712Domain, ()),
            abi.encode(bytes1(0x0f), "request-", "0.0.1", block.chainid, _request, bytes32(0), new uint256[](0))
        );
        vm.expectRevert(PrepareSepoliaThreeFOfferScript.InvalidRequestName.selector);
        _prepare();
    }

    function test_ExhaustedNonceRequiresNewRequest() public {
        vm.mockCall(_request, abi.encodeCall(IThreeFOfferNonce.nonce, (_maker)), abi.encode(type(uint256).max));
        vm.expectRevert(PrepareSepoliaThreeFOfferScript.NonceExhausted.selector);
        _prepare();
    }

    function test_RejectsUnregisteredRequest() public {
        vm.mockCall(
            SepoliaInfrastructure.REQUESTS_FACTORY,
            abi.encodeCall(IThreeFRequestFactory.isRequest, (_request)),
            abi.encode(false)
        );
        vm.expectRevert(PrepareSepoliaThreeFOfferScript.InvalidRequest.selector);
        _prepare();
    }

    function testFuzz_RejectsUnlistedAndPausedRequests(uint8 status) public {
        status = uint8(bound(status, 0, 2));
        if (status > 0) status += 1;
        vm.mockCall(
            SepoliaInfrastructure.WHITELIST,
            abi.encodeCall(IThreeFWhitelist.isWhitelisted, (_request)),
            abi.encode(status)
        );
        vm.expectRevert(PrepareSepoliaThreeFOfferScript.NotWhitelisted.selector);
        _prepare();
    }

    function test_RejectsAssetMismatchAndClosedRequest() public {
        vm.mockCall(_request, abi.encodeCall(IThreeFRequest.asset, ()), abi.encode(address(0xBAD)));
        vm.expectRevert(PrepareSepoliaThreeFOfferScript.AssetMismatch.selector);
        _prepare();
        vm.mockCall(_request, abi.encodeCall(IThreeFRequest.asset, ()), abi.encode(SepoliaInfrastructure.USDC));
        vm.mockCall(_request, abi.encodeCall(IThreeFVaultController.canWithdraw, ()), abi.encode(true));
        vm.expectRevert(PrepareSepoliaThreeFOfferScript.InvalidRequest.selector);
        _prepare();
    }

    function test_RejectsForeignInfrastructureAndWrongChain() public {
        _deployed.markets[0].threeF = address(0xBAD);
        vm.expectRevert(PrepareSepoliaThreeFOfferScript.InvalidInfrastructure.selector);
        _prepare();
        _deployed.markets[0].threeF = SepoliaInfrastructure.FACILITY;
        vm.chainId(1);
        vm.expectRevert(PrepareSepoliaThreeFOfferScript.InvalidInfrastructure.selector);
        _prepare();
    }

    function test_RejectsMissingMarketAndForeignAdapterWhitelist() public {
        vm.expectRevert(PrepareSepoliaThreeFOfferScript.InvalidMarket.selector);
        PrepareSepoliaThreeFOfferScript(_preparer)
            .prepareOffer(_deployed, 1, _request, 100e6, 300_000, block.timestamp + 1 hours);
        vm.mockCall(_maker, abi.encodeCall(IThreeFAdapter.REQUEST_WHITELIST, ()), abi.encode(address(0xBAD)));
        vm.expectRevert(PrepareSepoliaThreeFOfferScript.InvalidMarket.selector);
        _prepare();
    }

    function test_RejectsDomainSaltFieldChainAndVerifierMismatch() public {
        _mockDomain(0x1f, SepoliaInfrastructure.CHAIN_ID, _request);
        vm.expectRevert(PrepareSepoliaThreeFOfferScript.InvalidDomain.selector);
        _prepare();
        _mockDomain(0x0f, 1, _request);
        vm.expectRevert(PrepareSepoliaThreeFOfferScript.InvalidDomain.selector);
        _prepare();
        _mockDomain(0x0f, SepoliaInfrastructure.CHAIN_ID, address(0xBAD));
        vm.expectRevert(PrepareSepoliaThreeFOfferScript.InvalidDomain.selector);
        _prepare();
    }

    function test_RejectsDomainMetadataMismatch() public {
        vm.mockCall(_request, abi.encodeCall(IThreeFRequestName.name, ()), abi.encode("request-1"));
        vm.expectRevert(PrepareSepoliaThreeFOfferScript.InvalidDomain.selector);
        _prepare();
    }

    function test_RejectsWrongIntentAndUnsupportedCollateral() public {
        _mockIntent(address(0xBAD), true);
        vm.expectRevert(PrepareSepoliaThreeFOfferScript.InvalidRequest.selector);
        _prepare();
        _mockIntent(_request, false);
        vm.expectRevert(PrepareSepoliaThreeFOfferScript.InvalidRequest.selector);
        _prepare();
        _mockIntent(_request, true);
        vm.mockCall(_collateral, abi.encodeCall(IThreeFUnderlyingAsset.underlying, ()), abi.encode(address(0)));
        vm.expectRevert(PrepareSepoliaThreeFOfferScript.InvalidRequest.selector);
        _prepare();
    }

    function test_RejectsExpiredAndZeroTerms() public {
        vm.expectRevert(PrepareSepoliaThreeFOfferScript.InvalidOffer.selector);
        PrepareSepoliaThreeFOfferScript(_preparer)
            .prepareOffer(_deployed, 0, _request, 100e6, 300_000, block.timestamp - 1);
        vm.expectRevert(PrepareSepoliaThreeFOfferScript.InvalidOffer.selector);
        PrepareSepoliaThreeFOfferScript(_preparer).prepareOffer(_deployed, 0, _request, 0, 300_000, block.timestamp);
        vm.expectRevert(PrepareSepoliaThreeFOfferScript.InvalidOffer.selector);
        PrepareSepoliaThreeFOfferScript(_preparer).prepareOffer(_deployed, 0, _request, 100e6, 0, block.timestamp);
    }

    function test_JSONPreservesLargeIntegersAndSigningDomain() public {
        PrepareSepoliaThreeFOfferScript.PreparedOffer memory prepared = PrepareSepoliaThreeFOfferScript(_preparer)
            .prepareOffer(_deployed, 0, _request, (uint256(1) << 200) + 37, 300_000, block.timestamp + 1 hours);
        PrepareSepoliaThreeFOfferScript(_preparer)
            .writeOffer(prepared, 0, "script/deploy/testnet/manifests/sepolia-threef-offer-unit-test.json");
        string memory json = vm.readFile("script/deploy/testnet/manifests/sepolia-threef-offer-unit-test.json");
        assertEq(vm.parseJsonBytes32(json, ".digest"), prepared.digest);
        assertEq(vm.parseJsonAddress(json, ".riskAsset"), _riskAsset);
        assertEq(vm.parseJsonString(json, ".offer.amount"), Strings.toString(prepared.offer.amount));
        assertEq(vm.parseJsonString(json, ".offer.nonce"), "8");
        assertEq(vm.parseJsonString(json, ".typedData.message.amount"), Strings.toString(prepared.offer.amount));
        assertEq(vm.parseJsonString(json, ".typedData.primaryType"), "Offer");
        assertEq(vm.parseJsonAddress(json, ".typedData.domain.verifyingContract"), _request);
        assertEq(vm.parseJsonUint(json, ".typedData.domain.chainId"), 11_155_111);
        assertEq(vm.parseJsonString(json, ".typedData.types.Offer[3].name"), "nonce");
        assertFalse(vm.keyExistsJson(json, ".domain.salt"));
        assertTrue(vm.parseJsonBool(json, ".offer.useCallback"));
        vm.removeFile("script/deploy/testnet/manifests/sepolia-threef-offer-unit-test.json");
    }

    /* INTERNAL FUNCTIONS */

    function _prepare() internal view returns (PrepareSepoliaThreeFOfferScript.PreparedOffer memory) {
        return PrepareSepoliaThreeFOfferScript(_preparer)
            .prepareOffer(_deployed, 0, _request, 100e6, 300_000, block.timestamp + 1 hours);
    }

    function _mockDomain(bytes1 fields, uint256 chainId, address verifyingContract) internal {
        vm.mockCall(
            _request,
            abi.encodeCall(IERC5267.eip712Domain, ()),
            abi.encode(fields, "request-16393", "0.0.1", chainId, verifyingContract, bytes32(0), new uint256[](0))
        );
    }

    function _mockIntent(address request, bool isPositionManager) internal {
        vm.mockCall(
            SepoliaInfrastructure.FACILITY,
            abi.encodeCall(IThreeFFacility.getIntent, (16_393)),
            abi.encode(
                IThreeFFacility.IntentProperties({
                    depositAsset: IThreeFFacility.Asset({asset: SepoliaInfrastructure.USDC, isPositionManager: false}),
                    targetAsset: IThreeFFacility.Asset({asset: _positionManager, isPositionManager: isPositionManager}),
                    depositCap: 1000e6,
                    guardKey: _positionManager,
                    resolveStart: uint40(block.timestamp),
                    quorum: 1,
                    transferableIntent: true
                }),
                address(0),
                request,
                false
            )
        );
    }
}
