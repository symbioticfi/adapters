// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockAaveAToken is ERC20, Ownable {
    address public immutable UNDERLYING_ASSET_ADDRESS;
    address public pool;

    constructor(address underlyingAsset, address owner_) ERC20("Mock AToken", "maToken") Ownable(owner_) {
        UNDERLYING_ASSET_ADDRESS = underlyingAsset;
    }

    function setPool(address newPool) external onlyOwner {
        require(pool == address(0), "pool already set");
        pool = newPool;
    }

    /// @dev Returns the reserve pool through Aave's canonical uppercase getter.
    function POOL() external view returns (address) {
        return pool;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }

    function transferUnderlying(address to, uint256 amount) external {
        require(msg.sender == pool, "not pool");
        IERC20(UNDERLYING_ASSET_ADDRESS).transfer(to, amount);
    }
}

contract MockAavePool is Ownable {
    uint256 internal constant ACTIVE_RESERVE_CONFIGURATION = 1 << 56;

    mapping(address asset => MockAaveAToken aToken) public aTokens;
    address public immutable ADDRESSES_PROVIDER;

    bool public revertOnSupply;
    bool public revertOnWithdraw;
    mapping(address asset => bool enabled) public useVirtualUnderlyingBalanceOverride;
    mapping(address asset => uint128 cash) public virtualUnderlyingBalanceOverride;

    constructor(address asset_, address aToken_, address addressesProvider_, address owner_) Ownable(owner_) {
        ADDRESSES_PROVIDER = addressesProvider_;
        aTokens[asset_] = MockAaveAToken(aToken_);
    }

    function setReserveToken(address asset_, address aToken_) external onlyOwner {
        aTokens[asset_] = MockAaveAToken(aToken_);
    }

    function getReserveAToken(address asset_) external view returns (address) {
        return address(aTokens[asset_]);
    }

    /// @dev Reports configured reserves as active through Aave's packed configuration getter.
    function getConfiguration(address asset_) external view returns (uint256) {
        return address(aTokens[asset_]) == address(0) ? 0 : ACTIVE_RESERVE_CONFIGURATION;
    }

    function getVirtualUnderlyingBalance(address asset_) external view returns (uint128) {
        MockAaveAToken aToken = aTokens[asset_];
        if (address(aToken) == address(0)) {
            return 0;
        }
        if (useVirtualUnderlyingBalanceOverride[asset_]) {
            uint256 balance = IERC20(asset_).balanceOf(address(aToken));
            return uint128(
                balance < virtualUnderlyingBalanceOverride[asset_] ? balance : virtualUnderlyingBalanceOverride[asset_]
            );
        }
        return uint128(IERC20(asset_).balanceOf(address(aToken)));
    }

    function setRevertOnSupply(bool value) external onlyOwner {
        revertOnSupply = value;
    }

    function setRevertOnWithdraw(bool value) external onlyOwner {
        revertOnWithdraw = value;
    }

    /// @dev Sets a reserve cash budget bounded by backing tokens for liquidity exercises.
    function setVirtualUnderlyingBalance(address asset_, uint128 value) external onlyOwner {
        uint256 balance = IERC20(asset_).balanceOf(address(aTokens[asset_]));
        useVirtualUnderlyingBalanceOverride[asset_] = true;
        virtualUnderlyingBalanceOverride[asset_] = uint128(value < balance ? value : balance);
    }

    /// @dev Restores balance-based cash reporting for the selected reserve.
    function clearVirtualUnderlyingBalanceOverride(address asset_) external onlyOwner {
        useVirtualUnderlyingBalanceOverride[asset_] = false;
    }

    function supply(address asset_, uint256 amount, address onBehalfOf, uint16) external {
        MockAaveAToken aToken = aTokens[asset_];
        require(address(aToken) != address(0), "invalid asset");
        require(!revertOnSupply, "supply failed");

        IERC20(asset_).transferFrom(msg.sender, address(aToken), amount);
        aToken.mint(onBehalfOf, amount);
        if (useVirtualUnderlyingBalanceOverride[asset_]) {
            require(amount <= type(uint128).max, "amount too large");
            virtualUnderlyingBalanceOverride[asset_] += uint128(amount);
        }
    }

    function withdraw(address asset_, uint256 amount, address to) external returns (uint256 withdrawn) {
        MockAaveAToken aToken = aTokens[asset_];
        require(address(aToken) != address(0), "invalid asset");
        require(!revertOnWithdraw, "withdraw failed");

        uint256 balance = aToken.balanceOf(msg.sender);
        uint256 liquidity = IERC20(asset_).balanceOf(address(aToken));
        withdrawn = amount == type(uint256).max ? balance : amount;
        require(withdrawn <= balance && withdrawn <= liquidity, "insufficient liquidity");
        if (useVirtualUnderlyingBalanceOverride[asset_]) {
            require(withdrawn <= virtualUnderlyingBalanceOverride[asset_], "insufficient cash");
            virtualUnderlyingBalanceOverride[asset_] -= uint128(withdrawn);
        }
        if (withdrawn > 0) {
            aToken.burn(msg.sender, withdrawn);
            aToken.transferUnderlying(to, withdrawn);
        }
    }

    function accrueYield(address asset_, address account, uint256 amount) external onlyOwner {
        MockAaveAToken aToken = aTokens[asset_];
        require(address(aToken) != address(0), "invalid asset");
        IERC20(asset_).transferFrom(msg.sender, address(aToken), amount);
        aToken.mint(account, amount);
        if (useVirtualUnderlyingBalanceOverride[asset_]) {
            require(amount <= type(uint128).max, "amount too large");
            virtualUnderlyingBalanceOverride[asset_] += uint128(amount);
        }
    }
}
