// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Restricted relayer boundary for exercising actual ERC20 allowance consumption in offline tests.
contract CoWCapabilityRelayerMock {
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
contract CoWCapabilitySettlementMock {
    bytes32 public constant domainSeparator = 0xc078f884a2676e1345748b1feace7b0abee5d00ecadb6e574dcdd109a63e8943;
    address public immutable vaultRelayer = address(new CoWCapabilityRelayerMock());
    mapping(bytes orderUid => uint256 value) public preSignature;
    address internal _callbackTarget;
    bytes internal _callbackData;
    bool internal _insideCallback;
    bool public callbackSucceeded;
    bytes public callbackResult;

    function setCallback(address target, bytes calldata data) external {
        _callbackTarget = target;
        _callbackData = data;
    }

    function setPreSignature(bytes calldata orderUid, bool signed) external {
        require(orderUid.length == 56, "GPv2: invalid uid");
        require(address(bytes20(orderUid[32:52])) == msg.sender, "GPv2: cannot presign order");
        preSignature[orderUid] = signed ? uint256(keccak256("GPv2Signing.Scheme.PreSign")) : 0;
        if (_callbackTarget != address(0) && !_insideCallback) {
            _insideCallback = true;
            (callbackSucceeded, callbackResult) = _callbackTarget.call(_callbackData);
            _insideCallback = false;
        }
    }

    function consumeSellTokens(address token, address owner, uint256 amount) external {
        CoWCapabilityRelayerMock(vaultRelayer).pull(token, owner, amount);
    }

    function consumePresignedSellTokens(bytes calldata orderUid, address token, uint256 amount) external {
        require(preSignature[orderUid] != 0, "GPv2: order not presigned");
        require(orderUid.length == 56, "GPv2: invalid uid");
        CoWCapabilityRelayerMock(vaultRelayer).pull(token, address(bytes20(orderUid[32:52])), amount);
    }
}

/// @dev Models a paused token that rejects approvals and transfers while preserving balances and allowances.
contract CoWCapabilityPausedTokenMock is ERC20 {
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
