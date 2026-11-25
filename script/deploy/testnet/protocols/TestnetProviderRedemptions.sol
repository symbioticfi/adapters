// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {OpenEdenAccount} from "src/contracts/ll-adapter/OpenEdenAccount.sol";
import {OpenEdenOracle} from "src/contracts/ll-adapter/oracles/OpenEdenOracle.sol";
import {TestnetPriceFeed, TestnetToken} from "./TestnetAssets.sol";

import {IOpenEdenExpress} from "src/interfaces/ll-adapter/openeden/IOpenEdenExpress.sol";
import {IPriceDataOracle} from "src/interfaces/ll-adapter/IPriceDataOracle.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Script} from "forge-std/Script.sol";

/// @title TestnetOpenEdenExpress
/// @notice Native OpenEden pending/final queues with locked quotes and issuer-funded final payouts.
contract TestnetOpenEdenExpress is Ownable, IOpenEdenExpress {
    using SafeERC20 for IERC20;
    using Math for uint256;

    error InvalidRequest();
    error NotReady();

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
    uint256 public activeRequestCount;
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
        if (to == address(0) || amount < redeemMinimum()) revert InvalidRequest();
        previewRedeem(amount);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 id = requestCount++;
        ++activeRequestCount;
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
        if (request.stage != 1) revert InvalidRequest();
        if (block.timestamp < request.requestedAt + 1 days) revert NotReady();
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
            revert InvalidRequest();
        }
        if (block.timestamp < request.requestedAt + 2 days) revert NotReady();
        request.stage = 3;
        --activeRequestCount;
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

/// @title TestnetProviderDeploymentScript
/// @notice Deploys the fixture token, native redemption endpoint, and OpenEden account.
contract TestnetProviderDeploymentScript is Script {
    address internal immutable _OWNER;
    bool internal immutable _BROADCAST;

    constructor(address newOwner, bool newBroadcast) {
        _OWNER = newOwner;
        _BROADCAST = newBroadcast;
    }

    function deploy(address factory, address cow, address asset)
        public
        returns (address token, address oracle, address endpoint, address implementation)
    {
        if (_BROADCAST) vm.startBroadcast(_OWNER);
        else vm.startPrank(_OWNER);
        address feed = address(new TestnetPriceFeed(_OWNER, "Testnet issuer NAV", 18, 30 hours, 1.08e18));
        token = address(new TestnetToken("Testnet issuer shares", "HYBOND", 18, _OWNER));
        endpoint = address(new TestnetOpenEdenExpress(_OWNER, token, asset, feed));
        oracle = address(new OpenEdenOracle(1, type(uint256).max, token, endpoint));
        implementation = address(new OpenEdenAccount(oracle, factory, 12 hours, token, endpoint, cow));
        if (_BROADCAST) vm.stopBroadcast();
        else vm.stopPrank();
    }
}
