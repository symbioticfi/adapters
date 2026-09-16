// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICoWSwapAction} from "src/interfaces/merkle_adapter/ICoWSwapAction.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Restricted relayer boundary for exercising actual ERC20 allowance consumption in offline tests.
contract CoWActionRelayerMock {
    using SafeERC20 for IERC20;

    address internal immutable _settlement;

    constructor() {
        _settlement = msg.sender;
    }

    function pull(address token, address from, uint256 amount) external {
        require(msg.sender == _settlement, "Only settlement");
        IERC20(token).safeTransferFrom(from, _settlement, amount);
    }
}

/// @dev CoW pre-signature ownership boundary; mainnet tests exercise actual protocol hashing and settlement.
contract CoWActionSettlementMock {
    bytes32 public constant domainSeparator = 0xc078f884a2676e1345748b1feace7b0abee5d00ecadb6e574dcdd109a63e8943;
    address public immutable vaultRelayer = address(new CoWActionRelayerMock());
    mapping(bytes orderUid => uint256 value) public preSignature;

    function setPreSignature(bytes calldata orderUid, bool signed) external {
        require(orderUid.length == 56, "GPv2: invalid uid");
        require(address(bytes20(orderUid[32:52])) == msg.sender, "GPv2: cannot presign order");
        preSignature[orderUid] = signed ? uint256(keccak256("GPv2Signing.Scheme.PreSign")) : 0;
    }

    function consumeSellTokens(address token, address owner, uint256 amount) external {
        CoWActionRelayerMock(vaultRelayer).pull(token, owner, amount);
    }

    function consumePresignedSellTokens(bytes calldata orderUid, address token, uint256 amount) external {
        require(preSignature[orderUid] != 0, "GPv2: order not presigned");
        require(orderUid.length == 56, "GPv2: invalid uid");
        CoWActionRelayerMock(vaultRelayer).pull(token, address(bytes20(orderUid[32:52])), amount);
    }
}

/// @dev Malformed settlement used to reject deployment when no relayer contract exists.
contract CoWActionSettlementWithoutRelayerMock {
    function vaultRelayer() external pure returns (address) {
        return address(0);
    }
}

/// @dev Models a paused token that rejects approvals and transfers while preserving balances and allowances.
contract CoWActionPausedTokenMock is ERC20 {
    error TokenPaused();

    bool public paused;

    constructor() ERC20("Paused Token", "PAUSE") {
        _mint(msg.sender, 1000);
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        if (paused) {
            revert TokenPaused();
        }
        return super.approve(spender, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) {
            revert TokenPaused();
        }
        super._update(from, to, value);
    }
}

/// @dev A transfer-tax token makes the action's exact-funding requirement observable.
contract CoWActionTaxTokenMock is ERC20 {
    constructor() ERC20("Tax Token", "TAX") {
        _mint(msg.sender, 1e24);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value > 0) {
            super._update(from, address(0), 1);
            value -= 1;
        }
        super._update(from, to, value);
    }
}

/// @dev Emulates an ERC20 callback routed through the adapter while order funding is in progress.
contract CoWActionCallbackTokenMock is ERC20 {
    address internal _callback;
    bool internal _insideCallback;

    constructor() ERC20("Callback Token", "CALL") {
        _mint(msg.sender, 1000);
    }

    function setCallback(address callback) external {
        _callback = callback;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (_callback != address(0) && from == _callback && to != address(0) && !_insideCallback) {
            _insideCallback = true;
            CoWActionCallbackAdapterMock(_callback).onTransfer();
            _insideCallback = false;
        }
    }
}

contract CoWActionCallbackAdapterMock {
    ICoWSwapAction internal _capability;
    IERC20 internal _sellToken;
    bool public callbackSucceeded;
    bytes public callbackResult;

    function authorize(ICoWSwapAction actionContract, IERC20 sellToken, address tokenOut) external {
        _capability = actionContract;
        _sellToken = sellToken;
        sellToken.approve(address(actionContract), 100);
        actionContract.convert(
            address(sellToken),
            100,
            tokenOut,
            ICoWSwapAction.OrderParams({buyAmount: 90, validTo: uint32(block.timestamp + 1800), appData: 0})
        );
    }

    function onTransfer() external {
        (callbackSucceeded, callbackResult) =
            address(_capability).call(abi.encodeCall(ICoWSwapAction.recover, (address(_sellToken))));
    }
}
