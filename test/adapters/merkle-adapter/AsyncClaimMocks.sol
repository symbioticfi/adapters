// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AsyncClaimTokenMock is ERC20 {
    uint8 internal immutable _decimals;

    constructor(uint8 newDecimals) ERC20("Fixture asset", "ASSET") {
        _decimals = newDecimals;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address receiver, uint256 amount) public {
        _mint(receiver, amount);
    }
}

contract AsyncClaimVaultMock is ERC20 {
    error AsyncPreview();
    address public immutable asset;
    mapping(address => uint256) public pendingDeposit;
    mapping(address => uint256) public pendingRedeem;
    mapping(address => uint256) internal _claimableMint;
    mapping(address => uint256) internal _claimableRedeem;

    constructor(address newAsset) ERC20("Fixture shares", "SHARE") {
        asset = newAsset;
    }

    function seedShares(address receiver, uint256 shares) public {
        _mint(receiver, shares);
    }

    function requestDeposit(uint256 assets, address controller, address owner) public returns (uint256) {
        require(owner == msg.sender);
        IERC20(asset).transferFrom(owner, address(this), assets);
        pendingDeposit[controller] += assets;
        return 0;
    }

    function requestRedeem(uint256 shares, address controller, address owner) public returns (uint256) {
        require(owner == msg.sender);
        _burn(owner, shares);
        pendingRedeem[controller] += shares;
        return 0;
    }

    function settleDeposit(address controller, uint256 assets) public {
        pendingDeposit[controller] -= assets;
        _claimableMint[controller] += assets * 1e12;
    }

    function settleRedeem(address controller, uint256 shares) public {
        pendingRedeem[controller] -= shares;
        _claimableRedeem[controller] += shares;
    }

    function maxMint(address controller) public view returns (uint256) {
        return _claimableMint[controller];
    }

    function maxDeposit(address controller) public view returns (uint256) {
        return _claimableMint[controller] / 1e12;
    }

    function maxRedeem(address controller) public view returns (uint256) {
        return _claimableRedeem[controller];
    }

    function maxWithdraw(address controller) public view virtual returns (uint256) {
        return _claimableRedeem[controller] / 1e12;
    }

    function previewMint(uint256) public pure returns (uint256) {
        revert AsyncPreview();
    }

    function previewWithdraw(uint256) public pure returns (uint256) {
        revert AsyncPreview();
    }

    function previewRedeem(uint256) public pure returns (uint256) {
        revert AsyncPreview();
    }

    function mint(uint256 shares, address receiver) public returns (uint256 assets) {
        _claimableMint[msg.sender] -= shares;
        _mint(receiver, shares);
        return shares / 1e12;
    }

    function deposit(uint256 assets, address receiver) public returns (uint256 shares) {
        shares = assets * 1e12;
        _claimableMint[msg.sender] -= shares;
        _mint(receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address controller) public returns (uint256 assets) {
        require(controller == msg.sender);
        _claimableRedeem[controller] -= shares;
        assets = shares / 1e12;
        IERC20(asset).transfer(receiver, assets);
    }

    function withdraw(uint256 assets, address receiver, address controller) public virtual returns (uint256 shares) {
        require(controller == msg.sender);
        shares = assets * 1e12;
        _claimableRedeem[controller] -= shares;
        IERC20(asset).transfer(receiver, assets);
    }
}
