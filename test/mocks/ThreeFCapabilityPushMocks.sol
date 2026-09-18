// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import {IThreeFRequestCallback} from "src/interfaces/3f-adapter/IThreeFRequestCallback.sol";
import {IThreeFWhitelist} from "src/interfaces/3f-adapter/IThreeFWhitelist.sol";
import {IThreeFFacility} from "src/interfaces/3f-adapter/IThreeFAdapterDependencies.sol";
import {Offer} from "src/interfaces/3f-adapter/ThreeFTypes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

contract ThreeFCapabilityAdapterMock {
    using Address for address;
    address public immutable vault;
    address public immutable owner;

    constructor(address vault_, address owner_) {
        vault = vault_;
        owner = owner_;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory) {
        return target.functionCall(data);
    }

    function approve(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }
}

contract ThreeFCapabilityVaultMock {
    address public immutable asset;

    constructor(address asset_) {
        asset = asset_;
    }
}

contract ThreeFCapabilityWhitelistMock is IThreeFWhitelist {
    mapping(address => WhitelistStatus) internal statuses;

    function set(address request, WhitelistStatus status) external {
        statuses[request] = status;
    }

    function isWhitelisted(address request) external view returns (WhitelistStatus) {
        return statuses[request];
    }
}

contract ThreeFCapabilityFacilityMock is IThreeFFacility {
    mapping(uint256 => IntentProperties) internal propertiesById;
    mapping(uint256 => address) internal requests;

    function setIntent(uint256 id, address request, address positionManager, bool isPositionManager) external {
        propertiesById[id].targetAsset = Asset(positionManager, isPositionManager);
        requests[id] = request;
    }

    function getIntent(uint256 id)
        external
        view
        returns (IntentProperties memory properties, address fund, address request, bool resolved)
    {
        return (propertiesById[id], address(0), requests[id], false);
    }
}

contract ThreeFCapabilityPositionManagerMock {
    address public collateral;

    constructor(address collateral_) {
        collateral = collateral_;
    }

    function setCollateral(address collateral_) external {
        collateral = collateral_;
    }

    function assets() external view returns (address collateralAsset, address debtAsset) {
        return (collateral, address(0));
    }
}

contract ThreeFCapabilityCollateralMock {
    address public immutable underlying;

    constructor(address underlying_) {
        underlying = underlying_;
    }
}

contract ThreeFCapabilityTokenMock is ERC20 {
    using Address for address;
    address internal callbackFrom;
    address internal callbackTarget;
    bytes internal callbackData;
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }

    function setTransferFromCallback(address from, address target, bytes calldata data) external {
        callbackFrom = from;
        callbackTarget = target;
        callbackData = data;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool result = super.transferFrom(from, to, amount);
        if (from == callbackFrom && callbackTarget != address(0)) {
            address target = callbackTarget;
            callbackTarget = address(0);
            target.functionCall(callbackData);
        }
        return result;
    }
}

/// @dev Normal push behavior follows Request: authorization overwrites, both-zero mint is a no-op,
/// bounds are checked, authorization clears, principal is pulled, and PT/YT go to msg.sender.
contract ThreeFCapabilityRequestMock {
    error SlippageExceeded();
    error MintFailed();
    error NotWithdrawable();

    address public immutable asset;
    string public name;
    bool public canWithdraw;
    bool public revertBalancesOf;
    bool internal failMint;
    uint256 public ptSupply;
    uint256 public ytSupply;
    address public mintCaller;
    uint128 public principalCapAtMint;
    uint128 public yieldFloorAtMint;
    uint256 public allowanceAtMint;
    uint256 public mintCalls;
    address internal callbackTarget;
    bytes internal callbackData;
    bool public callbackSuccess;
    bytes public callbackResult;
    mapping(address => uint256) internal ptBalances;
    mapping(address => uint256) internal ytBalances;
    mapping(address => uint128) internal authorizedPrincipal;
    mapping(address => uint128) internal authorizedYield;
    mapping(address => uint256) public nonce;

    constructor(address asset_, string memory name_) {
        asset = asset_;
        name = name_;
    }

    function setName(string calldata name_) external {
        name = name_;
    }

    function setCanWithdraw(bool status) external {
        canWithdraw = status;
    }

    function setRevertBalancesOf(bool status) external {
        revertBalancesOf = status;
    }

    function setFailMint(bool status) external {
        failMint = status;
    }

    function setMintCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function setNonce(uint256 newNonce) external {
        if (nonce[msg.sender] >= newNonce) revert();
        nonce[msg.sender] = newNonce;
    }

    function authorizeMinting(address account, uint128 principal, uint128 yieldAmount) external {
        authorizedPrincipal[account] = principal;
        authorizedYield[account] = yieldAmount;
    }

    function mintAuthorization(address account) external view returns (uint128, uint128) {
        return (authorizedPrincipal[account], authorizedYield[account]);
    }

    function mint(uint128 maxPrincipal, uint128 minYield) external {
        uint128 principal = authorizedPrincipal[msg.sender];
        uint128 yieldAmount = authorizedYield[msg.sender];
        if (principal == 0 && yieldAmount == 0) return;
        if (principal > maxPrincipal || yieldAmount < minYield) revert SlippageExceeded();
        authorizedPrincipal[msg.sender] = 0;
        authorizedYield[msg.sender] = 0;
        mintCaller = msg.sender;
        principalCapAtMint = maxPrincipal;
        yieldFloorAtMint = minYield;
        allowanceAtMint = IERC20(asset).allowance(msg.sender, address(this));
        ++mintCalls;
        IERC20(asset).transferFrom(msg.sender, address(this), principal);
        _mintShares(msg.sender, principal, yieldAmount);
        if (callbackTarget != address(0)) {
            (callbackSuccess, callbackResult) = callbackTarget.call(callbackData);
        }
        if (failMint) revert MintFailed();
    }

    function balancesOf(address account) external view returns (uint256 ptShares, uint256 ytShares) {
        if (revertBalancesOf) revert();
        return (ptBalances[account], ytBalances[account]);
    }

    function convertToAssets(uint256 ptShares, uint256 ytShares)
        public
        view
        returns (uint256 pAssets, uint256 yAssets)
    {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 principalValue = balance < ptSupply ? balance : ptSupply;
        if (ptSupply > 0) pAssets = principalValue * ptShares / ptSupply;
        if (ytSupply > 0 && balance > principalValue) yAssets = (balance - principalValue) * ytShares / ytSupply;
    }

    function pull(address receiver, uint256 amount) external {
        IERC20(asset).transfer(receiver, amount);
    }

    function pullFrom(address owner, address receiver, uint256 amount) external {
        IERC20(asset).transferFrom(owner, receiver, amount);
    }

    function consume(
        address actionContract,
        Offer calldata offer,
        bytes calldata signature,
        uint256 principal,
        uint256 yieldAmount
    ) external {
        IThreeFRequestCallback(actionContract).onRequestConsumed(offer, signature, principal, yieldAmount);
        IERC20(asset).transferFrom(actionContract, address(this), principal);
        _mintShares(actionContract, principal, yieldAmount);
    }

    function burnAll(address owner, address receiver)
        external
        returns (uint256 ptShares, uint256 ytShares, uint256 pAssets, uint256 yAssets)
    {
        if (!canWithdraw) revert NotWithdrawable();
        ptShares = ptBalances[owner];
        ytShares = ytBalances[owner];
        (pAssets, yAssets) = convertToAssets(ptShares, ytShares);
        ptBalances[owner] = 0;
        ytBalances[owner] = 0;
        ptSupply -= ptShares;
        ytSupply -= ytShares;
        IERC20(asset).transfer(receiver, pAssets + yAssets);
    }

    function _mintShares(address account, uint256 principal, uint256 yieldAmount) internal {
        ptBalances[account] += principal;
        ytBalances[account] += yieldAmount;
        ptSupply += principal;
        ytSupply += yieldAmount;
    }
}
