// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct BorrowTestCall {
    address target;
    bytes data;
}

contract BorrowCapabilityAdapterMock {
    using Address for address;

    function execute(address target, bytes calldata data) external returns (bytes memory) {
        return target.functionCall(data);
    }
}

contract BorrowCapabilityTokenMock is ERC20 {
    error TransferFailed();

    bool public failTransfers;
    address public callbackTarget;
    bytes public callbackData;
    address public callbackSender;

    constructor() ERC20("Borrow asset", "BORROW") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function setFailTransfers(bool fail) external {
        failTransfers = fail;
    }

    function setTransferCallback(address sender, address target, bytes calldata data) external {
        callbackSender = sender;
        callbackTarget = target;
        callbackData = data;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (failTransfers && from != address(0)) {
            revert TransferFailed();
        }
        super._update(from, to, amount);
        if (from != address(0) && from == callbackSender) {
            Address.functionCall(callbackTarget, callbackData);
        }
    }
}

/// @dev Models Aave's distinct borrow caller/fund recipient and delegated debt owner, using the same ABI.
contract BorrowCapabilityPoolMock {
    error BorrowFailed();
    error MissingDelegation();
    error QueryFailed();

    IERC20 public immutable asset;
    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;
    mapping(address => bool) public reserves;
    mapping(address => mapping(address => uint256)) public delegation;
    bool public sendDirectly;
    bool public failBorrow;
    uint256 public queryMode;
    address public callbackTarget;
    bytes public callbackData;

    constructor(address asset_) {
        asset = IERC20(asset_);
        reserves[asset_] = true;
    }

    function setReserve(address token) external {
        reserves[token] = true;
    }

    function withdrawCollateral(uint256 amount, address account) external {
        collateral[account] -= amount;
    }

    function setCollateral(address account, uint256 amount) external {
        collateral[account] = amount;
    }

    function approveDelegation(address delegatee, uint256 amount) external {
        delegation[msg.sender][delegatee] = amount;
    }

    function setSendDirectly(bool direct) external {
        sendDirectly = direct;
    }

    function setFailBorrow(bool fail) external {
        failBorrow = fail;
    }

    function setQueryMode(uint256 mode) external {
        queryMode = mode;
    }

    function statefulHealth() external returns (uint256) {
        ++queryMode;
        return type(uint256).max;
    }

    function setBorrowCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function borrow(address asset_, uint256 amount, uint256 rateMode, uint16 referral, address onBehalfOf)
        external
        returns (uint256)
    {
        if (failBorrow || !reserves[asset_] || amount == 0 || rateMode != 2 || referral != 0) {
            revert BorrowFailed();
        }
        if (msg.sender != onBehalfOf) {
            uint256 allowance_ = delegation[onBehalfOf][msg.sender];
            if (allowance_ < amount) {
                revert MissingDelegation();
            }
            if (allowance_ != type(uint256).max) {
                delegation[onBehalfOf][msg.sender] = allowance_ - amount;
            }
        }
        debt[onBehalfOf] += amount;
        IERC20(asset_).transfer(sendDirectly ? onBehalfOf : msg.sender, amount);
        if (callbackTarget != address(0)) {
            Address.functionCall(callbackTarget, callbackData);
        }
        return amount;
    }

    function repay(uint256 amount, address account) external {
        debt[account] -= amount;
        asset.transferFrom(msg.sender, address(this), amount);
    }

    function getUserAccountData(address account)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        if (queryMode == 1) {
            revert QueryFailed();
        }
        if (queryMode == 2) {
            assembly ("memory-safe") {
                mstore(0, 0xffff)
                return(0, 31)
            }
        }
        if (queryMode == 3) {
            return (0, 0, 0, 0, 0, 0);
        }
        if (queryMode == 4) {
            assembly ("memory-safe") {
                mstore(0, not(0))
                return(0, 32)
            }
        }
        if (queryMode == 5) {
            bytes memory response =
                abi.encode(uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), type(uint256).max);
            assembly ("memory-safe") {
                return(add(response, 32), 191)
            }
        }
        return (collateral[account], debt[account], 0, 8000, 7500, healthFactor(account));
    }

    function healthFactor(address account) public view returns (uint256) {
        return debt[account] == 0 ? type(uint256).max : collateral[account] * 1e18 / debt[account];
    }
}
