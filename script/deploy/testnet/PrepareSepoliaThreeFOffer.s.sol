// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {DeployRealisticTestnetScript} from "./DeployRealisticTestnet.s.sol";
import {SepoliaInfrastructure} from "./SepoliaInfrastructure.sol";
import {TestnetPhaseScript} from "./base/TestnetPhase.s.sol";

import {IThreeFAdapter} from "src/interfaces/IThreeFAdapter.sol";
import {
    IThreeFFacility,
    IThreeFPositionManager,
    IThreeFRequestName,
    IThreeFUnderlyingAsset
} from "src/interfaces/3f-adapter/IThreeFAdapterDependencies.sol";
import {IThreeFRequestFactory} from "src/interfaces/3f-adapter/IThreeFRequestFactory.sol";
import {IThreeFRequest} from "src/interfaces/3f-adapter/IThreeFRequest.sol";
import {IThreeFWhitelist} from "src/interfaces/3f-adapter/IThreeFWhitelist.sol";
import {Offer} from "src/interfaces/3f-adapter/ThreeFTypes.sol";
import {REQUEST_NAME_PREFIX_LENGTH} from "src/interfaces/merkle-adapter/automations/policies/IThreeFPolicy.sol";

import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title IThreeFOfferNonce
 * @notice Interface for the native request's last consumed offer nonce.
 */
interface IThreeFOfferNonce {
    /**
     * @notice Returns the last consumed nonce for a maker; a new offer must use a larger value.
     * @param maker Address funding the request and receiving PT and YT.
     * @return lastNonce Last successfully consumed offer nonce for the maker.
     */
    function nonce(address maker) external view returns (uint256 lastNonce);
}

/// @title PrepareSepoliaThreeFOfferScript
/// @notice Prepares an unsigned native 3F offer for an existing official Sepolia auction request.
/// @dev Reads live provenance and signing data, then writes a payload for an offchain keystore and API submission.
contract PrepareSepoliaThreeFOfferScript is TestnetPhaseScript {
    using Strings for uint256;

    /* CONSTANTS */

    bytes32 internal constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant _OFFER_TYPEHASH = keccak256(
        "Offer(address maker,uint256 amount,uint256 expectedReturn,uint256 nonce,uint256 expiration,bool useCallback)"
    );

    /* ERRORS */

    error AssetMismatch();

    error InvalidDomain();

    error InvalidInfrastructure();

    error InvalidMarket();

    error InvalidOffer();

    error InvalidRequest();

    error InvalidRequestName();

    error NonceExhausted();

    error NotWhitelisted();

    /* STRUCTS */

    /// @notice Native offer, signing domain, and the collateral risk asset used by ThreeFPolicy.
    struct PreparedOffer {
        address request;
        address asset;
        address riskAsset;
        string name;
        string version;
        Offer offer;
        bytes32 digest;
    }

    /* PUBLIC FUNCTIONS */

    /// @notice Loads the manifest, validates explicit offer terms, and writes the unsigned signing payload.
    function run() public returns (PreparedOffer memory prepared) {
        uint256 marketIndex = vm.envOr("TESTNET_THREE_F_MARKET", uint256(0));
        prepared = prepareOffer(
            load(),
            marketIndex,
            vm.envAddress("TESTNET_THREE_F_REQUEST"),
            vm.envUint("TESTNET_THREE_F_AMOUNT"),
            vm.envUint("TESTNET_THREE_F_EXPECTED_RETURN"),
            vm.envUint("TESTNET_THREE_F_EXPIRATION")
        );
        writeOffer(
            prepared,
            marketIndex,
            vm.envOr(
                "TESTNET_THREE_F_OFFER_OUTPUT", string("script/deploy/testnet/manifests/sepolia-threef-offer.json")
            )
        );
    }

    /// @notice Validates official request provenance and derives a fresh native Offer digest without execution.
    function prepareOffer(
        DeployRealisticTestnetScript.Deployment memory deployed,
        uint256 marketIndex,
        address request,
        uint256 amount,
        uint256 expectedReturn,
        uint256 expiration
    ) public view returns (PreparedOffer memory prepared) {
        if (block.chainid != SepoliaInfrastructure.CHAIN_ID) revert InvalidInfrastructure();
        if (deployed.chainId != block.chainid) revert InvalidInfrastructure();
        if (marketIndex >= deployed.markets.length) revert InvalidMarket();
        if (deployed.markets[marketIndex].threeF != SepoliaInfrastructure.FACILITY) revert InvalidInfrastructure();
        if (amount == 0 || expectedReturn == 0 || expiration < block.timestamp) revert InvalidOffer();
        if (
            request.code.length == 0
                || !IThreeFRequestFactory(SepoliaInfrastructure.REQUESTS_FACTORY).isRequest(request)
        ) revert InvalidRequest();
        if (
            IThreeFWhitelist(SepoliaInfrastructure.WHITELIST).isWhitelisted(request)
                != IThreeFWhitelist.WhitelistStatus.Whitelisted
        ) revert NotWhitelisted();
        if (
            deployed.markets[marketIndex].threeFAdapter.code.length == 0
                || IThreeFAdapter(deployed.markets[marketIndex].threeFAdapter).REQUEST_WHITELIST()
                    != SepoliaInfrastructure.WHITELIST
        ) revert InvalidMarket();
        if (IThreeFRequest(request).asset() != deployed.markets[marketIndex].asset) revert AssetMismatch();
        if (IThreeFRequest(request).canWithdraw()) revert InvalidRequest();

        prepared.request = request;
        prepared.asset = deployed.markets[marketIndex].asset;
        bytes1 fields;
        uint256 chainId;
        address verifyingContract;
        bytes32 salt;
        uint256[] memory extensions;
        (fields, prepared.name, prepared.version, chainId, verifyingContract, salt, extensions) =
            IERC5267(request).eip712Domain();
        if (
            fields != 0x0f || chainId != block.chainid || verifyingContract != request || salt != bytes32(0)
                || extensions.length > 0
                || keccak256(bytes(prepared.name)) != keccak256(bytes(IThreeFRequestName(request).name()))
        ) revert InvalidDomain();
        if (bytes(prepared.name).length <= REQUEST_NAME_PREFIX_LENGTH) revert InvalidRequestName();
        (IThreeFFacility.IntentProperties memory properties,, address intentRequest,) = IThreeFFacility(
                SepoliaInfrastructure.FACILITY
            )
            .getIntent(Strings.parseUint(prepared.name, REQUEST_NAME_PREFIX_LENGTH, bytes(prepared.name).length));
        if (intentRequest != request || !properties.targetAsset.isPositionManager) revert InvalidRequest();
        (address collateralAsset,) = IThreeFPositionManager(properties.targetAsset.asset).assets();
        prepared.riskAsset = IThreeFUnderlyingAsset(collateralAsset).underlying();
        if (prepared.riskAsset == address(0)) revert InvalidRequest();

        uint256 lastNonce = IThreeFOfferNonce(request).nonce(deployed.markets[marketIndex].threeFAdapter);
        if (lastNonce == type(uint256).max) revert NonceExhausted();
        prepared.offer = Offer({
            maker: deployed.markets[marketIndex].threeFAdapter,
            amount: amount,
            expectedReturn: expectedReturn,
            nonce: lastNonce + 1,
            expiration: expiration,
            useCallback: true
        });
        prepared.digest = keccak256(
            abi.encodePacked(
                hex"1901",
                keccak256(
                    abi.encode(
                        _DOMAIN_TYPEHASH,
                        keccak256(bytes(prepared.name)),
                        keccak256(bytes(prepared.version)),
                        chainId,
                        verifyingContract
                    )
                ),
                keccak256(abi.encode(_OFFER_TYPEHASH, prepared.offer))
            )
        );
    }

    /// @notice Writes exact decimal offer fields, their native signing domain, and the digest to a JSON file.
    function writeOffer(PreparedOffer memory prepared, uint256 marketIndex, string memory path) public {
        vm.serializeString("threef-domain", "name", prepared.name);
        vm.serializeString("threef-domain", "version", prepared.version);
        vm.serializeUint("threef-domain", "chainId", SepoliaInfrastructure.CHAIN_ID);
        string memory domain = vm.serializeAddress("threef-domain", "verifyingContract", prepared.request);
        vm.serializeAddress("threef-offer", "maker", prepared.offer.maker);
        vm.serializeString("threef-offer", "amount", prepared.offer.amount.toString());
        vm.serializeString("threef-offer", "expectedReturn", prepared.offer.expectedReturn.toString());
        vm.serializeString("threef-offer", "nonce", prepared.offer.nonce.toString());
        vm.serializeString("threef-offer", "expiration", prepared.offer.expiration.toString());
        string memory offer = vm.serializeBool("threef-offer", "useCallback", prepared.offer.useCallback);
        string memory typedData = string.concat(
            '{"domain":',
            domain,
            ',"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],"Offer":[{"name":"maker","type":"address"},{"name":"amount","type":"uint256"},{"name":"expectedReturn","type":"uint256"},{"name":"nonce","type":"uint256"},{"name":"expiration","type":"uint256"},{"name":"useCallback","type":"bool"}]},"primaryType":"Offer","message":',
            offer,
            "}"
        );
        vm.serializeJson(
            "threef-prepared", string.concat('{"domain":', domain, ',"offer":', offer, ',"typedData":', typedData, "}")
        );
        vm.serializeUint("threef-prepared", "schemaVersion", 1);
        vm.serializeUint("threef-prepared", "chainId", SepoliaInfrastructure.CHAIN_ID);
        vm.serializeUint("threef-prepared", "marketIndex", marketIndex);
        vm.serializeAddress("threef-prepared", "request", prepared.request);
        vm.serializeAddress("threef-prepared", "asset", prepared.asset);
        vm.serializeAddress("threef-prepared", "riskAsset", prepared.riskAsset);
        vm.writeJson(vm.serializeBytes32("threef-prepared", "digest", prepared.digest), path);
    }
}
