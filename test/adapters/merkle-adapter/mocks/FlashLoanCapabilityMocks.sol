// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {IFlashLoanCapability} from "src/interfaces/merkle-adapter/capabilities/IFlashLoanCapability.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract FlashLoanTokenMock is ERC20 {
    address public approvalCallback;

    constructor() ERC20("Flash loan asset", "FLASH") {}

    function mint(address recipient, uint256 amount) public {
        _mint(recipient, amount);
    }

    function setApprovalCallback(address newApprovalCallback) public {
        approvalCallback = newApprovalCallback;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        bool result = super.approve(spender, amount);
        if (approvalCallback != address(0) && amount > 0) FlashLoanLenderMock(approvalCallback).replay();
        return result;
    }
}

/// @dev Exercises the exact single-asset lender ABIs and configurable hostile callbacks.
contract FlashLoanLenderMock {
    using SafeERC20 for IERC20;

    enum Mutation {
        None,
        Token,
        Amount,
        Data,
        Initiator,
        Skip,
        Sender,
        Replay
    }

    uint256 public constant PREMIUM = 7;
    Mutation public mutation;
    address public otherLender;
    address internal _receiver;
    address internal _token;
    uint256 internal _amount;
    bytes internal _data;
    address internal _initiator;
    bool internal _aave;

    function configure(Mutation newMutation, address newOtherLender) public {
        mutation = newMutation;
        otherLender = newOtherLender;
    }

    function flashLoanSimple(address receiver, address token, uint256 amount, bytes calldata data, uint16) public {
        _receiver = receiver;
        _token = token;
        _amount = amount;
        _data = data;
        _initiator = msg.sender;
        _aave = true;
        IERC20(token).safeTransfer(receiver, amount);
        if (mutation == Mutation.Skip) return;
        _callback();
        if (mutation == Mutation.Replay) _callback();
        IERC20(token).safeTransferFrom(receiver, address(this), amount + PREMIUM);
    }

    function flashLoan(address token, uint256 amount, bytes calldata data) public {
        _receiver = msg.sender;
        _token = token;
        _amount = amount;
        _data = data;
        _initiator = msg.sender;
        _aave = false;
        IERC20(token).safeTransfer(msg.sender, amount);
        if (mutation == Mutation.Skip) return;
        _callback();
        if (mutation == Mutation.Replay) _callback();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    function replay() public {
        _callback();
    }

    function dispatch(address receiver, bool aave, address token, uint256 amount, address initiator, bytes memory data)
        public
    {
        if (aave) {
            require(IFlashLoanCapability(receiver).executeOperation(token, amount, PREMIUM, initiator, data));
        } else {
            IFlashLoanCapability(receiver).onMorphoFlashLoan(amount, data);
        }
    }

    function _callback() internal {
        address token = mutation == Mutation.Token ? address(0xBAD) : _token;
        uint256 amount = mutation == Mutation.Amount ? _amount + 1 : _amount;
        bytes memory data = _data;
        if (_aave) {
            if (mutation == Mutation.Data) data = bytes.concat(data, hex"01");
        } else if (mutation == Mutation.Token || mutation == Mutation.Data) {
            (, bytes memory innerData) = abi.decode(data, (address, bytes));
            data = abi.encode(token, mutation == Mutation.Data ? bytes.concat(innerData, hex"01") : innerData);
        }
        address initiator = mutation == Mutation.Initiator ? address(0xBAD) : _initiator;
        if (mutation == Mutation.Sender) {
            FlashLoanLenderMock(otherLender).dispatch(_receiver, _aave, token, amount, initiator, data);
        } else {
            dispatch(_receiver, _aave, token, amount, initiator, data);
        }
    }
}

contract FlashLoanSubjectMock {
    using SafeERC20 for IERC20;

    error ActionFailed();

    uint256 public calls;
    uint256 public borrowed;
    address public caller;

    function returnTokens(address token, uint256 amount) public {
        ++calls;
        borrowed += amount;
        caller = msg.sender;
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function fail() public pure {
        revert ActionFailed();
    }
}
