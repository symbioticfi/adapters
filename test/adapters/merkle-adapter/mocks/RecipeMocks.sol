// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RecipeLiquiditySource {
    error QueryFailed();
    IERC20 public immutable asset;
    address public immutable adapter;
    uint256 public liquidity;
    uint256 public withdrawn;
    uint256 public calls;
    int256 public adjustment;
    address public callbackTarget;
    bytes public callbackData;

    constructor(IERC20 asset_, address adapter_) {
        asset = asset_;
        adapter = adapter_;
    }

    function setLiquidity(uint256 amount) external {
        liquidity = amount;
    }

    function setAdjustment(int256 amount) external {
        adjustment = amount;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function getLiquidity() external view returns (uint256) {
        return liquidity;
    }

    function failQuery() external pure returns (uint256) {
        revert QueryFailed();
    }

    function malformedQuery() external pure returns (uint256) {
        assembly ("memory-safe") { return(0, 1) }
    }

    function mutatingQuery() external returns (uint256) {
        ++calls;
        return liquidity;
    }

    function give(address receiver, uint256 amount) external {
        require(msg.sender == adapter);
        asset.transfer(receiver, amount);
    }

    function withdraw(address receiver, uint256 amount) external payable {
        require(msg.sender == adapter && receiver == adapter);
        require(amount <= liquidity);
        liquidity -= amount;
        withdrawn += amount;
        ++calls;
        uint256 sent = adjustment < 0 ? amount - uint256(-adjustment) : amount + uint256(adjustment);
        asset.transfer(receiver, sent);
        if (callbackTarget != address(0)) {
            (bool ok, bytes memory result) = callbackTarget.call(callbackData);
            if (!ok) {
                assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
            }
        }
    }
}

contract RecipeRwaToken is ERC20 {
    uint256 public redeemed;

    constructor() ERC20("Redeemable RWA", "RWA") {
        _mint(msg.sender, 10_000_000);
    }

    function redeem(uint256 amount) public {
        _burn(msg.sender, amount);
        redeemed += amount;
    }
}

contract RecipeIssuerReceipt is ERC20 {
    address public immutable rwa;

    constructor(address newRwa) ERC20("Issuer redemption receipt", "RECEIPT") {
        rwa = newRwa;
    }

    function redeem(uint256 amount, uint256 receipts) public {
        IERC20(rwa).transferFrom(msg.sender, address(this), amount);
        RecipeRwaToken(rwa).redeem(amount);
        _mint(msg.sender, receipts);
    }
}
