// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {AcredSecuritizeAccount, SecuritizeAccount} from "src/contracts/ll-adapter/SecuritizeAccount.sol";
import {AssetoAccount} from "src/contracts/ll-adapter/AssetoAccount.sol";
import {AssetoOracle} from "src/contracts/ll-adapter/oracles/AssetoOracle.sol";
import {ChainlinkOracle} from "src/contracts/ll-adapter/oracles/ChainlinkOracle.sol";
import {CutoffAccount} from "src/contracts/ll-adapter/common/CutoffAccount.sol";
import {DigiFTAccount} from "src/contracts/ll-adapter/DigiFTAccount.sol";
import {OpenEdenAccount} from "src/contracts/ll-adapter/OpenEdenAccount.sol";
import {OpenEdenOracle} from "src/contracts/ll-adapter/oracles/OpenEdenOracle.sol";
import {SecuritizeNoticeAccount} from "src/contracts/ll-adapter/SecuritizeNoticeAccount.sol";
import {SecuritizeOffRampAccount} from "src/contracts/ll-adapter/SecuritizeOffRampAccount.sol";
import {SpikoAccount} from "src/contracts/ll-adapter/SpikoAccount.sol";
import {SuperstateAccount} from "src/contracts/ll-adapter/SuperstateAccount.sol";
import {TestnetPriceFeed, TestnetToken} from "./TestnetAssets.sol";

import {IAssetoAccount} from "src/interfaces/ll-adapter/asseto/IAssetoAccount.sol";
import {IAssetoManager} from "src/interfaces/ll-adapter/asseto/IAssetoManager.sol";
import {IAssetoPricer} from "src/interfaces/ll-adapter/asseto/IAssetoPricer.sol";
import {ICutoffAccount} from "src/interfaces/ll-adapter/ICutoffAccount.sol";
import {IDigiFTSubRedManagement} from "src/interfaces/ll-adapter/digift/IDigiFTSubRedManagement.sol";
import {IOpenEdenExpress} from "src/interfaces/ll-adapter/openeden/IOpenEdenExpress.sol";
import {IPriceDataOracle} from "src/interfaces/ll-adapter/IPriceDataOracle.sol";
import {ISecuritizeAccount} from "src/interfaces/ll-adapter/securitize/ISecuritizeAccount.sol";
import {
    ISecuritizeLiquidityProvider,
    ISecuritizeOffRamp
} from "src/interfaces/ll-adapter/securitize/ISecuritizeOffRamp.sol";
import {ISpikoRedemption} from "src/interfaces/ll-adapter/spiko/ISpikoRedemption.sol";
import {ISuperstateToken} from "src/interfaces/ll-adapter/superstate/ISuperstateToken.sol";

import {IERC1363Receiver} from "@openzeppelin/contracts/interfaces/IERC1363Receiver.sol";
import {IERC1363Spender} from "@openzeppelin/contracts/interfaces/IERC1363Spender.sol";
import {IERC1363} from "@openzeppelin/contracts/interfaces/IERC1363.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Script} from "forge-std/Script.sol";

/**
 * @title ITestnetProviderIssuer
 * @notice Interface for issuer-controlled, funded settlement of recorded native redemption requests.
 */
interface ITestnetProviderIssuer {
    /* ERRORS */

    /**
     * @notice Raised when the caller is not the configured share token.
     */
    error InvalidCaller();

    /**
     * @notice Raised when a request is invalid, already settled, or settled above its quote.
     */
    error InvalidRequest();

    /**
     * @notice Raised when the requested redemption route is unavailable.
     */
    error InvalidRoute();

    /**
     * @notice Raised when the issuer settlement date or fresh valuation has not arrived.
     */
    error NotReady();

    /* EVENTS */

    /**
     * @notice Emitted when native custody or burning creates an issuer redemption request.
     */
    event Request(uint256 indexed id, address indexed receiver, uint256 tokenAmount, uint48 readyAt);
    /**
     * @notice Emitted when a funded payout closes a request, including a deliberately short payout.
     */
    event Settle(uint256 indexed id, address indexed receiver, uint256 payout, uint256 quotedAssets);

    /* FUNCTIONS */

    /**
     * @notice Records a Securitize share transfer to the redemption wallet.
     */
    function onReceipt(address receiver, uint256 amount) external;
    /**
     * @notice Records shares burned through the Superstate token's native redemption ABI.
     */
    function onBurn(address receiver, uint256 amount) external;
    /**
     * @notice Transfers a pre-funded payout to the recorded receiver and closes the request.
     */
    function settle(uint256 id, uint256 payout) external;
}

/// @title TestnetAssetoPricer
/// @notice Admin-published Asseto price-id history with the native pricer ABI and explicit freshness.
contract TestnetAssetoPricer is TestnetPriceFeed, IAssetoPricer {
    /* CONSTRUCTOR */

    constructor(address newOwner, int256 price) TestnetPriceFeed(newOwner, "Testnet Asseto NAV", 18, 30 hours, price) {}

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IAssetoPricer
    function latestPriceId() public view returns (uint256) {
        return latestRound;
    }

    /// @inheritdoc IAssetoPricer
    function prices(uint256 id) public view returns (uint256 price, uint256 timestamp) {
        if (id > type(uint80).max) revert InvalidPrice();
        (, int256 answer,, uint256 updatedAt,) = getRoundData(uint80(id));
        return (uint256(answer), updatedAt);
    }

    /// @inheritdoc IAssetoPricer
    function getLatestPrice() public view returns (uint256) {
        return getDataInBase18();
    }
}

/// @title TestnetNoticeToken
/// @notice Share token whose transfer to the issuer wallet records an off-chain redemption notice.
contract TestnetNoticeToken is TestnetToken {
    /* STATE VARIABLES */

    address public endpoint;

    /* CONSTRUCTOR */

    constructor(string memory newName, string memory newSymbol, uint8 newDecimals, address newOwner)
        TestnetToken(newName, newSymbol, newDecimals, newOwner)
    {}

    /* PUBLIC FUNCTIONS */

    /// @notice Binds the native redemption wallet once.
    function setEndpoint(address newEndpoint) public onlyOwner {
        if (endpoint != address(0) || newEndpoint == address(0)) revert ITestnetProviderIssuer.InvalidRoute();
        endpoint = newEndpoint;
    }

    /// @inheritdoc IERC20
    function transfer(address to, uint256 value) public override returns (bool) {
        super.transfer(to, value);
        if (to == endpoint && value > 0) ITestnetProviderIssuer(endpoint).onReceipt(msg.sender, value);
        return true;
    }

    /// @inheritdoc IERC20
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        super.transferFrom(from, to, value);
        if (to == endpoint && value > 0) ITestnetProviderIssuer(endpoint).onReceipt(from, value);
        return true;
    }
}

/// @title TestnetSuperstateToken
/// @notice Admin-issued USCC shares supporting the native burn-and-notice redemption ABI.
contract TestnetSuperstateToken is TestnetToken, ISuperstateToken {
    /* STATE VARIABLES */

    address public endpoint;

    /* CONSTRUCTOR */

    constructor(address newOwner) TestnetToken("Testnet Superstate Crypto Carry", "USCC", 6, newOwner) {}

    /* PUBLIC FUNCTIONS */

    /// @notice Binds the funded issuer once.
    function setEndpoint(address newEndpoint) public onlyOwner {
        if (endpoint != address(0) || newEndpoint == address(0)) revert ITestnetProviderIssuer.InvalidRoute();
        endpoint = newEndpoint;
    }

    /// @inheritdoc ISuperstateToken
    function offchainRedeem(uint256 amount) public {
        if (endpoint == address(0) || amount == 0) revert ITestnetProviderIssuer.InvalidRequest();
        _burn(msg.sender, amount);
        ITestnetProviderIssuer(endpoint).onBurn(msg.sender, amount);
    }
}

/// @title TestnetSpikoToken
/// @notice Admin-issued five-decimal SPKCC shares with ERC-1363 callbacks and investor restrictions.
contract TestnetSpikoToken is TestnetToken, IERC1363 {
    /* CONSTRUCTOR */

    constructor(address newOwner) TestnetToken("Testnet Spiko US T-Bills", "SPKCC", 5, newOwner) {}

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 id) public pure returns (bool) {
        return id == type(IERC165).interfaceId || id == type(IERC1363).interfaceId;
    }

    /// @inheritdoc IERC1363
    function transferAndCall(address to, uint256 value) public returns (bool) {
        return transferAndCall(to, value, "");
    }

    /// @inheritdoc IERC1363
    function transferAndCall(address to, uint256 value, bytes memory data) public returns (bool) {
        transfer(to, value);
        if (
            IERC1363Receiver(to).onTransferReceived(msg.sender, msg.sender, value, data)
                != IERC1363Receiver.onTransferReceived.selector
        ) revert ITestnetProviderIssuer.InvalidRoute();
        return true;
    }

    /// @inheritdoc IERC1363
    function transferFromAndCall(address from, address to, uint256 value) public returns (bool) {
        return transferFromAndCall(from, to, value, "");
    }

    /// @inheritdoc IERC1363
    function transferFromAndCall(address from, address to, uint256 value, bytes memory data) public returns (bool) {
        transferFrom(from, to, value);
        if (
            IERC1363Receiver(to).onTransferReceived(msg.sender, from, value, data)
                != IERC1363Receiver.onTransferReceived.selector
        ) revert ITestnetProviderIssuer.InvalidRoute();
        return true;
    }

    /// @inheritdoc IERC1363
    function approveAndCall(address spender, uint256 value) public returns (bool) {
        return approveAndCall(spender, value, "");
    }

    /// @inheritdoc IERC1363
    function approveAndCall(address spender, uint256 value, bytes memory data) public returns (bool) {
        approve(spender, value);
        if (
            IERC1363Spender(spender).onApprovalReceived(msg.sender, value, data)
                != IERC1363Spender.onApprovalReceived.selector
        ) revert ITestnetProviderIssuer.InvalidRoute();
        return true;
    }
}

/// @title TestnetProviderIssuer
/// @notice Funded issuer wallet and native Asseto/DigiFT manager for asynchronous redemption requests.
/// @dev Transfers for notice profiles remain in custody until final settlement. Other profiles burn
/// shares during the native request. Short payouts exercise the production accounts' expiry/write-off paths.
contract TestnetProviderIssuer is Ownable, ITestnetProviderIssuer, IAssetoManager, IDigiFTSubRedManagement {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /* IMMUTABLES */

    address public immutable token;
    address public immutable asset;
    address public immutable oracle;
    uint8 public immutable profile;

    /* STATE VARIABLES */

    /// @dev One native issuer notice; quote zero means it awaits a post-cutoff valuation.
    struct RequestData {
        address receiver;
        uint256 tokenAmount;
        uint256 quotedAssets;
        uint48 readyAt;
        bool closed;
    }

    uint256 public requestCount;
    mapping(uint256 id => RequestData data) public requests;

    /* CONSTRUCTOR */

    constructor(address newOwner, address newToken, address newAsset, address newOracle, uint8 newProfile)
        Ownable(newOwner)
    {
        token = newToken;
        asset = newAsset;
        oracle = newOracle;
        profile = newProfile;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ITestnetProviderIssuer
    function onReceipt(address receiver, uint256 amount) public {
        if (token != msg.sender) revert InvalidCaller();
        if (profile != 0 && profile != 1 && profile != 8) revert InvalidRoute();
        uint48 readyAt = uint48(block.timestamp) + 1 days;
        if (profile != 1) {
            readyAt = ICutoffAccount(receiver).bucketToTimestamp(ICutoffAccount(receiver).currentBucket()) + 4 days;
        }
        _record(receiver, amount, readyAt, profile != 1);
    }

    /// @inheritdoc ITestnetProviderIssuer
    function onBurn(address receiver, uint256 amount) public {
        if (token != msg.sender) revert InvalidCaller();
        if (profile != 3) revert InvalidRoute();
        _record(receiver, amount, uint48(block.timestamp) + 1 days, false);
    }

    /// @inheritdoc IDigiFTSubRedManagement
    function redeem(address stToken, address currencyToken, uint256 quantity, uint256 deadline) public {
        if (profile != 4 || stToken != token || currencyToken != asset) revert InvalidRoute();
        if (block.timestamp > deadline) revert InvalidRequest();
        IERC20(token).safeTransferFrom(msg.sender, address(this), quantity);
        TestnetToken(token).burn(quantity);
        _record(msg.sender, quantity, uint48(block.timestamp) + 1 days, false);
    }

    /// @inheritdoc IAssetoManager
    function rwa() public view returns (address) {
        return token;
    }

    /// @inheritdoc IAssetoManager
    function collateral() public view returns (address) {
        return asset;
    }

    /// @inheritdoc IAssetoManager
    function minimumRedemptionAmount() public pure returns (uint256) {
        return 1e18;
    }

    /// @inheritdoc IAssetoManager
    function maximumRedemptionAmount() public pure returns (uint256) {
        return 5000e18;
    }

    /// @inheritdoc IAssetoManager
    function redemptionRequestCounter() public view returns (uint256) {
        return requestCount;
    }

    /// @inheritdoc IAssetoManager
    function requestRedemptionServicedOffchain(uint256 amount, bytes32 destination) public {
        if (profile != 6) revert InvalidRoute();
        if (amount < minimumRedemptionAmount() || amount > maximumRedemptionAmount() || destination == bytes32(0)) {
            revert InvalidRequest();
        }
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        TestnetToken(token).burn(amount);
        _record(msg.sender, amount, uint48(block.timestamp) + 1 days, true);
    }

    /// @inheritdoc ITestnetProviderIssuer
    function settle(uint256 id, uint256 payout) public onlyOwner {
        RequestData storage request = requests[id];
        if (request.receiver == address(0) || request.closed) revert InvalidRequest();
        if (block.timestamp < request.readyAt) revert NotReady();
        if (request.quotedAssets == 0) {
            uint48 bucket = ICutoffAccount(request.receiver)
                .timestampToBucket(request.readyAt - (profile == 6 ? uint48(1 days) : uint48(4 days)));
            uint256 price;
            if (profile == 6) (,, price) = IAssetoAccount(request.receiver).buckets(bucket);
            else (,, price) = ISecuritizeAccount(request.receiver).buckets(bucket);
            if (price == 0) {
                uint48 updatedAt;
                (price, updatedAt) = IPriceDataOracle(oracle).getPriceData();
                if (updatedAt < request.readyAt) revert NotReady();
            }
            request.quotedAssets = request.tokenAmount
                .mulDiv(price * 10 ** IERC20Metadata(asset).decimals(), 1e18 * 10 ** IERC20Metadata(token).decimals());
        }
        if (payout > request.quotedAssets) revert InvalidRequest();
        request.closed = true;
        if (profile == 0 || profile == 1 || profile == 8) TestnetToken(token).burn(request.tokenAmount);
        if (payout > 0) IERC20(asset).safeTransfer(request.receiver, payout);
        emit Settle(id, request.receiver, payout, request.quotedAssets);
    }

    /* INTERNAL FUNCTIONS */

    function _record(address receiver, uint256 amount, uint48 readyAt, bool priceAtCutoff) internal {
        if (amount == 0 || receiver == address(0)) revert InvalidRequest();
        uint256 quote;
        if (!priceAtCutoff) {
            (uint256 price,) = IPriceDataOracle(oracle).getPriceData();
            quote = amount.mulDiv(
                price * 10 ** IERC20Metadata(asset).decimals(), 1e18 * 10 ** IERC20Metadata(token).decimals()
            );
        }
        uint256 id = requestCount++;
        requests[id] = RequestData({
            receiver: receiver, tokenAmount: amount, quotedAssets: quote, readyAt: readyAt, closed: false
        });
        emit Request(id, receiver, amount, readyAt);
    }
}

/// @title TestnetSecuritizeOffRamp
/// @notice Native Securitize quote/minimum ABI backed by a funded stablecoin liquidity reserve.
contract TestnetSecuritizeOffRamp is Ownable, ISecuritizeOffRamp, ISecuritizeLiquidityProvider {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /* IMMUTABLES */

    address public immutable assetAddress;
    address public immutable liquidityToken;
    address public immutable oracle;

    /* STATE VARIABLES */

    uint256 public feeBps;

    event Redeem(address indexed receiver, uint256 tokenAmount, uint256 payout);
    event SetFee(uint256 feeBps);

    /* CONSTRUCTOR */

    constructor(address newOwner, address newToken, address newAsset, address newOracle) Ownable(newOwner) {
        assetAddress = newToken;
        liquidityToken = newAsset;
        oracle = newOracle;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ISecuritizeOffRamp
    function liquidityProvider() public view returns (address) {
        return address(this);
    }

    /// @inheritdoc ISecuritizeOffRamp
    function calculateLiquidityTokenAmount(uint256 amount) public view returns (uint256) {
        (uint256 price,) = IPriceDataOracle(oracle).getPriceData();
        return amount.mulDiv(
                price * 10 ** IERC20Metadata(liquidityToken).decimals(),
                1e18 * 10 ** IERC20Metadata(assetAddress).decimals()
            )
            .mulDiv(10_000 - feeBps, 10_000);
    }

    /// @notice Sets the quote fee to exercise production oracle-floor and slippage protection.
    function setFee(uint256 newFeeBps) public onlyOwner {
        if (newFeeBps > 1000) revert ITestnetProviderIssuer.InvalidRequest();
        feeBps = newFeeBps;
        emit SetFee(newFeeBps);
    }

    /// @inheritdoc ISecuritizeOffRamp
    function redeem(uint256 amount, uint256 minimum) public {
        uint256 payout = calculateLiquidityTokenAmount(amount);
        if (amount == 0 || payout < minimum) revert ITestnetProviderIssuer.InvalidRequest();
        IERC20(assetAddress).safeTransferFrom(msg.sender, address(this), amount);
        TestnetToken(assetAddress).burn(amount);
        IERC20(liquidityToken).safeTransfer(msg.sender, payout);
        emit Redeem(msg.sender, amount, payout);
    }
}

/// @title TestnetSpikoRedemption
/// @notice ERC-1363 custody with issuer execution, funded payouts, and deadline-enforced native cancellation.
contract TestnetSpikoRedemption is Ownable, ISpikoRedemption, IERC1363Receiver {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /* IMMUTABLES */

    address public immutable token;
    address public immutable asset;
    address public immutable oracle;

    /* STATE VARIABLES */

    struct RequestData {
        address receiver;
        uint256 tokenAmount;
        uint256 quotedAssets;
        uint48 requestedAt;
        uint48 deadline;
        Status status;
    }

    mapping(bytes32 id => RequestData data) public requests;

    event Request(bytes32 indexed id, address indexed receiver, uint256 tokenAmount, uint48 deadline);
    event Settle(bytes32 indexed id, uint256 payout, uint256 quotedAssets);
    event CancelRedemption(bytes32 indexed id, uint256 tokenAmount);

    /* CONSTRUCTOR */

    constructor(address newOwner, address newToken, address newAsset, address newOracle) Ownable(newOwner) {
        token = newToken;
        asset = newAsset;
        oracle = newOracle;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ISpikoRedemption
    function outputsFor(address input) public view returns (address[] memory outputs) {
        outputs = new address[](input == token ? 1 : 0);
        if (input == token) outputs[0] = asset;
    }

    /// @inheritdoc ISpikoRedemption
    function minimum(address input) public view returns (uint256) {
        return input == token ? 1e5 : type(uint256).max;
    }

    /// @inheritdoc ISpikoRedemption
    function details(bytes32 id) public view returns (Status, uint48) {
        return (requests[id].status, requests[id].deadline);
    }

    /// @inheritdoc IERC1363Receiver
    function onTransferReceived(address, address from, uint256 value, bytes calldata data) public returns (bytes4) {
        if (token != msg.sender) revert ITestnetProviderIssuer.InvalidCaller();
        (address output, bytes32 salt) = abi.decode(data, (address, bytes32));
        if (output != asset || value < minimum(token)) revert ITestnetProviderIssuer.InvalidRoute();
        bytes32 id = keccak256(abi.encodePacked(from, token, output, value, salt));
        if (requests[id].status != Status.NULL) revert ITestnetProviderIssuer.InvalidRequest();
        (uint256 price,) = IPriceDataOracle(oracle).getPriceData();
        uint48 deadline = uint48(block.timestamp) + 1 days;
        requests[id] = RequestData({
            receiver: from,
            tokenAmount: value,
            quotedAssets: value.mulDiv(price * 10 ** IERC20Metadata(asset).decimals(), 1e23),
            requestedAt: uint48(block.timestamp),
            deadline: deadline,
            status: Status.PENDING
        });
        emit Request(id, from, value, deadline);
        return IERC1363Receiver.onTransferReceived.selector;
    }

    /// @notice Executes a pending request with an issuer-funded full or short payout.
    function settle(bytes32 id, uint256 payout) public onlyOwner {
        RequestData storage request = requests[id];
        if (request.status != Status.PENDING || payout > request.quotedAssets) {
            revert ITestnetProviderIssuer.InvalidRequest();
        }
        if (block.timestamp < request.requestedAt + 1 hours || block.timestamp >= request.deadline) {
            revert ITestnetProviderIssuer.NotReady();
        }
        request.status = Status.EXECUTED;
        TestnetToken(token).burn(request.tokenAmount);
        if (payout > 0) IERC20(asset).safeTransfer(request.receiver, payout);
        emit Settle(id, payout, request.quotedAssets);
    }

    /// @inheritdoc ISpikoRedemption
    function cancelRedemption(address user, address input, address output, uint256 value, bytes32 salt) public {
        if (user != msg.sender && owner() != msg.sender) revert ITestnetProviderIssuer.InvalidCaller();
        if (input != token || output != asset) revert ITestnetProviderIssuer.InvalidRoute();
        bytes32 id = keccak256(abi.encodePacked(user, input, output, value, salt));
        RequestData storage request = requests[id];
        if (request.status != Status.PENDING) revert ITestnetProviderIssuer.InvalidRequest();
        if (block.timestamp < request.deadline) revert ITestnetProviderIssuer.NotReady();
        request.status = Status.CANCELED;
        IERC20(token).safeTransfer(user, value);
        emit CancelRedemption(id, value);
    }
}

/// @title TestnetOpenEdenExpress
/// @notice Native OpenEden pending/final queues with locked quotes and issuer-funded final payouts.
contract TestnetOpenEdenExpress is Ownable, IOpenEdenExpress {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /* IMMUTABLES */

    address public immutable token;
    address public immutable redeemAsset;
    address public immutable priceOracle;

    /* STATE VARIABLES */

    struct RequestData {
        address sender;
        address receiver;
        uint256 tokenAmount;
        uint256 grossAssets;
        uint256 feeAssets;
        uint48 requestedAt;
        uint8 stage;
    }

    uint256 public requestCount;
    mapping(address receiver => uint256 amount) public pendingRedeemInfo;
    mapping(address receiver => uint256 amount) public redeemInfo;
    mapping(uint256 id => RequestData data) public requests;
    uint256[] internal _queue;

    event RequestRedeem(uint256 indexed id, address indexed receiver, uint256 tokenAmount);
    event Lock(uint256 indexed id, uint256 grossAssets, uint256 feeAssets);
    event Settle(uint256 indexed id, uint256 payout);

    /* CONSTRUCTOR */

    constructor(address newOwner, address newToken, address newAsset, address newOracle) Ownable(newOwner) {
        token = newToken;
        redeemAsset = newAsset;
        priceOracle = newOracle;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IOpenEdenExpress
    function maxStalePeriod() public pure returns (uint256) {
        return 30 hours;
    }

    /// @inheritdoc IOpenEdenExpress
    function redeemMinimum() public pure returns (uint256) {
        return 1e18;
    }

    /// @inheritdoc IOpenEdenExpress
    function previewRedeem(uint256 amount) public view returns (uint256 fee, uint256 gross, uint256 net) {
        (uint256 price,) = IPriceDataOracle(priceOracle).getPriceData();
        gross = amount.mulDiv(price * 10 ** IERC20Metadata(redeemAsset).decimals(), 1e36);
        fee = gross.mulDiv(5, 10_000);
        net = gross - fee;
    }

    /// @inheritdoc IOpenEdenExpress
    function getRedeemQueueLength() public view returns (uint256) {
        return _queue.length;
    }

    /// @inheritdoc IOpenEdenExpress
    function getRedeemQueueInfo(uint256 index)
        public
        view
        returns (address, address, uint256, uint256, uint256, uint256, uint256, bytes32)
    {
        uint256 id = _queue[index];
        RequestData memory request = requests[id];
        return (
            request.sender,
            request.receiver,
            request.tokenAmount,
            request.tokenAmount,
            request.grossAssets,
            request.feeAssets,
            request.requestedAt,
            bytes32(id)
        );
    }

    /// @inheritdoc IOpenEdenExpress
    function requestRedeem(address to, uint256 amount) public {
        if (to == address(0) || amount < redeemMinimum()) revert ITestnetProviderIssuer.InvalidRequest();
        previewRedeem(amount);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 id = requestCount++;
        requests[id] = RequestData({
            sender: msg.sender,
            receiver: to,
            tokenAmount: amount,
            grossAssets: 0,
            feeAssets: 0,
            requestedAt: uint48(block.timestamp),
            stage: 1
        });
        pendingRedeemInfo[to] += amount;
        emit RequestRedeem(id, to, amount);
    }

    /// @notice Moves a matured pending request to the final queue using a fresh locked quote.
    function lock(uint256 id) public onlyOwner {
        RequestData storage request = requests[id];
        if (request.stage != 1) revert ITestnetProviderIssuer.InvalidRequest();
        if (block.timestamp < request.requestedAt + 1 days) revert ITestnetProviderIssuer.NotReady();
        (request.feeAssets, request.grossAssets,) = previewRedeem(request.tokenAmount);
        request.stage = 2;
        pendingRedeemInfo[request.receiver] -= request.tokenAmount;
        redeemInfo[request.receiver] += request.tokenAmount;
        _queue.push(id);
        TestnetToken(token).burn(request.tokenAmount);
        emit Lock(id, request.grossAssets, request.feeAssets);
    }

    /// @notice Pays a funded full or short final-queue amount and removes the issuer obligation.
    function settle(uint256 id, uint256 payout) public onlyOwner {
        RequestData storage request = requests[id];
        if (request.stage != 2 || payout > request.grossAssets - request.feeAssets) {
            revert ITestnetProviderIssuer.InvalidRequest();
        }
        if (block.timestamp < request.requestedAt + 2 days) revert ITestnetProviderIssuer.NotReady();
        request.stage = 3;
        redeemInfo[request.receiver] -= request.tokenAmount;
        uint256 length = _queue.length;
        for (uint256 i; i < length; ++i) {
            if (_queue[i] == id) {
                _queue[i] = _queue[length - 1];
                _queue.pop();
                break;
            }
        }
        if (payout > 0) IERC20(redeemAsset).safeTransfer(request.receiver, payout);
        emit Settle(id, payout);
    }
}

/// @title TestnetDailySecuritizeAccount
/// @notice Production Securitize account base with daily testnet repurchase cutoff cohorts.
contract TestnetDailySecuritizeAccount is SecuritizeAccount {
    /* CONSTRUCTOR */

    constructor(address newOracle, address newFactory, address newToken, address newWallet, address newCow)
        SecuritizeAccount(newOracle, newFactory, 12 hours, newToken, newWallet, 4 days, 30 days, newCow)
    {}

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ICutoffAccount
    function timestampToBucket(uint48 timestamp) public pure override(CutoffAccount, ICutoffAccount) returns (uint48) {
        return uint48((uint256(timestamp) + 1 days - 1) / 1 days);
    }

    /// @inheritdoc ICutoffAccount
    function bucketToTimestamp(uint48 bucket) public pure override(CutoffAccount, ICutoffAccount) returns (uint48) {
        return bucket * uint48(1 days);
    }
}

/// @title TestnetProviderDeploymentScript
/// @notice Deploys all native provider dependencies and their current production account implementations.
/// @dev Construct and invoke outside the parent's broadcast region: this local script embeds creation
/// code and is never a chain-deployed factory. Profile order is ACRED, STAC, VBILL, USCC, bEQTY,
/// SPKCC, Asseto, OpenEden, then daily Securitize. Funding and share issuance are explicit later phases.
contract TestnetProviderDeploymentScript is Script {
    /// @notice Profile order shared with the full testnet deployment catalog.
    enum Profile {
        ACRED,
        STAC,
        VBILL,
        USCC,
        BEQTY,
        SPKCC,
        ASSETO,
        OPENEDEN,
        SECURITIZE
    }

    /* IMMUTABLES */

    address internal immutable _OWNER;
    bool internal immutable _BROADCAST;

    /* CONSTRUCTOR */

    constructor(address newOwner, bool newBroadcast) {
        _OWNER = newOwner;
        _BROADCAST = newBroadcast;
    }

    /* PUBLIC FUNCTIONS */

    /// @notice Deploys a profile's issued token, oracle, native endpoint, and account implementation.
    function deploy(address factory, address cow, address asset, uint8 profile)
        public
        returns (address token, address oracle, address endpoint, address implementation)
    {
        if (profile > 8) revert ITestnetProviderIssuer.InvalidRoute();
        if (_BROADCAST) vm.startBroadcast(_OWNER);
        else vm.startPrank(_OWNER);
        uint256 price = profile == 0
            ? 100e18
            : profile == 1
                ? 1000e18
                : profile == 2
                    ? 1.02e18
                    : profile == 3
                        ? 11.4e18
                        : profile == 4
                            ? 100e18
                            : profile == 5 ? 1.03e18 : profile == 6 ? 11.2e18 : profile == 7 ? 1.08e18 : 1e18;
        address feed = profile == 6
            ? address(new TestnetAssetoPricer(_OWNER, int256(price)))
            : address(new TestnetPriceFeed(_OWNER, "Testnet issuer NAV", 18, 30 hours, int256(price)));
        if (profile == 6) {
            oracle = address(new AssetoOracle(1e18, 100e18, feed));
        } else if (profile != 7) {
            uint256 minimum = profile == 1 ? 100e18 : profile == 2 ? 0.95e18 : profile == 5 ? 0.5e18 : price / 10;
            uint256 maximum = profile == 1 ? 10_000e18 : profile == 2 ? 1.05e18 : profile == 5 ? 2e18 : price * 10;
            oracle = address(new ChainlinkOracle(minimum, maximum, [feed, address(0)], [uint48(30 hours), uint48(0)]));
        }
        if (profile == 0 || profile == 1 || profile == 8) {
            token = address(
                new TestnetNoticeToken(
                    "Testnet Securitize shares",
                    profile == 0 ? "ACRED" : profile == 1 ? "STAC" : "SECURITIZE",
                    6,
                    _OWNER
                )
            );
        } else if (profile == 3) {
            token = address(new TestnetSuperstateToken(_OWNER));
        } else if (profile == 5) {
            token = address(new TestnetSpikoToken(_OWNER));
        } else {
            token = address(
                new TestnetToken(
                    "Testnet issuer shares",
                    profile == 2 ? "VBILL" : profile == 4 ? "bEQTY" : profile == 6 ? "AoABT" : "HYBOND",
                    profile == 2 ? 6 : 18,
                    _OWNER
                )
            );
        }
        if (profile == 2) {
            endpoint = address(new TestnetSecuritizeOffRamp(_OWNER, token, asset, oracle));
            implementation = address(new SecuritizeOffRampAccount(oracle, factory, token, endpoint, asset, cow));
        } else if (profile == 5) {
            endpoint = address(new TestnetSpikoRedemption(_OWNER, token, asset, oracle));
            implementation = address(new SpikoAccount(oracle, factory, token, endpoint, asset, 30 days, cow));
        } else if (profile == 7) {
            endpoint = address(new TestnetOpenEdenExpress(_OWNER, token, asset, feed));
            oracle = address(new OpenEdenOracle(1, type(uint256).max, token, endpoint));
            implementation = address(new OpenEdenAccount(oracle, factory, 12 hours, token, endpoint, cow));
        } else {
            endpoint = address(new TestnetProviderIssuer(_OWNER, token, asset, oracle, profile));
            if (profile == 0) {
                TestnetNoticeToken(token).setEndpoint(endpoint);
                implementation =
                    address(new AcredSecuritizeAccount(oracle, factory, token, endpoint, 4 days, 30 days, cow));
            } else if (profile == 1) {
                TestnetNoticeToken(token).setEndpoint(endpoint);
                implementation = address(new SecuritizeNoticeAccount(oracle, factory, token, endpoint, 30 days, cow));
            } else if (profile == 3) {
                TestnetSuperstateToken(token).setEndpoint(endpoint);
                implementation = address(new SuperstateAccount(oracle, factory, 12 hours, token, 3 days, cow));
            } else if (profile == 4) {
                implementation = address(new DigiFTAccount(oracle, factory, token, endpoint, 7 days, cow));
            } else if (profile == 6) {
                implementation =
                    address(new AssetoAccount(oracle, factory, 12 hours, token, endpoint, 1 days, 30 days, cow));
            } else {
                TestnetNoticeToken(token).setEndpoint(endpoint);
                implementation = address(new TestnetDailySecuritizeAccount(oracle, factory, token, endpoint, cow));
            }
        }
        if (_BROADCAST) vm.stopBroadcast();
        else vm.stopPrank();
    }
}
