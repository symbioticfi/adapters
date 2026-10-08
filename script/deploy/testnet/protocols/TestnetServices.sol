// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {GPv2Order} from "src/libraries/GPv2Order.sol";

import {ICoWSwapSettlement} from "src/interfaces/common/ICoWSwapConverter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TestnetMerklDistributor
/// @notice Funded cumulative reward claims with Merkle verification and replay protection.
contract TestnetMerklDistributor is Ownable {
    using SafeERC20 for IERC20;
    error InvalidClaim();
    bytes32 public root;
    mapping(address user => mapping(address token => uint256 amount)) public claimed;
    event Claimed(address indexed user, address indexed token, uint256 amount);
    event SetRoot(bytes32 root);
    constructor(address newOwner) Ownable(newOwner) {}

    function setRoot(bytes32 newRoot) public onlyOwner {
        root = newRoot;
        emit SetRoot(newRoot);
    }

    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) public {
        if (
            users.length == 0 || users.length != tokens.length || users.length != amounts.length
                || users.length != proofs.length
        ) revert InvalidClaim();
        for (uint256 i; i < users.length; ++i) {
            if (users[i] != msg.sender && users[i] != tx.origin && owner() != msg.sender) revert InvalidClaim();
            // Merkl's native leaf pads both addresses to 32 bytes.
            bytes32 leaf = keccak256(abi.encode(users[i], tokens[i], amounts[i]));
            if (!MerkleProof.verifyCalldata(proofs[i], root, leaf) || amounts[i] < claimed[users[i]][tokens[i]]) {
                revert InvalidClaim();
            }
            uint256 amount = amounts[i] - claimed[users[i]][tokens[i]];
            claimed[users[i]][tokens[i]] = amounts[i];
            IERC20(tokens[i]).safeTransfer(users[i], amount);
            emit Claimed(users[i], tokens[i], amount);
        }
    }
}

/// @title TestnetCowRelayer
/// @notice Moves only settlement-authorized, user-approved ERC20 sell amounts.
contract TestnetCowRelayer {
    using SafeERC20 for IERC20;
    error InvalidCaller();
    address public immutable settlement;

    constructor(address newSettlement) {
        settlement = newSettlement;
    }

    function transferFrom(address token, address sender, address receiver, uint256 amount) public {
        if (settlement != msg.sender) revert InvalidCaller();
        IERC20(token).safeTransferFrom(sender, receiver, amount);
    }
}

/// @title TestnetCowSettlement
/// @notice Funded presigned sell-order settlement with canonical GPv2 hashes, UIDs and partial-fill limits.
/// @dev Covers ERC20 balances and presignatures. Solver auction, Balancer balances and signature schemes are absent.
contract TestnetCowSettlement is ReentrancyGuard, ICoWSwapSettlement {
    using SafeERC20 for IERC20;
    using GPv2Order for GPv2Order.Data;
    using Math for uint256;
    error InvalidOrder();
    address public immutable vaultRelayer;
    bytes32 public immutable domainSeparator;
    mapping(bytes uid => uint256 signed) public preSignature;
    mapping(bytes uid => uint256 amount) public filledAmount;
    event PreSignature(address indexed owner, bytes orderUid, bool signed);
    event Trade(
        address indexed owner,
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 buyAmount,
        uint256 feeAmount,
        bytes orderUid
    );

    constructor() {
        vaultRelayer = address(new TestnetCowRelayer(address(this)));
        domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Gnosis Protocol"),
                keccak256("v2"),
                block.chainid,
                address(this)
            )
        );
    }

    function setPreSignature(bytes calldata orderUid, bool signed) public {
        (, address owner,) = GPv2Order.extractOrderUidParams(orderUid);
        if (owner != msg.sender) revert InvalidOrder();
        preSignature[orderUid] = signed ? uint256(keccak256("GPv2Signing.Scheme.PreSign")) : 0;
        emit PreSignature(owner, orderUid, signed);
    }

    function fill(GPv2Order.Data memory order, bytes calldata uid, uint256 sellAmount, uint256 buyAmount)
        public
        nonReentrant
    {
        (bytes32 hash, address owner, uint32 validTo) = GPv2Order.extractOrderUidParams(uid);
        if (
            hash != order.hash(domainSeparator) || validTo != order.validTo || block.timestamp > validTo
                || preSignature[uid] == 0 || order.kind != GPv2Order.KIND_SELL
                || order.sellTokenBalance != GPv2Order.BALANCE_ERC20 || order.buyTokenBalance != GPv2Order.BALANCE_ERC20
                || sellAmount == 0 || order.sellAmount == 0
                || (!order.partiallyFillable && sellAmount != order.sellAmount)
        ) revert InvalidOrder();
        uint256 prior = filledAmount[uid];
        uint256 filled = prior + sellAmount;
        if (
            filled > order.sellAmount
                || buyAmount < sellAmount.mulDiv(order.buyAmount, order.sellAmount, Math.Rounding.Ceil)
        ) revert InvalidOrder();
        uint256 fee = filled.mulDiv(order.feeAmount, order.sellAmount) - prior.mulDiv(order.feeAmount, order.sellAmount);
        filledAmount[uid] = filled;
        IERC20(address(order.buyToken)).safeTransferFrom(msg.sender, order.actualReceiver(owner), buyAmount);
        TestnetCowRelayer(vaultRelayer).transferFrom(address(order.sellToken), owner, msg.sender, sellAmount + fee);
        emit Trade(owner, address(order.sellToken), address(order.buyToken), sellAmount, buyAmount, fee, uid);
    }
}

/// @title TestnetBurner
/// @notice Funded slash receiver with canonical AppAdapter burner entrypoint and observable burn events.
contract TestnetBurner {
    using SafeERC20 for IERC20;
    address public immutable collateral;
    event OnSlash(bytes32 indexed subnetwork, address indexed operator, uint256 amount, uint48 captureTimestamp);

    constructor(address newCollateral) {
        collateral = newCollateral;
    }

    function onSlash(bytes32 subnetwork, address operator, uint256 amount, uint48 captureTimestamp) public {
        IERC20(collateral).safeTransfer(address(0xdead), amount);
        emit OnSlash(subnetwork, operator, amount, captureTimestamp);
    }
}
