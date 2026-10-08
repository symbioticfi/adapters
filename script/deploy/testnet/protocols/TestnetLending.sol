// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TestnetCreditVault
/// @notice Funded ERC-4626 credit market with accruing debt, collateral checks and cash-limited exits.
/// @dev Implements the adapter-facing Euler and Morpho Vault V2 reads. This is a behavioral model;
/// it does not implement EVC account routing or Morpho Vault V2 allocation queues.
contract TestnetCreditVault is ERC4626, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    error InsufficientCollateral();
    error InvalidAmount();

    address public immutable adapterRegistry;
    address public immutable collateralToken;
    uint256 public immutable annualBorrowRate;
    uint256 public debtIndex = 1e18;
    uint48 public lastAccrual;
    uint256 public totalDebtShares;
    mapping(address account => uint256 shares) public debtShares;
    mapping(address account => uint256 assets) public collateral;
    uint256 public collateralPrice = 1e18;
    uint256 public borrowLTV = 7500;
    uint256 public liquidationLTV = 8000;

    event Borrow(address indexed account, uint256 assets);
    event Repay(address indexed account, uint256 assets);
    event VaultStatus(
        uint256 totalShares,
        uint256 totalBorrows,
        uint256 accumulatedFees,
        uint256 cash,
        uint256 interestAccumulator,
        uint256 interestRate,
        uint256 timestamp
    );
    event SetRisk(uint256 price, uint256 borrowLTV, uint256 liquidationLTV);
    event SupplyCollateral(address indexed account, uint256 assets);

    constructor(
        address newAsset,
        address newCollateral,
        address newOwner,
        address newRegistry,
        string memory newName,
        string memory newSymbol,
        uint256 newAnnualBorrowRate
    ) ERC20(newName, newSymbol) ERC4626(IERC20(newAsset)) Ownable(newOwner) {
        collateralToken = newCollateral;
        adapterRegistry = newRegistry;
        annualBorrowRate = newAnnualBorrowRate;
        lastAccrual = uint48(block.timestamp);
    }

    function liquidityAdapter() public pure returns (address) {
        return address(0);
    }

    function abdicated(bytes4 selector) public pure returns (bool) {
        return selector == bytes4(keccak256("setAdapterRegistry(address)"));
    }

    function canSendShares(address) public pure returns (bool) {
        return true;
    }

    function canReceiveAssets(address) public pure returns (bool) {
        return true;
    }

    function liquidityData() public pure returns (bytes memory) {
        return "";
    }

    function cash() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function currentDebtIndex() public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastAccrual;
        uint256 base = 1e27 + interestRate();
        uint256 factor = 1e27;
        while (elapsed > 0) {
            if (elapsed & 1 > 0) factor = factor.mulDiv(base, 1e27);
            elapsed >>= 1;
            if (elapsed > 0) base = base.mulDiv(base, 1e27);
        }
        return debtIndex.mulDiv(factor, 1e27);
    }

    function interestRate() public view returns (uint256) {
        return annualBorrowRate * 1e9 / 31_556_952;
    }

    function interestAccumulator() public view returns (uint256) {
        return currentDebtIndex() * 1e9;
    }

    function totalBorrows() public view returns (uint256) {
        return totalDebtShares.mulDiv(currentDebtIndex(), 1e18);
    }

    function debtOf(address account) public view returns (uint256) {
        return debtShares[account].mulDiv(currentDebtIndex(), 1e18);
    }

    function totalAssets() public view override returns (uint256) {
        return cash() + totalBorrows();
    }

    function maxWithdraw(address account) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(account), cash());
    }

    function maxRedeem(address account) public view override returns (uint256) {
        return Math.min(balanceOf(account), convertToShares(cash()));
    }

    function accountLiquidity(address account, bool liquidation)
        public
        view
        returns (uint256 value, uint256 liability)
    {
        value = collateral[account]
            .mulDiv(collateralPrice * 10 ** decimals(), 1e18 * 10 ** IERC20Metadata(collateralToken).decimals())
            .mulDiv(liquidation ? liquidationLTV : borrowLTV, 10_000);
        liability = debtOf(account);
    }

    function setRisk(uint256 price, uint256 newBorrowLTV, uint256 newLiquidationLTV) public onlyOwner {
        if (price == 0 || newBorrowLTV > newLiquidationLTV || newLiquidationLTV > 10_000) revert InvalidAmount();
        collateralPrice = price;
        borrowLTV = newBorrowLTV;
        liquidationLTV = newLiquidationLTV;
        emit SetRisk(price, newBorrowLTV, newLiquidationLTV);
    }

    function supplyCollateral(uint256 assets, address account) public {
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), assets);
        collateral[account] += assets;
        emit SupplyCollateral(account, assets);
    }

    function borrow(uint256 assets, address receiver) public returns (uint256) {
        accrueInterest();
        if (assets == 0 || assets > cash()) revert InvalidAmount();
        debtShares[msg.sender] += assets.mulDiv(1e18, debtIndex, Math.Rounding.Ceil);
        totalDebtShares += assets.mulDiv(1e18, debtIndex, Math.Rounding.Ceil);
        (uint256 value, uint256 liability) = accountLiquidity(msg.sender, false);
        if (liability > value) revert InsufficientCollateral();
        IERC20(asset()).safeTransfer(receiver, assets);
        emit Borrow(msg.sender, assets);
        return assets;
    }

    function repay(uint256 assets, address account) public returns (uint256 paid) {
        accrueInterest();
        uint256 shares = Math.min(debtShares[account], assets.mulDiv(1e18, debtIndex));
        if (assets == type(uint256).max) shares = debtShares[account];
        paid = shares.mulDiv(debtIndex, 1e18, Math.Rounding.Ceil);
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), paid);
        debtShares[account] -= shares;
        totalDebtShares -= shares;
        emit Repay(account, paid);
    }

    function accrueInterest() public {
        debtIndex = currentDebtIndex();
        lastAccrual = uint48(block.timestamp);
        emit VaultStatus(
            totalSupply(), totalBorrows(), 0, cash(), interestAccumulator(), interestRate(), block.timestamp
        );
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        accrueInterest();
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address account, uint256 assets, uint256 shares)
        internal
        override
    {
        accrueInterest();
        super._withdraw(caller, receiver, account, assets, shares);
    }
}

/// @title TestnetLendingRegistry
/// @notice Factory predicates used by the real Euler/Morpho adapters, restricted to registered markets.
contract TestnetLendingRegistry is Ownable {
    mapping(address vault => bool registered) public isVaultV2;
    mapping(address vault => bool registered) public isProxy;
    event Register(address indexed vault);
    constructor(address newOwner) Ownable(newOwner) {}

    function register(address vault) public onlyOwner {
        isVaultV2[vault] = true;
        isProxy[vault] = true;
        emit Register(vault);
    }

    function isInRegistry(address vault) public view returns (bool) {
        return isVaultV2[vault];
    }
}

/// @title TestnetAToken
/// @notice Indexed Aave receipt balances; only the configured pool can mint, burn or move reserve cash.
contract TestnetAToken is IERC20Metadata {
    using Math for uint256;
    using SafeERC20 for IERC20;
    error InvalidCaller();
    error InvalidAmount();
    address public immutable POOL;
    address public immutable UNDERLYING_ASSET_ADDRESS;
    uint256 internal _scaledSupply;
    mapping(address account => uint256 shares) internal _scaledBalances;
    mapping(address account => mapping(address spender => uint256 amount)) public allowance;
    event Mint(
        address indexed caller, address indexed onBehalfOf, uint256 value, uint256 balanceIncrease, uint256 index
    );
    event Burn(address indexed from, address indexed target, uint256 value, uint256 balanceIncrease, uint256 index);
    event BalanceTransfer(address indexed from, address indexed to, uint256 value, uint256 index);

    constructor(address newPool, address newAsset) {
        POOL = newPool;
        UNDERLYING_ASSET_ADDRESS = newAsset;
    }

    function name() public pure returns (string memory) {
        return "Testnet Aave receipt";
    }

    function symbol() public pure returns (string memory) {
        return "aTEST";
    }

    function decimals() public view returns (uint8) {
        return IERC20Metadata(UNDERLYING_ASSET_ADDRESS).decimals();
    }

    function scaledBalanceOf(address account) public view returns (uint256) {
        return _scaledBalances[account];
    }

    function scaledTotalSupply() public view returns (uint256) {
        return _scaledSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _scaledBalances[account].mulDiv(
            TestnetAavePool(POOL).getReserveNormalizedIncome(UNDERLYING_ASSET_ADDRESS), 1e27
        );
    }

    function totalSupply() public view returns (uint256) {
        return _scaledSupply.mulDiv(TestnetAavePool(POOL).getReserveNormalizedIncome(UNDERLYING_ASSET_ADDRESS), 1e27);
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function mint(address account, uint256 amount, uint256 index) public {
        if (POOL != msg.sender) revert InvalidCaller();
        uint256 shares = amount.mulDiv(1e27, index);
        if (shares == 0) revert InvalidAmount();
        _scaledBalances[account] += shares;
        _scaledSupply += shares;
        emit Transfer(address(0), account, amount);
        emit Mint(msg.sender, account, amount, 0, index);
    }

    function burn(address account, uint256 amount, uint256 index) public {
        if (POOL != msg.sender) revert InvalidCaller();
        uint256 shares = amount.mulDiv(1e27, index, Math.Rounding.Ceil);
        _scaledBalances[account] -= shares;
        _scaledSupply -= shares;
        emit Transfer(account, address(0), amount);
        emit Burn(account, account, amount, 0, index);
    }

    function transferUnderlying(address receiver, uint256 amount) public {
        if (POOL != msg.sender) revert InvalidCaller();
        IERC20(UNDERLYING_ASSET_ADDRESS).safeTransfer(receiver, amount);
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert InvalidAmount();
        uint256 index = TestnetAavePool(POOL).getReserveNormalizedIncome(UNDERLYING_ASSET_ADDRESS);
        uint256 shares = amount.mulDiv(1e27, index, Math.Rounding.Ceil);
        _scaledBalances[from] -= shares;
        _scaledBalances[to] += shares;
        TestnetAavePool(POOL).validateTransfer(from);
        emit Transfer(from, to, amount);
        emit BalanceTransfer(from, to, shares, index);
    }
}

/// @title TestnetAavePool
/// @notice Single-reserve Aave V3 behavioral model with indexed receipts, debt, flags and pool events.
contract TestnetAavePool is Ownable {
    using Math for uint256;
    using SafeERC20 for IERC20;
    error InsufficientCollateral();
    error InvalidAmount();
    address public immutable asset;
    address public immutable aToken;
    address public immutable ADDRESSES_PROVIDER;
    uint256 public liquidityIndex = 1e27;
    uint256 public variableBorrowIndex = 1e27;
    uint256 public liquidityRate;
    uint256 public variableBorrowRate = 8e25;
    uint48 public lastUpdate;
    uint256 public totalScaledDebt;
    uint256 public assetPrice = 1e8;
    mapping(address account => uint256 debt) public scaledDebt;

    event Supply(
        address indexed reserve, address user, address indexed onBehalfOf, uint256 amount, uint16 indexed referralCode
    );
    event Withdraw(address indexed reserve, address indexed user, address indexed to, uint256 amount);
    event SetAssetPrice(uint256 price);
    event Borrow(
        address indexed reserve,
        address user,
        address indexed onBehalfOf,
        uint256 amount,
        uint8 interestRateMode,
        uint256 borrowRate,
        uint16 indexed referralCode
    );
    event Repay(
        address indexed reserve, address indexed user, address indexed repayer, uint256 amount, bool useATokens
    );
    event ReserveDataUpdated(
        address indexed reserve,
        uint256 liquidityRate,
        uint256 stableBorrowRate,
        uint256 variableBorrowRate,
        uint256 liquidityIndex,
        uint256 variableBorrowIndex
    );

    constructor(address newAsset, address newOwner) Ownable(newOwner) {
        asset = newAsset;
        ADDRESSES_PROVIDER = address(this);
        aToken = address(new TestnetAToken(address(this), newAsset));
        lastUpdate = uint48(block.timestamp);
    }

    function getReserveAToken(address token) public view returns (address) {
        return token == asset ? aToken : address(0);
    }

    function getPriceOracle() public view returns (address) {
        return address(this);
    }

    function getPool() public view returns (address) {
        return address(this);
    }

    function getPoolDataProvider() public view returns (address) {
        return address(this);
    }

    function getAssetPrice(address token) public view returns (uint256) {
        return token == asset ? assetPrice : 0;
    }

    function setAssetPrice(uint256 newPrice) public onlyOwner {
        if (newPrice == 0) revert InvalidAmount();
        assetPrice = newPrice;
        emit SetAssetPrice(newPrice);
    }

    function getVirtualUnderlyingBalance(address token) public view returns (uint128) {
        return token == asset ? uint128(IERC20(asset).balanceOf(aToken)) : 0;
    }

    function getConfiguration(address token) public view returns (uint256) {
        return token == asset
            ? uint256(7500) | (uint256(8000) << 16) | (uint256(IERC20Metadata(asset).decimals()) << 48) | (1 << 56)
                | (1 << 58)
            : 0;
    }

    function getUserConfiguration(address account) public view returns (uint256) {
        return (scaledDebt[account] > 0 ? 1 : 0) | (IERC20(aToken).balanceOf(account) > 0 ? 2 : 0);
    }

    function getUserEMode(address) public pure returns (uint256) {
        return 0;
    }

    function getReserveAddressById(uint16 id) public view returns (address) {
        return id == 0 ? asset : address(0);
    }

    function getReserveNormalizedIncome(address) public view returns (uint256) {
        return liquidityIndex + liquidityIndex.mulDiv(liquidityRate * (block.timestamp - lastUpdate), 365 days * 1e27);
    }

    function getReserveNormalizedVariableDebt(address) public view returns (uint256) {
        return variableBorrowIndex
            + variableBorrowIndex.mulDiv(variableBorrowRate * (block.timestamp - lastUpdate), 365 days * 1e27);
    }

    function debtOf(address account) public view returns (uint256) {
        return scaledDebt[account].mulDiv(getReserveNormalizedVariableDebt(asset), 1e27);
    }

    function getUserAccountData(address account)
        public
        view
        returns (uint256 value, uint256 debt, uint256 available, uint256 threshold, uint256 ltv, uint256 health)
    {
        value = IERC20(aToken).balanceOf(account).mulDiv(assetPrice, 10 ** IERC20Metadata(asset).decimals());
        debt = debtOf(account).mulDiv(assetPrice, 10 ** IERC20Metadata(asset).decimals());
        available = value.mulDiv(7500, 10_000).saturatingSub(debt);
        threshold = 8000;
        ltv = 7500;
        health = debt == 0 ? type(uint256).max : value.mulDiv(8e17, debt);
    }

    function supply(address token, uint256 amount, address receiver, uint16 referral) public {
        if (token != asset || amount == 0) revert InvalidAmount();
        _accrue();
        IERC20(asset).safeTransferFrom(msg.sender, aToken, amount);
        TestnetAToken(aToken).mint(receiver, amount, liquidityIndex);
        _rates();
        emit Supply(asset, msg.sender, receiver, amount, referral);
    }

    function withdraw(address token, uint256 amount, address receiver) public returns (uint256 paid) {
        if (token != asset) revert InvalidAmount();
        _accrue();
        paid = amount == type(uint256).max ? IERC20(aToken).balanceOf(msg.sender) : amount;
        if (paid > IERC20(asset).balanceOf(aToken)) revert InvalidAmount();
        TestnetAToken(aToken).burn(msg.sender, paid, liquidityIndex);
        if (debtOf(msg.sender) > IERC20(aToken).balanceOf(msg.sender).mulDiv(8000, 10_000)) {
            revert InsufficientCollateral();
        }
        TestnetAToken(aToken).transferUnderlying(receiver, paid);
        _rates();
        emit Withdraw(asset, msg.sender, receiver, paid);
    }

    function borrow(address token, uint256 amount, uint256 mode, uint16 referral, address account) public {
        if (token != asset || account != msg.sender || mode != 2 || amount == 0) revert InvalidAmount();
        _accrue();
        uint256 shares = amount.mulDiv(1e27, variableBorrowIndex, Math.Rounding.Ceil);
        scaledDebt[account] += shares;
        totalScaledDebt += shares;
        if (debtOf(account) > IERC20(aToken).balanceOf(account).mulDiv(7500, 10_000)) revert InsufficientCollateral();
        TestnetAToken(aToken).transferUnderlying(msg.sender, amount);
        _rates();
        emit Borrow(asset, msg.sender, account, amount, 2, variableBorrowRate, referral);
    }

    function repay(address token, uint256 amount, uint256 mode, address account) public returns (uint256 paid) {
        if (token != asset || mode != 2) revert InvalidAmount();
        _accrue();
        uint256 shares = amount == type(uint256).max
            ? scaledDebt[account]
            : Math.min(scaledDebt[account], amount.mulDiv(1e27, variableBorrowIndex));
        paid = shares.mulDiv(variableBorrowIndex, 1e27, Math.Rounding.Ceil);
        IERC20(asset).safeTransferFrom(msg.sender, aToken, paid);
        scaledDebt[account] -= shares;
        totalScaledDebt -= shares;
        _rates();
        emit Repay(asset, account, msg.sender, paid, false);
    }

    function validateTransfer(address account) public view {
        if (aToken != msg.sender) revert InvalidAmount();
        if (debtOf(account) > IERC20(aToken).balanceOf(account).mulDiv(8000, 10_000)) revert InsufficientCollateral();
    }

    function getReserveTokensAddresses(address token) public view returns (address, address, address) {
        return (getReserveAToken(token), address(0), address(this));
    }

    function interestRate() public view returns (uint256) {
        return variableBorrowRate / 365 days;
    }

    function getReserveData(address token)
        public
        view
        returns (
            uint256,
            uint128,
            uint128,
            uint128,
            uint128,
            uint128,
            uint40,
            uint16,
            address,
            address,
            address,
            address,
            uint128,
            uint128,
            uint128
        )
    {
        return (
            getConfiguration(token),
            uint128(getReserveNormalizedIncome(token)),
            uint128(liquidityRate),
            uint128(getReserveNormalizedVariableDebt(token)),
            uint128(variableBorrowRate),
            0,
            uint40(lastUpdate),
            0,
            getReserveAToken(token),
            address(0),
            address(this),
            address(this),
            0,
            0,
            0
        );
    }

    function _accrue() internal {
        liquidityIndex = getReserveNormalizedIncome(asset);
        variableBorrowIndex = getReserveNormalizedVariableDebt(asset);
        lastUpdate = uint48(block.timestamp);
    }

    function _rates() internal {
        uint256 debt = totalScaledDebt.mulDiv(variableBorrowIndex, 1e27);
        uint256 backing = IERC20(asset).balanceOf(aToken) + debt;
        uint256 utilization = backing == 0 ? 0 : debt.mulDiv(1e27, backing);
        variableBorrowRate = 2e25 + utilization.mulDiv(10e25, 1e27);
        liquidityRate = variableBorrowRate.mulDiv(utilization, 1e27).mulDiv(9000, 10_000);
        emit ReserveDataUpdated(asset, liquidityRate, 0, variableBorrowRate, liquidityIndex, variableBorrowIndex);
    }
}
