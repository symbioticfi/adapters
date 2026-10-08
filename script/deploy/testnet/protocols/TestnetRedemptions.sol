// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {TestnetToken, TestnetPriceFeed} from "./TestnetAssets.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TestnetMidasRedemptionVault
/// @notice Funded Midas-standard redemption requests with locked prices, fees, delay and issuer approval.
contract TestnetMidasRedemptionVault is Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;
    error InvalidRequest();
    error NotReady();

    struct Request {
        address sender;
        address tokenOut;
        uint8 status;
        uint256 amountMToken;
        uint256 mTokenRate;
        uint256 tokenOutRate;
    }
    address public immutable mToken;
    address public immutable mTokenDataFeed;
    address public immutable outputAsset;
    uint48 public immutable settlementDelay;
    uint256 public immutable fee;
    uint256 public nextRequestId;
    uint256 public activeRequestCount;
    mapping(uint256 id => Request request) public redeemRequests;
    mapping(uint256 id => uint48 timestamp) public readyAt;
    event RedeemRequest(
        uint256 indexed requestId,
        address indexed sender,
        address indexed tokenOut,
        uint256 amountMToken,
        uint256 fee,
        uint256 mTokenRate,
        uint256 tokenOutRate
    );
    event ApproveRedeemRequest(uint256 indexed requestId, uint256 newMTokenRate);
    event RejectRedeemRequest(uint256 indexed requestId);

    constructor(address newOwner, address newToken, address newFeed, address newAsset, uint48 newDelay, uint256 newFee)
        Ownable(newOwner)
    {
        mToken = newToken;
        mTokenDataFeed = newFeed;
        outputAsset = newAsset;
        settlementDelay = newDelay;
        fee = newFee;
    }

    function tokensConfig(address token) public view returns (address, uint256, uint256, bool) {
        return token == outputAsset ? (address(0), fee, type(uint256).max, true) : (address(0), 0, 0, false);
    }

    function redeemRequest(address tokenOut, uint256 amount) public returns (uint256 id) {
        if (tokenOut != outputAsset || amount == 0) revert InvalidRequest();
        uint256 charged = amount.mulDiv(fee, 10_000);
        uint256 rate = TestnetPriceFeed(mTokenDataFeed).getDataInBase18();
        IERC20(mToken).safeTransferFrom(msg.sender, address(this), amount);
        id = nextRequestId++;
        ++activeRequestCount;
        redeemRequests[id] = Request({
            sender: msg.sender,
            tokenOut: tokenOut,
            status: 0,
            amountMToken: amount - charged,
            mTokenRate: rate,
            tokenOutRate: 1e18
        });
        readyAt[id] = uint48(block.timestamp) + settlementDelay;
        emit RedeemRequest(id, msg.sender, tokenOut, amount, charged, rate, 1e18);
    }

    function approveRequest(uint256 id) public onlyOwner {
        _approveRequest(id, redeemRequests[id].mTokenRate);
    }

    function settleRequest(uint256 id, uint256 newRate) public onlyOwner {
        if (newRate == 0) revert InvalidRequest();
        _approveRequest(id, newRate);
    }

    function _approveRequest(uint256 id, uint256 newRate) internal {
        Request storage request = redeemRequests[id];
        if (request.sender == address(0) || request.status > 0) revert InvalidRequest();
        if (block.timestamp < readyAt[id]) revert NotReady();
        uint256 assets = request.amountMToken
            .mulDiv(
                newRate * 10 ** IERC20Metadata(outputAsset).decimals(), 1e18 * 10 ** IERC20Metadata(mToken).decimals()
            );
        request.status = 1;
        --activeRequestCount;
        request.mTokenRate = newRate;
        TestnetToken(mToken).burn(request.amountMToken);
        IERC20(outputAsset).safeTransfer(request.sender, assets);
        emit ApproveRedeemRequest(id, request.mTokenRate);
    }

    function rejectRequest(uint256 id) public onlyOwner {
        Request storage request = redeemRequests[id];
        if (request.sender == address(0) || request.status > 0) revert InvalidRequest();
        request.status = 2;
        --activeRequestCount;
        IERC20(mToken).safeTransfer(request.sender, request.amountMToken);
        emit RejectRedeemRequest(id);
    }
}

/// @title TestnetAsyncVault
/// @notice Funded ERC-7540-shaped request/fulfillment/claim lifecycle with fixed fulfillment prices.
/// @dev Single outstanding request per controller, matching the request-zero aggregation used by accounts.
contract TestnetAsyncVault is ERC20, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;
    error InvalidRequest();
    error NotReady();
    address public immutable asset;
    address public immutable priceFeed;
    uint48 public immutable delay;
    uint256 public nextRequestId;
    uint256 public reservedAssets;
    mapping(address controller => uint256 id) public activeRequest;
    mapping(address controller => uint256 shares) public pending;
    mapping(address controller => uint256 shares) public claimable;
    mapping(address controller => uint256 assets) public claimableAssets;
    mapping(address controller => uint48 timestamp) public readyAt;
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );
    event FulfillRedeem(address indexed controller, uint256 shares, uint256 assets);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    constructor(
        address newOwner,
        address newAsset,
        address newFeed,
        uint48 newDelay,
        string memory newName,
        string memory newSymbol
    ) ERC20(newName, newSymbol) Ownable(newOwner) {
        asset = newAsset;
        priceFeed = newFeed;
        delay = newDelay;
    }

    function mint(address receiver, uint256 shares) public onlyOwner {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), convertToAssets(shares));
        _mint(receiver, shares);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return
            shares.mulDiv(TestnetPriceFeed(priceFeed).getDataInBase18() * 10 ** IERC20Metadata(asset).decimals(), 1e36);
    }

    function pendingRedeemRequest(uint256 id, address controller) public view returns (uint256) {
        return id == 0 || id == activeRequest[controller] ? pending[controller] : 0;
    }

    function claimableRedeemRequest(uint256 id, address controller) public view returns (uint256) {
        return id == 0 || id == activeRequest[controller] ? claimable[controller] : 0;
    }

    function maxWithdraw(address controller) public view returns (uint256) {
        return claimableAssets[controller];
    }

    function maxRedeem(address controller) public view returns (uint256) {
        return claimable[controller];
    }

    function requestRedeem(uint256 shares, address controller, address account) public returns (uint256 id) {
        if (controller != msg.sender || shares == 0 || pending[controller] > 0 || claimable[controller] > 0) {
            revert InvalidRequest();
        }
        if (account != msg.sender) _spendAllowance(account, msg.sender, shares);
        _transfer(account, address(this), shares);
        pending[controller] = shares;
        readyAt[controller] = uint48(block.timestamp) + delay;
        id = ++nextRequestId;
        activeRequest[controller] = id;
        emit RedeemRequest(controller, account, id, msg.sender, shares);
    }

    function fulfill(address controller) public onlyOwner {
        uint256 shares = pending[controller];
        if (shares == 0) revert InvalidRequest();
        if (block.timestamp < readyAt[controller]) revert NotReady();
        uint256 assets = convertToAssets(shares);
        // Pending claims cannot consume cash already reserved for another controller.
        if (IERC20(asset).balanceOf(address(this)) < reservedAssets + assets) revert NotReady();
        reservedAssets += assets;
        pending[controller] = 0;
        claimable[controller] += shares;
        claimableAssets[controller] += assets;
        emit FulfillRedeem(controller, shares, assets);
    }

    function redeem(uint256 shares, address receiver, address controller) public returns (uint256 assets) {
        if (controller != msg.sender || shares == 0 || shares > claimable[controller]) revert InvalidRequest();
        assets = shares.mulDiv(claimableAssets[controller], claimable[controller]);
        claimable[controller] -= shares;
        claimableAssets[controller] -= assets;
        reservedAssets -= assets;
        if (claimable[controller] == 0) delete activeRequest[controller];
        _burn(address(this), shares);
        IERC20(asset).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }
}
