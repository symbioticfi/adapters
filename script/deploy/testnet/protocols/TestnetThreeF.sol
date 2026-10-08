// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IThreeFFacility} from "src/interfaces/3f-adapter/IThreeFAdapterDependencies.sol";
import {IThreeFRequestCallback} from "src/interfaces/3f-adapter/IThreeFRequestCallback.sol";
import {IThreeFWhitelist} from "src/interfaces/3f-adapter/IThreeFWhitelist.sol";
import {Offer} from "src/interfaces/3f-adapter/ThreeFTypes.sol";

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title TestnetThreeFRequest
/// @notice Authenticated push/callback funding and a maturity-gated principal/yield payout waterfall.
contract TestnetThreeFRequest is Ownable, EIP712 {
    using SafeERC20 for IERC20;
    using Math for uint256;
    error InvalidOffer();
    error NotReady();
    address public immutable asset;
    uint48 public immutable maturity;
    string public name;
    uint256 public ptSupply;
    uint256 public ytSupply;
    mapping(address account => uint256 amount) public ptBalance;
    mapping(address account => uint256 amount) public ytBalance;
    mapping(address account => uint256 value) public nonce;

    struct Authorization {
        uint128 principal;
        uint128 yieldAssets;
    }
    mapping(address account => Authorization value) public mintAuthorization;
    bytes32 public constant OFFER_TYPEHASH = keccak256(
        "Offer(address maker,uint256 amount,uint256 expectedReturn,uint256 nonce,uint256 expiration,bool useCallback)"
    );
    event AuthorizeMinting(address indexed account, uint128 principal, uint128 yieldAssets);
    event Mint(address indexed account, uint256 principal, uint256 yieldAssets);
    event BurnAll(address indexed account, address indexed receiver, uint256 principal, uint256 yieldAssets);
    event SetNonce(address indexed account, uint256 nonce);

    constructor(address newOwner, address newAsset, uint48 newMaturity, uint256 intentId)
        Ownable(newOwner)
        EIP712("TestnetThreeFRequest", "1")
    {
        asset = newAsset;
        maturity = newMaturity;
        name = string.concat("request-", Strings.toString(intentId));
    }

    function canWithdraw() public view returns (bool) {
        return block.timestamp >= maturity;
    }

    function setNonce(uint256 newNonce) public {
        if (newNonce <= nonce[msg.sender]) revert InvalidOffer();
        nonce[msg.sender] = newNonce;
        emit SetNonce(msg.sender, newNonce);
    }

    function authorizeMinting(address account, uint128 principal, uint128 yieldAssets) public onlyOwner {
        if (canWithdraw()) revert InvalidOffer();
        mintAuthorization[account] = Authorization({principal: principal, yieldAssets: yieldAssets});
        emit AuthorizeMinting(account, principal, yieldAssets);
    }

    function mint(uint128 maxPrincipal, uint128 minYield) public {
        Authorization memory auth = mintAuthorization[msg.sender];
        if (auth.principal == 0 && auth.yieldAssets == 0) return;
        if (canWithdraw() || auth.principal > maxPrincipal || auth.yieldAssets < minYield) revert InvalidOffer();
        delete mintAuthorization[msg.sender];
        IERC20(asset).safeTransferFrom(msg.sender, address(this), auth.principal);
        _mintShares(msg.sender, auth.principal, auth.yieldAssets);
    }

    function offerDigest(Offer calldata offer) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    OFFER_TYPEHASH,
                    offer.maker,
                    offer.amount,
                    offer.expectedReturn,
                    offer.nonce,
                    offer.expiration,
                    offer.useCallback
                )
            )
        );
    }

    function consume(Offer calldata offer, bytes calldata signature) public {
        if (
            canWithdraw() || offer.expiration < block.timestamp || offer.nonce != nonce[offer.maker]
                || !SignatureChecker.isValidSignatureNowCalldata(offer.maker, offerDigest(offer), signature)
        ) revert InvalidOffer();
        ++nonce[offer.maker];
        if (offer.useCallback) {
            IThreeFRequestCallback(offer.maker).onRequestConsumed(offer, signature, offer.amount, offer.expectedReturn);
        }
        IERC20(asset).safeTransferFrom(offer.maker, address(this), offer.amount);
        _mintShares(offer.maker, offer.amount, offer.expectedReturn);
    }

    /// @notice Funds fixture yield and consumes a signed native offer atomically.
    function fundAndConsume(Offer calldata offer, bytes calldata signature) public onlyOwner {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), offer.expectedReturn);
        consume(offer, signature);
    }

    function balancesOf(address account) public view returns (uint256, uint256) {
        return (ptBalance[account], ytBalance[account]);
    }

    function convertToAssets(uint256 ptShares, uint256 ytShares)
        public
        view
        returns (uint256 principal, uint256 yieldAssets)
    {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 principalBacking = Math.min(balance, ptSupply);
        if (ptSupply > 0) principal = principalBacking.mulDiv(ptShares, ptSupply);
        if (ytSupply > 0) yieldAssets = (balance - principalBacking).mulDiv(ytShares, ytSupply);
    }

    function burnAll(address account, address receiver)
        public
        returns (uint256 pt, uint256 yt, uint256 principal, uint256 yieldAssets)
    {
        if (account != msg.sender || !canWithdraw()) revert NotReady();
        pt = ptBalance[account];
        yt = ytBalance[account];
        (principal, yieldAssets) = convertToAssets(pt, yt);
        delete ptBalance[account];
        delete ytBalance[account];
        ptSupply -= pt;
        ytSupply -= yt;
        IERC20(asset).safeTransfer(receiver, principal + yieldAssets);
        emit BurnAll(account, receiver, principal, yieldAssets);
    }

    function _mintShares(address account, uint256 principal, uint256 yieldAssets) internal {
        ptBalance[account] += principal;
        ytBalance[account] += yieldAssets;
        ptSupply += principal;
        ytSupply += yieldAssets;
        emit Mint(account, principal, yieldAssets);
    }
}

/// @title TestnetThreeFFacility
/// @notice Native request registry, whitelist and intent metadata consumed by the real adapter and policy.
contract TestnetThreeFFacility is Ownable {
    mapping(address request => bool registered) public isRequest;
    mapping(uint256 id => address request) public requests;
    address public immutable asset;
    address public immutable positionManager;
    uint256 public intents;
    event CreateRequest(uint256 indexed id, address indexed request);

    constructor(address newOwner, address newAsset, address newCollateral) Ownable(newOwner) {
        asset = newAsset;
        positionManager = address(new TestnetThreeFPositionManager(newCollateral, newAsset));
    }

    function createRequest(uint48 maturity) public onlyOwner returns (address request) {
        uint256 id = ++intents;
        request = address(new TestnetThreeFRequest(owner(), asset, maturity, id));
        isRequest[request] = true;
        requests[id] = request;
        emit CreateRequest(id, request);
    }

    function isWhitelisted(address request) public view returns (IThreeFWhitelist.WhitelistStatus) {
        return isRequest[request]
            ? IThreeFWhitelist.WhitelistStatus.Whitelisted
            : IThreeFWhitelist.WhitelistStatus.NotWhitelisted;
    }

    function getIntent(uint256 id)
        public
        view
        returns (IThreeFFacility.IntentProperties memory properties, address fund, address request, bool resolved)
    {
        request = requests[id];
        properties = IThreeFFacility.IntentProperties({
            depositAsset: IThreeFFacility.Asset({asset: asset, isPositionManager: false}),
            targetAsset: IThreeFFacility.Asset({asset: positionManager, isPositionManager: true}),
            depositCap: 10_000_000 * 10 ** IERC20Metadata(asset).decimals(),
            guardKey: owner(),
            resolveStart: 0,
            quorum: 1,
            transferableIntent: false
        });
        fund = owner();
        resolved = request != address(0) && TestnetThreeFRequest(request).canWithdraw();
    }
}

/// @title TestnetThreeFPositionManager
/// @notice Collateral and funding-token metadata for testnet intent risk resolution.
contract TestnetThreeFPositionManager {
    address public immutable collateral;
    address public immutable debt;

    constructor(address newCollateral, address newDebt) {
        collateral = address(new TestnetThreeFCollateral(newCollateral));
        debt = newDebt;
    }

    function assets() public view returns (address, address) {
        return (collateral, debt);
    }
}

/// @title TestnetThreeFCollateral
/// @notice Explicit underlying risk-asset metadata used by ThreeFPolicy.
contract TestnetThreeFCollateral {
    address public immutable underlying;

    constructor(address newUnderlying) {
        underlying = newUnderlying;
    }
}
